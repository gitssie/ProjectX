#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ProjectXLogging.h"
#import "IdentifierManager.h"
#import "ProfileManifest.h"
#import "PXRootHidePath.h"
#import "PXProcessHookPolicy.h"
#import "PXSysctlHookRouter.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <IOKit/IOKitLib.h>
#import <ellekit/ellekit.h>
#import <sys/sysctl.h>
#import <pthread.h>
#import <errno.h>

// Macro for iOS version checking
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)

// Update the shouldSpoofForBundle function to directly check settings files
static BOOL shouldSpoofForBundle(NSString *bundleID) {
    if (!bundleID) return NO;
    return [[IdentifierManager sharedManager] shouldSpoofForBundle:bundleID];
}
#if 0
    
    // Skip system apps, the tweak itself, and system processes - more comprehensive filtering
    if ([bundleID hasPrefix:@"com.apple."] || 
        [bundleID isEqualToString:@"com.hydra.projectx"] ||
        [bundleID containsString:@"springboard"] ||
        [bundleID containsString:@"backboardd"] ||
        [bundleID containsString:@"mediaserverd"] ||
        [bundleID containsString:@"searchd"] ||
        [bundleID containsString:@"assertiond"] ||
        [bundleID containsString:@"useractivityd"] ||
        [bundleID containsString:@"apsd"] ||
        [bundleID containsString:@"identityservicesd"] ||
        [bundleID containsString:@"coreduetd"] ||
        [bundleID containsString:@"sharingd"] ||
        [bundleID containsString:@"mobiletimerd"] ||
        ([bundleID containsString:@"system"] && [bundleID containsString:@"daemon"])) {
        return NO;
    }
    
    // Get the executable path to check if it's a system binary
    NSString *executablePath = [[NSBundle mainBundle] executablePath];
    if (executablePath && 
        ([executablePath hasPrefix:@"/usr/"] || 
         [executablePath hasPrefix:@"/bin/"] || 
         [executablePath hasPrefix:@"/sbin/"])) {
        return NO;
    }
    
    // Initialize the cache queue if needed
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cacheQueue = dispatch_queue_create("com.hydra.projectx.uuidcache", DISPATCH_QUEUE_SERIAL);
        isInitialized = YES;
    });
    
    // Check if for some reason initialization failed
    if (!isInitialized || !cacheQueue) {
        return NO;
    }
    
    // Use sync block for thread-safe access to the cache
    __block BOOL shouldSpoof = NO;
    __block BOOL foundInCache = NO;
    
    dispatch_sync(cacheQueue, ^{
        // Ensure the cache dictionary exists
        if (!cachedBundleDecisions) {
            cachedBundleDecisions = [NSMutableDictionary dictionary];
        }
        
        // Check cache first
        NSNumber *cachedDecision = cachedBundleDecisions[bundleID];
        NSDate *decisionTimestamp = cachedBundleDecisions[[bundleID stringByAppendingString:@"_timestamp"]];
        
        if (cachedDecision && decisionTimestamp && 
            [[NSDate date] timeIntervalSinceDate:decisionTimestamp] < kCacheValidityDuration) {
            shouldSpoof = [cachedDecision boolValue];
            foundInCache = YES;
        }
    });
    
    // If found in cache, return immediately
    if (foundInCache) {
        return shouldSpoof;
    }
    
    // Not found in cache, need to compute the value safely
    @try {
        // Check if this app is enabled by directly reading the settings file
        // First check if the app is in the scoped apps list (enabled in the tweak)
        BOOL isAppEnabled = NO;
        
        NSArray *preferencesLocations = @[PXPreferencesDirectoryPath()];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *scopedAppsFilePath = nil;
        
        // Try to find the global_scope.plist file
        for (NSString *prefsPath in preferencesLocations) {
            NSString *testPath = [prefsPath stringByAppendingPathComponent:@"com.hydra.projectx.global_scope.plist"];
            if ([fileManager fileExistsAtPath:testPath]) {
                scopedAppsFilePath = testPath;
                break;
            }
        }
        
        if (scopedAppsFilePath) {
            NSDictionary *scopedAppsDict = PXProfileReadDictionary(scopedAppsFilePath);
            NSDictionary *scopedApps = scopedAppsDict[@"ScopedApps"];
            
            if (scopedApps && scopedApps[bundleID]) {
                isAppEnabled = [scopedApps[bundleID][@"enabled"] boolValue];
                PXLog(@"[WeaponX] 🔍 App %@ found in scoped apps, enabled: %@", bundleID, isAppEnabled ? @"YES" : @"NO");
            } else {
                PXLog(@"[WeaponX] 🔍 App %@ not found in scoped apps list", bundleID);
            }
        } else {
            PXLog(@"[WeaponX] ⚠️ Could not find global_scope.plist file");
        }
        
        // If the app is not enabled, no need to check further
        if (!isAppEnabled) {
            dispatch_sync(cacheQueue, ^{
                cachedBundleDecisions[bundleID] = @NO;
                cachedBundleDecisions[[bundleID stringByAppendingString:@"_timestamp"]] = [NSDate date];
            });
            return NO;
        }
        
        // Now check if the UUID features are enabled by reading settings
        BOOL systemBootUUIDEnabled = NO;
        BOOL dyldCacheUUIDEnabled = NO;
        
        // Try to find the settings.plist file
        NSString *settingsFilePath = nil;
        for (NSString *prefsPath in preferencesLocations) {
            NSString *testPath = [prefsPath stringByAppendingPathComponent:@"com.hydra.projectx.settings.plist"];
            if ([fileManager fileExistsAtPath:testPath]) {
                settingsFilePath = testPath;
                break;
            }
        }
        
        if (settingsFilePath) {
            NSDictionary *settingsDict = PXProfileReadDictionary(settingsFilePath);
            NSDictionary *enabledIdentifiers = settingsDict[@"EnabledIdentifiers"];
            
            if (enabledIdentifiers) {
                systemBootUUIDEnabled = [enabledIdentifiers[@"SystemBootUUID"] boolValue];
                dyldCacheUUIDEnabled = [enabledIdentifiers[@"DyldCacheUUID"] boolValue];
                
                PXLog(@"[WeaponX] 🔍 Checking SystemBootUUID - Enabled: %@", systemBootUUIDEnabled ? @"YES" : @"NO");
                PXLog(@"[WeaponX] 🔍 Checking DyldCacheUUID - Enabled: %@", dyldCacheUUIDEnabled ? @"YES" : @"NO");
            }
        } else {
            PXLog(@"[WeaponX] ⚠️ Could not find settings.plist file");
        }
        
        // Every enabled scoped app receives the active virtual runtime session.
        shouldSpoof = isAppEnabled;
        
        if (shouldSpoof) {
            PXLog(@"[WeaponX] ✅ UUID spoofing enabled for %@", bundleID);
        } else {
            PXLog(@"[WeaponX] ℹ️ UUID features not enabled, skipping hooks for %@", bundleID);
        }
        
        // Cache the decision
        dispatch_sync(cacheQueue, ^{
            cachedBundleDecisions[bundleID] = @(shouldSpoof);
            cachedBundleDecisions[[bundleID stringByAppendingString:@"_timestamp"]] = [NSDate date];
        });
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in shouldSpoofForBundle: %@", exception);
        shouldSpoof = NO;
        
        // Cache the negative decision to avoid repeated exceptions
        dispatch_sync(cacheQueue, ^{
            cachedBundleDecisions[bundleID] = @NO;
            cachedBundleDecisions[[bundleID stringByAppendingString:@"_timestamp"]] = [NSDate date];
        });
    }
    
    return shouldSpoof;
#endif

// Direct check for SystemBootUUID being enabled
static BOOL isSystemBootUUIDEnabled() {
    return YES;
}

// Direct check for DyldCacheUUID being enabled
static BOOL isDyldCacheUUIDEnabled() {
    // Check settings file directly
    NSArray *preferencesLocations = @[PXPreferencesDirectoryPath()];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    for (NSString *prefsPath in preferencesLocations) {
        NSString *settingsPath = [prefsPath stringByAppendingPathComponent:@"com.hydra.projectx.settings.plist"];
        if ([fileManager fileExistsAtPath:settingsPath]) {
            NSDictionary *settingsDict = PXProfileReadDictionary(settingsPath);
            NSDictionary *enabledIdentifiers = settingsDict[@"EnabledIdentifiers"];
            
            if (enabledIdentifiers) {
                BOOL isEnabled = [enabledIdentifiers[@"DyldCacheUUID"] boolValue];
                PXLog(@"[WeaponX] 🔍 DyldCacheUUID enabled status from plist: %@", isEnabled ? @"YES" : @"NO");
                return isEnabled;
            }
        }
    }
    
    PXLog(@"[WeaponX] ⚠️ Could not find settings.plist file, assuming DyldCacheUUID is disabled");
    return NO;
}

// Read validated values from the single active Profile generation.
static PXProfileManifest *PXCurrentUUIDHookManifest(void) {
    PXProfileStore *store = [[PXProfileStore alloc]
        initWithIdentityDirectory:PXCurrentProfileIdentityValuesPath()];
    return [store activeManifestWithError:nil];
}

static NSString *getSpoofedSystemBootUUID() {
    return PXCurrentUUIDHookManifest().virtualSession.bootUUID;
}

static NSString *getSpoofedDyldCacheUUID() {
    NSString *value = PXCurrentUUIDHookManifest().identifiers[@"dyldCacheUUID"];
    return [[NSUUID alloc] initWithUUIDString:value] ? value : nil;
}

#pragma mark - NSUUID Hooks

// Generic UUID creation/stringification is not a Boot UUID API. Keep these legacy hooks inactive
// so IDFA/IDFV and application-generated UUIDs remain independent of the virtual runtime session.
%group LegacyGenericUUIDInterception

%hook NSUUID

// Hook NSUUID's UUID method to intercept system UUID requests
+ (instancetype)UUID {
    @try {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        if (shouldSpoofForBundle(bundleID)) {
            // Use direct check instead of manager
            if (isSystemBootUUIDEnabled()) {
                NSString *bootUUID = getSpoofedSystemBootUUID();
                if (bootUUID && bootUUID.length > 0) {
                    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:bootUUID];
                    if (uuid) {
                        PXLog(@"[WeaponX] 🔄 Spoofing NSUUID with: %@", bootUUID);
                        return uuid;
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in NSUUID+UUID: %@", exception);
    }
    
    return %orig;
}

// Hook UUIDString method to intercept UUID string requests
- (NSString *)UUIDString {
    @try {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        if (shouldSpoofForBundle(bundleID)) {
            // Use direct check instead of manager
            if (isSystemBootUUIDEnabled()) {
                // Only spoof if this is a system UUID (we can check by comparing with the actual system UUID)
                uuid_t bytes;
                [self getUUIDBytes:bytes];
                
                // Create a string from the original UUID bytes
                CFUUIDRef cfuuid = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, *((CFUUIDBytes *)bytes));
                if (!cfuuid) {
                    return %orig;
                }
                
                NSString *originalUUID = (NSString *)CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, cfuuid));
                CFRelease(cfuuid);
                
                // Determine if this is likely a system UUID (can be enhanced with more checks)
                io_registry_entry_t ioRegistryRoot = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/");
                if (ioRegistryRoot) {
                    CFStringRef platformUUID = (CFStringRef)IORegistryEntryCreateCFProperty(
                        ioRegistryRoot, 
                        CFSTR("IOPlatformUUID"), 
                        kCFAllocatorDefault, 
                        0);
                    IOObjectRelease(ioRegistryRoot);
                    
                    if (platformUUID) {
                        NSString *systemUUID = (__bridge_transfer NSString *)platformUUID;
                        if ([originalUUID isEqualToString:systemUUID]) {
                            NSString *bootUUID = getSpoofedSystemBootUUID();
                            if (bootUUID && bootUUID.length > 0) {
                                PXLog(@"[WeaponX] 🔄 Spoofing UUIDString with: %@", bootUUID);
                                return bootUUID;
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in UUIDString: %@", exception);
    }
    
    return %orig;
}

// Add additional initialization methods beyond what we already hook
- (instancetype)initWithUUIDBytes:(const uuid_t)bytes {
    @try {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        if (shouldSpoofForBundle(bundleID) && isSystemBootUUIDEnabled()) {
            // Create string from bytes to see if it matches the system UUID
            CFUUIDRef cfuuid = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, *((CFUUIDBytes *)bytes));
            if (!cfuuid) {
                return %orig;
            }
            
            NSString *originalUUID = (NSString *)CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, cfuuid));
            CFRelease(cfuuid);
            
            // Check if this might be system UUID
            io_registry_entry_t ioRegistryRoot = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/");
            if (ioRegistryRoot) {
                CFStringRef platformUUID = (CFStringRef)IORegistryEntryCreateCFProperty(
                    ioRegistryRoot, 
                    CFSTR("IOPlatformUUID"), 
                    kCFAllocatorDefault, 
                    0);
                IOObjectRelease(ioRegistryRoot);
                
                if (platformUUID) {
                    NSString *systemUUID = (__bridge_transfer NSString *)platformUUID;
                    if ([originalUUID isEqualToString:systemUUID]) {
                        NSString *bootUUID = getSpoofedSystemBootUUID();
                        if (bootUUID && bootUUID.length > 0) {
                            NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:bootUUID];
                            PXLog(@"[WeaponX] 🔄 Spoofing NSUUID initWithUUIDBytes with: %@", bootUUID);
                            return uuid ?: %orig;
                        }
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in NSUUID initWithUUIDBytes: %@", exception);
    }
    
    return %orig;
}

// Add this to catch UIDevice's identifierForVendor
- (NSString *)description {
    NSString *origDescription = %orig;
    
    @try {
        // Check if we need to spoof
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (shouldSpoofForBundle(bundleID) && isSystemBootUUIDEnabled()) {
            // Generally we don't want to modify all descriptions, only ones that might be system UUIDs
            // We'll check if the description matches the UUID pattern first
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$" 
                                                                                  options:NSRegularExpressionCaseInsensitive 
                                                                                    error:nil];
            if ([regex numberOfMatchesInString:origDescription options:0 range:NSMakeRange(0, origDescription.length)] > 0) {
                // It's a UUID string, now check if it's the system UUID
                io_registry_entry_t ioRegistryRoot = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/");
                if (ioRegistryRoot) {
                    CFStringRef platformUUID = (CFStringRef)IORegistryEntryCreateCFProperty(
                        ioRegistryRoot, 
                        CFSTR("IOPlatformUUID"), 
                        kCFAllocatorDefault, 
                        0);
                    IOObjectRelease(ioRegistryRoot);
                    
                    if (platformUUID) {
                        NSString *systemUUID = (__bridge_transfer NSString *)platformUUID;
                        if ([origDescription isEqualToString:systemUUID]) {
                            NSString *bootUUID = getSpoofedSystemBootUUID();
                            if (bootUUID && bootUUID.length > 0) {
                                PXLog(@"[WeaponX] 🔄 Spoofing NSUUID description from %@ to %@", origDescription, bootUUID);
                                return bootUUID;
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in NSUUID description: %@", exception);
    }
    
    return origDescription;
}

%end

#pragma mark - NSString UUID Hooks

%hook NSString

+ (NSString *)stringWithUUID:(uuid_t)bytes {
    @try {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        if (shouldSpoofForBundle(bundleID)) {
            // Use direct check instead of manager
            if (isSystemBootUUIDEnabled()) {
                NSString *bootUUID = getSpoofedSystemBootUUID();
                if (bootUUID && bootUUID.length > 0) {
                    PXLog(@"[WeaponX] 🔄 Spoofing System Boot UUID with: %@", bootUUID);
                    return bootUUID;
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in stringWithUUID: %@", exception);
    }
    
    // Call original if we're not spoofing
    return %orig;
}

%end

%end // LegacyGenericUUIDInterception

#pragma mark - IOKit Platform UUID Hooks

// Hook the IOKit function to intercept platform UUID requests
%hookf(CFTypeRef, IORegistryEntryCreateCFProperty, io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    @try {
        // Check if we're looking for the platform UUID
        if (key && [(__bridge NSString *)key isEqualToString:@"IOPlatformUUID"]) {
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            
            if (shouldSpoofForBundle(bundleID)) {
                // Use direct check instead of manager
                if (isSystemBootUUIDEnabled()) {
                    NSString *bootUUID = getSpoofedSystemBootUUID();
                    if (bootUUID && bootUUID.length > 0) {
                        PXLog(@"[WeaponX] 🔄 Spoofing IOPlatformUUID with: %@", bootUUID);
                        return (__bridge_retained CFStringRef)bootUUID;
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in IORegistryEntryCreateCFProperty: %@", exception);
    }
    
    return %orig;
}

// Hook IORegistryEntryCreateCFProperties to intercept multiple properties at once
%hookf(IOReturn, IORegistryEntryCreateCFProperties, io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, IOOptionBits options) {
    IOReturn result = %orig;
    
    @try {
        // If successful and we get properties back
        if (result == kIOReturnSuccess && properties && *properties) {
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            
            if (shouldSpoofForBundle(bundleID)) {
                // Use direct check instead of manager
                if (isSystemBootUUIDEnabled()) {
                    NSMutableDictionary *props = (__bridge NSMutableDictionary *)*properties;
                    
                    // Check if the dictionary has IOPlatformUUID
                    if (props[@"IOPlatformUUID"]) {
                        NSString *bootUUID = getSpoofedSystemBootUUID();
                        if (bootUUID && bootUUID.length > 0) {
                            PXLog(@"[WeaponX] 🔄 Spoofing IOPlatformUUID in properties with: %@", bootUUID);
                            props[@"IOPlatformUUID"] = bootUUID;
                        }
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in IORegistryEntryCreateCFProperties: %@", exception);
    }
    
    return result;
}

#pragma mark - Dyld Cache UUID Hooks

// Function pointer for _dyld_get_shared_cache_uuid
static bool (*orig_dyld_get_shared_cache_uuid)(uuid_t uuid_out) = NULL;

// Replacement function for _dyld_get_shared_cache_uuid
static bool replaced_dyld_get_shared_cache_uuid(uuid_t uuid_out) {
    @try {
        // First check if we need to spoof at all
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!shouldSpoofForBundle(bundleID) || !isDyldCacheUUIDEnabled() || !uuid_out) {
            // Call original if we're not spoofing
            if (orig_dyld_get_shared_cache_uuid) {
                return orig_dyld_get_shared_cache_uuid(uuid_out);
            }
            return false;
        }
        
        NSString *dyldUUID = getSpoofedDyldCacheUUID();
        NSUUID *uuid = dyldUUID ? [[NSUUID alloc] initWithUUIDString:dyldUUID] : nil;
        if (uuid) {
            [uuid getUUIDBytes:uuid_out];
            return true;
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in replaced_dyld_get_shared_cache_uuid: %@", exception);
    }
    
    // Call original if spoofing failed
    if (orig_dyld_get_shared_cache_uuid) {
        return orig_dyld_get_shared_cache_uuid(uuid_out);
    }
    
    return false;
}

// Additional hook for dyld_get_all_image_infos which can be used to get dyld cache info
static const struct dyld_all_image_infos* (*orig_dyld_get_all_image_infos)(void) = NULL;

// Version of the struct with only the fields we need to copy
typedef struct {
    uint32_t version;
    uint32_t infoArrayCount;
    const void* infoArray;
    const void* notification;
    bool processDetachedFromSharedRegion;
    bool libSystemInitialized;
    const void* dyldImageLoadAddress;
    void* jitInfo;
    const void* dyldVersion;
    const void* errorMessage;
    uintptr_t terminationFlags;
    void* coreSymbolicationShmPage;
    uintptr_t systemOrderFlag;
    uintptr_t uuidArrayCount;
    const void* uuidArray;
    const void* dyldAllImageInfosAddress;
    uintptr_t initialImageCount;
    uintptr_t errorKind;
    const void* errorClientOfDylibPath;
    const void* errorTargetDylibPath;
    const void* errorSymbol;
    const uuid_t* sharedCacheUUID;
    // Remaining fields are not needed for our spoofing
} simplified_dyld_all_image_infos;

// Create a thread-local storage for per-thread cache to avoid "1 image on all image" problem
static NSMutableDictionary *threadLocalCaches() {
    static NSMutableDictionary *allCaches = nil;
    static dispatch_once_t onceToken;
    static NSLock *cachesLock = nil;
    
    dispatch_once(&onceToken, ^{
        allCaches = [NSMutableDictionary dictionary];
        cachesLock = [[NSLock alloc] init];
    });
    
    [cachesLock lock];
    
    // Get current thread ID
    NSString *threadKey = [NSString stringWithFormat:@"%p", (void *)pthread_self()];
    NSMutableDictionary *threadCache = allCaches[threadKey];
    
    if (!threadCache) {
        threadCache = [NSMutableDictionary dictionary];
        allCaches[threadKey] = threadCache;
    }
    
    [cachesLock unlock];
    return threadCache;
}

// Create a copy of the image infos structure with spoofed UUID
static const struct dyld_all_image_infos* replaced_dyld_get_all_image_infos(void) {
    @try {
        const struct dyld_all_image_infos *original = orig_dyld_get_all_image_infos();
        if (!original) return NULL;
        
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        if (shouldSpoofForBundle(bundleID)) {
            // Use direct check instead of manager
            // The compiler warns about comparing sharedCacheUUID with NULL because it's an array pointer
            // Instead, we'll check if the version is high enough to safely access this field
            if (isDyldCacheUUIDEnabled() && original->version >= 15) {
                NSString *dyldUUID = getSpoofedDyldCacheUUID();
                if (!dyldUUID) return original;

                // Get thread-local storage for this image info
                NSMutableDictionary *threadCache = threadLocalCaches();
                NSString *cacheKey = [NSString stringWithFormat:@"image_info_%@", bundleID];
                
                // Check if we already have a cached struct for this thread + bundle
                NSDictionary *cachedInfo = threadCache[cacheKey];
                id cachedUUIDObj = threadCache[[NSString stringWithFormat:@"uuid_%@", bundleID]];
                uuid_t *cachedUUIDPtr = NULL;
                if (cachedUUIDObj) {
                    cachedUUIDPtr = (uuid_t *)[cachedUUIDObj pointerValue];
                }
                
                // Only create a new struct if needed
                if (cachedInfo && cachedUUIDPtr) {
                    // Update last access time
                    NSMutableDictionary *updatedCache = [cachedInfo mutableCopy];
                    [updatedCache setObject:[NSDate date] forKey:@"lastAccess"];
                    threadCache[cacheKey] = updatedCache;
                    
                    struct dyld_all_image_infos* spoofedInfos = (struct dyld_all_image_infos*)[cachedInfo[@"pointer"] pointerValue];
                    
                    // Replace the UUID in the original struct before returning
                    if (spoofedInfos && spoofedInfos->uuidArray) {
                        if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"15.0")) {
                            // Use proper struct access for dyld_uuid_info
                            struct dyld_uuid_info *uuidInfo = (struct dyld_uuid_info *)spoofedInfos->uuidArray;
                            for (int i = 0; i < original->uuidArrayCount; i++) {
                                // Use direct access to uuid field in dyld_uuid_info struct
                                if (cachedUUIDPtr) {
                                    memcpy((void*)uuidInfo[i].imageUUID, cachedUUIDPtr, sizeof(uuid_t));
                                }
                            }
                        } else {
                            // For older iOS versions
                            struct dyld_uuid_info *uuidInfo = (struct dyld_uuid_info *)spoofedInfos->uuidArray;
                            if (cachedUUIDPtr) {
                                memcpy((void*)uuidInfo[0].imageUUID, cachedUUIDPtr, sizeof(uuid_t));
                            }
                        }
                    }
                    
                    return (const struct dyld_all_image_infos*)spoofedInfos;
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in replaced_dyld_get_all_image_infos: %@", exception);
    }
    
    return orig_dyld_get_all_image_infos();
}

#pragma mark - Additional System UUID Methods

// Hook for gethostuuid system call
static int (*orig_gethostuuid)(uuid_t id, const struct timespec *wait);

static int replaced_gethostuuid(uuid_t id, const struct timespec *wait) {
    @try {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        if (shouldSpoofForBundle(bundleID) && isSystemBootUUIDEnabled()) {
            NSString *bootUUID = getSpoofedSystemBootUUID();
            if (bootUUID && bootUUID.length > 0) {
                // Convert string UUID to bytes
                NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:bootUUID];
                if (uuid) {
                    [uuid getUUIDBytes:id];
                    PXLog(@"[WeaponX] 🔄 Spoofing gethostuuid with: %@", bootUUID);
                    return 0; // Success
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in replaced_gethostuuid: %@", exception);
    }
    
    // Call original if we're not spoofing
    if (orig_gethostuuid) {
        return orig_gethostuuid(id, wait);
    }
    
    return -1; // Error
}

// Hook for sysctlbyname for kern.uuid
static int (*orig_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

static int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    @try {
        // Boot/session UUID aliases all resolve to the same persisted virtual session UUID.
        if (name && (strcmp(name, "kern.uuid") == 0 ||
                     strcmp(name, "kern.bootuuid") == 0 ||
                     strcmp(name, "kern.bootsessionuuid") == 0)) {
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            
            if (shouldSpoofForBundle(bundleID) && isSystemBootUUIDEnabled()) {
                NSString *bootUUID = getSpoofedSystemBootUUID();
                if (bootUUID.length > 0 && oldlenp) {
                    const char *uuidCString = bootUUID.UTF8String;
                    size_t requiredLength = strlen(uuidCString) + 1;
                    if (!oldp) {
                        *oldlenp = requiredLength;
                        return 0;
                    }
                    if (*oldlenp < requiredLength) {
                        *oldlenp = requiredLength;
                        errno = ENOMEM;
                        return -1;
                    }
                    memcpy(oldp, uuidCString, requiredLength);
                    *oldlenp = requiredLength;
                    PXLog(@"[WeaponX] 🔄 Spoofing sysctlbyname(%s) with: %@", name, bootUUID);
                    return 0;
                }
            }
        }
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in replaced_sysctlbyname: %@", exception);
    }
    
    // Call original
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static BOOL PXUUIDSysctlByNameHandler(const char *name,
                                      void *oldp,
                                      size_t *oldlenp,
                                      void *newp,
                                      size_t newlen,
                                      int *result) {
    if (!name || (strcmp(name, "kern.uuid") != 0 &&
                  strcmp(name, "kern.bootuuid") != 0 &&
                  strcmp(name, "kern.bootsessionuuid") != 0)) {
        return NO;
    }
    *result = replaced_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    return YES;
}

#pragma mark - Constructor - Additional Hooks Setup

static void setupAdditionalSystemUUIDHooks() {
    @try {
        // Hook gethostuuid system call
        void *libc = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);
        if (libc) {
            void *gethostuuid_sym = dlsym(libc, "gethostuuid");
            if (gethostuuid_sym) {
                int result = EKHook(gethostuuid_sym, 
                                  (void *)replaced_gethostuuid, 
                                  (void **)&orig_gethostuuid);
                
                if (result == 0) {
                    PXLog(@"[WeaponX] ✅ Successfully hooked gethostuuid");
                } else {
                    PXLog(@"[WeaponX] ⚠️ Failed to hook gethostuuid: %d", result);
                }
            } else {
                PXLog(@"[WeaponX] ⚠️ Could not find gethostuuid symbol");
            }
            
            orig_sysctlbyname = PXCallOriginalSysctlByName;
            if (!PXRegisterSysctlByNameHandler(PXUUIDSysctlByNameHandler)) {
                PXLog(@"[WeaponX] ⚠️ Failed to register boot UUID sysctl handler");
            }
            
            dlclose(libc);
        } else {
            PXLog(@"[WeaponX] ⚠️ Failed to open libSystem.B.dylib");
        }
        
    } @catch (NSException *exception) {
        PXLog(@"[WeaponX] ❌ Exception in setupAdditionalSystemUUIDHooks: %@", exception);
    }
}

// Update constructor to initialize the additional hooks
%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        %init;
        NSUserDefaults *legacyUUIDSettings = [[NSUserDefaults alloc]
            initWithSuiteName:@"com.weaponx.securitySettings"];
        if ([legacyUUIDSettings boolForKey:@"legacyGenericUUIDInterceptionEnabled"]) {
            %init(LegacyGenericUUIDInterception);
        }
        // Delay hook initialization to ensure everything is properly set up
        // This helps avoid early hooking that might cause crashes
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // Enhanced process filtering - check if this is a process we should hook
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            NSString *executablePath = [[NSBundle mainBundle] executablePath];
            NSString *processName = [executablePath lastPathComponent];
            
            // Skip for critical system processes to prevent crashes
            // More comprehensive check than before to ensure stability
            if (!bundleID || 
                [processName isEqualToString:@"SpringBoard"] ||
                [processName isEqualToString:@"backboardd"] ||
                [processName isEqualToString:@"assertiond"] ||
                [processName isEqualToString:@"useractivityd"] ||
                [processName isEqualToString:@"apsd"] ||
                [processName containsString:@"daemon"] ||
                [processName containsString:@"assistant"] ||
                [processName containsString:@"locationd"] ||
                [processName containsString:@"powerd"] ||
                [executablePath hasPrefix:@"/usr/libexec/"] ||
                [executablePath hasPrefix:@"/usr/sbin/"] ||
                [executablePath hasPrefix:@"/usr/bin/"] ||
                [executablePath hasPrefix:@"/bin/"] ||
                [executablePath hasPrefix:@"/sbin/"]) {
                PXLog(@"[WeaponX] 🚫 Skipping UUID hooks for system process: %@", processName);
                return;
            }
            
            // Perform a more thorough check for iPad-specific processes that might be causing issues
            UIDevice *device = [UIDevice currentDevice];
            BOOL isIPad = [device userInterfaceIdiom] == UIUserInterfaceIdiomPad;
            
            if (isIPad) {
                // Additional processes to skip on iPad to prevent crashes
                if ([processName isEqualToString:@"sharingd"] ||
                    [processName isEqualToString:@"mediaserverd"] ||
                    [processName isEqualToString:@"searchd"] ||
                    [processName isEqualToString:@"identityservicesd"] ||
                    [processName isEqualToString:@"coreduetd"] ||
                    [processName isEqualToString:@"mobiletimerd"] ||
                    [processName containsString:@"app"] ||
                    [processName containsString:@"ctid"] ||
                    [processName containsString:@"trust"] ||
                    [processName containsString:@"xctest"]) {
                    PXLog(@"[WeaponX] 🚫 Skipping UUID hooks for iPad-specific process: %@", processName);
                    return;
                }
            }
            
            // Check if this app is actually configured for spoofing before initializing hooks
            // This prevents unnecessary hooking in apps not configured in the tweak
            if (!shouldSpoofForBundle(bundleID)) {
                // Most apps will hit this branch and exit immediately
                PXLog(@"[WeaponX] ℹ️ App %@ not configured for UUID spoofing, skipping hooks", bundleID);
                return;
            }
            
            // If we get here, the app is configured for spoofing, so we can initialize the hooks
            
            PXLog(@"[WeaponX] 🚀 Initializing UUID hooks for app: %@ (%@)", bundleID, processName);
            
            // Create a separate try-catch block for each hook to prevent one failure from affecting others
            @try {
                // Set up hook for _dyld_get_shared_cache_uuid
                void *handle = dlopen(NULL, RTLD_GLOBAL);
                if (handle) {
                    // Wrap each hook installation in its own try-catch for isolation
                    @try {
                        orig_dyld_get_shared_cache_uuid = dlsym(handle, "_dyld_get_shared_cache_uuid");
                        
                        if (orig_dyld_get_shared_cache_uuid) {
                            // Use EKHook for hook installation with retry logic
                            int retryCount = 0;
                            int maxRetries = 3;
                            int result = -1;
                            
                            while (result != 0 && retryCount < maxRetries) {
                                result = EKHook(orig_dyld_get_shared_cache_uuid, 
                                            (void *)replaced_dyld_get_shared_cache_uuid, 
                                            (void **)&orig_dyld_get_shared_cache_uuid);
                                
                                if (result == 0) {
                                    PXLog(@"[WeaponX] ✅ Successfully hooked _dyld_get_shared_cache_uuid");
                                } else {
                                    PXLog(@"[WeaponX] ⚠️ Failed to hook _dyld_get_shared_cache_uuid (attempt %d): %d", 
                                        retryCount + 1, result);
                                    retryCount++;
                                    // Small delay before retry
                                    [NSThread sleepForTimeInterval:0.1];
                                }
                            }
                        } else {
                            PXLog(@"[WeaponX] ⚠️ Could not find _dyld_get_shared_cache_uuid symbol");
                        }
                    } @catch (NSException *exception) {
                        PXLog(@"[WeaponX] ❌ Exception when hooking _dyld_get_shared_cache_uuid: %@", exception);
                    }
                    
                    // Separate try-catch for the second hook
                    @try {
                        // Set up hook for dyld_get_all_image_infos
                        orig_dyld_get_all_image_infos = dlsym(handle, "_dyld_get_all_image_infos");
                        
                        if (orig_dyld_get_all_image_infos) {
                            // Use EKHook for hook installation with retry logic
                            int retryCount = 0;
                            int maxRetries = 3;
                            int result = -1;
                            
                            while (result != 0 && retryCount < maxRetries) {
                                result = EKHook(orig_dyld_get_all_image_infos, 
                                            (void *)replaced_dyld_get_all_image_infos, 
                                            (void **)&orig_dyld_get_all_image_infos);
                                
                                if (result == 0) {
                                    PXLog(@"[WeaponX] ✅ Successfully hooked _dyld_get_all_image_infos");
                                } else {
                                    PXLog(@"[WeaponX] ⚠️ Failed to hook _dyld_get_all_image_infos (attempt %d): %d", 
                                        retryCount + 1, result);
                                    retryCount++;
                                    // Small delay before retry
                                    [NSThread sleepForTimeInterval:0.1];
                                }
                            }
                        } else {
                            PXLog(@"[WeaponX] ⚠️ Could not find _dyld_get_all_image_infos symbol");
                        }
                    } @catch (NSException *exception) {
                        PXLog(@"[WeaponX] ❌ Exception when hooking _dyld_get_all_image_infos: %@", exception);
                    }
                    
                    dlclose(handle);
                } else {
                    PXLog(@"[WeaponX] ⚠️ Failed to open dynamic linker handle");
                }
            } @catch (NSException *exception) {
                PXLog(@"[WeaponX] ❌ Exception in UUID hooks setup: %@", exception);
            }
            
            PXLog(@"[WeaponX] ✅ UUID hooks initialization complete for %@", bundleID);
            
            // Add after initializing hooks for _dyld_get_shared_cache_uuid and _dyld_get_all_image_infos
            @try {
                // If this app is configured for spoofing and UUIDs are enabled, set up additional hooks
                if (shouldSpoofForBundle(bundleID)) {
                    setupAdditionalSystemUUIDHooks();
                }
            } @catch (NSException *exception) {
                PXLog(@"[WeaponX] ❌ Exception in additional hooks setup: %@", exception);
            }
        });
    }
}
