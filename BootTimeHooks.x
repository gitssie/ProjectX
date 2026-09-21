#import "ProjectX.h"
#import "UptimeManager.h"
#import "ProfileManager.h"
#import "ProjectXLogging.h"
#import "PXRootHidePath.h"
#import "PXProcessHookPolicy.h"
#import "IdentifierManager.h"
#import "PXSysctlHookRouter.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/mach_host.h>
#import <substrate.h>
#import <ellekit/ellekit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// Define the boot time structure for sysctl calls
struct timeval_boot {
    time_t tv_sec;
    suseconds_t tv_usec;
};

// Original function pointers - ONLY for system calls
static int (*orig_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*orig_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

// Cache for spoofed values to improve performance
static NSDate *cachedBootTime = nil;
static NSTimeInterval cachedUptime = 0;
static NSString *cachedProfilePath = nil;
static NSDate *cacheTimestamp = nil;
static const NSTimeInterval kCacheValidityDuration = 30.0; // 30 seconds cache

// Path to scoped apps plist
#define kScopedAppsPath PXGlobalScopePreferencesPath()

// Scoped apps cache
static NSMutableDictionary *scopedAppsCache = nil;
static NSDate *scopedAppsCacheTimestamp = nil;
static const NSTimeInterval kScopedAppsCacheValidDuration = 30.0; // 30 seconds

// Global flag to track if hooks are installed
static BOOL hooksInstalled = NO;

// Forward declarations
static BOOL shouldSpoofBootTimeForApp(void);
static NSString *getCurrentProfilePath(void);
static void updateCachedBootTimeValues(void);
static void logBootTimeAccess(const char *method, NSString *bundleID);
static NSString *getCurrentBundleID(void);
static NSDictionary *loadScopedApps(void) __attribute__((unused));
static BOOL isInScopedAppsList(void);
static void installSystemCallHooks(void);
static BOOL isBootTimeOrUptimeEnabled(void);

#pragma mark - Helper Functions

// Get the current bundle ID
static NSString *getCurrentBundleID(void) {
    @try {
        NSBundle *mainBundle = [NSBundle mainBundle];
        if (!mainBundle) {
            return nil;
        }
        return [mainBundle bundleIdentifier];
    } @catch (NSException *e) {
        return nil;
    }
}

// Load scoped apps from the plist file
static NSDictionary *loadScopedApps(void) {
    @try {
        // Check if cache is valid
        if (scopedAppsCache && scopedAppsCacheTimestamp && 
            [[NSDate date] timeIntervalSinceDate:scopedAppsCacheTimestamp] < kScopedAppsCacheValidDuration) {
            return scopedAppsCache;
        }
        
        // Initialize cache if needed
        if (!scopedAppsCache) {
            scopedAppsCache = [NSMutableDictionary dictionary];
        } else {
            [scopedAppsCache removeAllObjects];
        }
        
        // Try each possible path for the scoped apps file
        NSArray *possiblePaths = @[kScopedAppsPath];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *validPath = nil;
        
        for (NSString *path in possiblePaths) {
            if ([fileManager fileExistsAtPath:path]) {
                validPath = path;
                break;
            }
        }
        
        if (!validPath) {
            // Don't log this error too frequently to avoid spam
            static NSDate *lastErrorLog = nil;
            if (!lastErrorLog || [[NSDate date] timeIntervalSinceDate:lastErrorLog] > 300.0) { // 5 minutes
                PXLog(@"[BootTimeHooks] Could not find scoped apps file");
                lastErrorLog = [NSDate date];
            }
            scopedAppsCacheTimestamp = [NSDate date];
            return scopedAppsCache;
        }
        
        // Load the plist file safely
        NSDictionary *plistDict = [NSDictionary dictionaryWithContentsOfFile:validPath];
        if (!plistDict || ![plistDict isKindOfClass:[NSDictionary class]]) {
            scopedAppsCacheTimestamp = [NSDate date];
            return scopedAppsCache;
        }
        
        // Get the scoped apps dictionary
        NSDictionary *scopedApps = plistDict[@"ScopedApps"];
        if (!scopedApps || ![scopedApps isKindOfClass:[NSDictionary class]]) {
            scopedAppsCacheTimestamp = [NSDate date];
            return scopedAppsCache;
        }
        
        // Copy the scoped apps to our cache
        [scopedAppsCache addEntriesFromDictionary:scopedApps];
        scopedAppsCacheTimestamp = [NSDate date];
        
        return scopedAppsCache;
        
    } @catch (NSException *e) {
        scopedAppsCacheTimestamp = [NSDate date];
        return scopedAppsCache ?: [NSMutableDictionary dictionary];
    }
}

// Check if the current app is in the scoped apps list
static BOOL isInScopedAppsList(void) {
    @try {
        NSString *bundleID = getCurrentBundleID();
        return bundleID.length > 0 &&
            [[IdentifierManager sharedManager] shouldSpoofForBundle:bundleID];
    } @catch (NSException *e) {
        return NO;
    }
}

// Check if boot time spoofing should be applied for the current app
static BOOL shouldSpoofBootTimeForApp(void) {
    @try {
        return isInScopedAppsList();
    } @catch (NSException *e) {
        return NO;
    }
}

// Get the current profile path for spoofed values
static NSString *getCurrentProfilePath(void) {
    @try {
        ProfileManager *profileManager = [ProfileManager sharedManager];
        if (!profileManager) return nil;
        
        Profile *currentProfile = [profileManager currentProfile];
        if (!currentProfile) return nil;
        
        // Use the hardcoded profiles directory path since profilesDirectory is private
        NSString *profilesDir = PXProfilesDirectoryPath();
        return [profilesDir stringByAppendingPathComponent:currentProfile.profileId];
    } @catch (NSException *e) {
        return nil;
    }
}

// Update cached boot time values from profile data
static void updateCachedBootTimeValues(void) {
    @try {
        NSString *profilePath = getCurrentProfilePath();
        if (!profilePath) {
            // Don't log this too frequently
            static NSDate *lastLog = nil;
            if (!lastLog || [[NSDate date] timeIntervalSinceDate:lastLog] > 300.0) {
                PXLog(@"[BootTimeHooks] ⚠️ No profile path available");
                lastLog = [NSDate date];
            }
            return;
        }
        
        // Check if cache is still valid
        if (cachedBootTime && cacheTimestamp && cachedProfilePath && 
            [cachedProfilePath isEqualToString:profilePath] &&
            [[NSDate date] timeIntervalSinceDate:cacheTimestamp] < kCacheValidityDuration) {
            return; // Cache is still valid
        }
        
        UptimeManager *uptimeManager = [UptimeManager sharedManager];
        if (!uptimeManager) return;
        
        // Get spoofed boot time and uptime
        NSDate *bootTime = [uptimeManager currentBootTimeForProfile:profilePath];
        NSTimeInterval uptime = [uptimeManager currentUptimeForProfile:profilePath];
        
        if (!bootTime || uptime <= 0) {
            [uptimeManager generateConsistentUptimeAndBootTimeForProfile:profilePath];
            bootTime = [uptimeManager currentBootTimeForProfile:profilePath];
            uptime = [uptimeManager currentUptimeForProfile:profilePath];
        }
        
        // Validate the data before caching
        if (bootTime && uptime > 0) {
            cachedBootTime = bootTime;
            cachedUptime = uptime;
            cachedProfilePath = profilePath;
            cacheTimestamp = [NSDate date];
        }
        
    } @catch (NSException *e) {
        // Silent failure to avoid crashes
    }
}

// Log boot time access attempts for debugging
static void logBootTimeAccess(const char *method, NSString *bundleID) {
    @try {
        static NSMutableSet *loggedMethods = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            loggedMethods = [NSMutableSet set];
        });
        
        if (!method || !bundleID) return;
        
        NSString *methodKey = [NSString stringWithFormat:@"%s:%@", method, bundleID];
        if (![loggedMethods containsObject:methodKey]) {
            [loggedMethods addObject:methodKey];
            PXLog(@"[BootTimeHooks] 🕵️ App %@ accessed boot time via %s", bundleID, method);
        }
    } @catch (NSException *e) {
        // Silent failure
    }
}

// Helper to check if a spoof identifier is enabled for the current profile
static BOOL isBootTimeOrUptimeEnabled(void) {
    @try {
        // Dynamically get IdentifierManager class and sharedManager
        Class managerClass = NSClassFromString(@"IdentifierManager");
        if (!managerClass) return NO;
        id manager = [managerClass respondsToSelector:@selector(sharedManager)] ? [managerClass sharedManager] : nil;
        if (!manager) return NO;
        
        SEL isEnabledSel = NSSelectorFromString(@"isIdentifierEnabled:");
        if (![manager respondsToSelector:isEnabledSel]) return NO;
        
        BOOL bootTimeEnabled = NO;
        BOOL uptimeEnabled = NO;
        NSString *bootTimeStr = @"BootTime";
        NSString *uptimeStr = @"SystemUptime";
        NSMethodSignature *sig = [manager methodSignatureForSelector:isEnabledSel];
        if (sig) {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
            [invocation setSelector:isEnabledSel];
            [invocation setTarget:manager];
            // BootTime
            [invocation setArgument:&bootTimeStr atIndex:2];
            [invocation invoke];
            [invocation getReturnValue:&bootTimeEnabled];
            // SystemUptime
            [invocation setArgument:&uptimeStr atIndex:2];
            [invocation invoke];
            [invocation getReturnValue:&uptimeEnabled];
        }
        return bootTimeEnabled || uptimeEnabled;
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - System Call Hooks

// Hook sysctl() for KERN_BOOTTIME queries - ONLY method that App Store apps commonly use
int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    @try {
        // Check if this is a KERN_BOOTTIME query
        if (namelen >= 2 && name && name[0] == CTL_KERN && name[1] == KERN_BOOTTIME) {
            if (shouldSpoofBootTimeForApp() && isBootTimeOrUptimeEnabled()) {
                NSString *bundleID = getCurrentBundleID();
                if (bundleID) {
                    logBootTimeAccess("sysctl(KERN_BOOTTIME)", bundleID);
                }
                updateCachedBootTimeValues();
                if (cachedBootTime && oldp && oldlenp && *oldlenp >= sizeof(struct timeval)) {
                    struct timeval boottime;
                    boottime.tv_sec = (time_t)[cachedBootTime timeIntervalSince1970];
                    boottime.tv_usec = 0;
                    memcpy(oldp, &boottime, sizeof(boottime));
                    *oldlenp = sizeof(boottime);
                    return 0; // Success
                }
            }
        }
    } @catch (NSException *e) {
        // Silent failure, pass through to original
    }
    // Call original function for all other cases
    if (orig_sysctl) {
        return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    }
    return -1;
}

// Hook sysctlbyname() for "kern.boottime" queries - ONLY method that App Store apps commonly use
int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    @try {
        if (name && strcmp(name, "kern.boottime") == 0) {
            if (shouldSpoofBootTimeForApp() && isBootTimeOrUptimeEnabled()) {
                NSString *bundleID = getCurrentBundleID();
                if (bundleID) {
                    logBootTimeAccess("sysctlbyname(kern.boottime)", bundleID);
                }
                updateCachedBootTimeValues();
                if (cachedBootTime && oldp && oldlenp && *oldlenp >= sizeof(struct timeval)) {
                    struct timeval boottime;
                    boottime.tv_sec = (time_t)[cachedBootTime timeIntervalSince1970];
                    boottime.tv_usec = 0;
                    memcpy(oldp, &boottime, sizeof(boottime));
                    *oldlenp = sizeof(boottime);
                    return 0; // Success
                }
            }
        }
    } @catch (NSException *e) {
        // Silent failure, pass through to original
    }
    // Call original function for all other cases
    if (orig_sysctlbyname) {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    return -1;
}

static BOOL PXBootTimeSysctlByNameHandler(const char *name,
                                          void *oldp,
                                          size_t *oldlenp,
                                          void *newp,
                                          size_t newlen,
                                          int *result) {
    if (!name || strcmp(name, "kern.boottime") != 0) return NO;
    *result = hook_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    return YES;
}

// Hook for -[NSProcessInfo systemUptime]
static NSTimeInterval (*orig_systemUptime)(NSProcessInfo *, SEL);
static NSTimeInterval hook_systemUptime(NSProcessInfo *self, SEL _cmd) {
    if (shouldSpoofBootTimeForApp() && isBootTimeOrUptimeEnabled()) {
        updateCachedBootTimeValues();
        if (cachedUptime > 0) {
            return cachedUptime;
        }
    }
    return orig_systemUptime(self, _cmd);
}

// Install system call hooks ONLY for scoped apps
static void installSystemCallHooks(void) {
    @try {
        if (hooksInstalled) {
            return; // Already installed
        }
        
        orig_sysctlbyname = PXCallOriginalSysctlByName;
        BOOL hookingSuccess = PXRegisterSysctlByNameHandler(PXBootTimeSysctlByNameHandler);
        
        // Try ElleKit first (preferred for rootless jailbreaks)
        if (EKIsElleKitEnv() || dlsym(RTLD_DEFAULT, "EKHook")) {
            // Hook sysctl
            void *sysctlPtr = dlsym(RTLD_DEFAULT, "sysctl");
            if (sysctlPtr && EKHook(sysctlPtr, (void *)hook_sysctl, (void **)&orig_sysctl) == 0) {
                hookingSuccess = YES;
            }
            
        } else if (dlsym(RTLD_DEFAULT, "MSHookFunction")) {
            // Fallback to Substrate
            void *sysctlPtr = dlsym(RTLD_DEFAULT, "sysctl");
            if (sysctlPtr) {
                MSHookFunction(sysctlPtr, (void *)hook_sysctl, (void **)&orig_sysctl);
                hookingSuccess = YES;
            }
            
        }
        
        if (hookingSuccess) {
            hooksInstalled = YES;
            NSString *bundleID = getCurrentBundleID();
            PXLog(@"[BootTimeHooks] ✅ System call hooks installed for scoped app: %@", bundleID);
            // Add systemUptime hook for NSProcessInfo
            Class procInfoClass = objc_getClass("NSProcessInfo");
            if (procInfoClass) {
                MSHookMessageEx(procInfoClass, @selector(systemUptime), (IMP)hook_systemUptime, (IMP *)&orig_systemUptime);
            }
        }
        
    } @catch (NSException *e) {
        PXLog(@"[BootTimeHooks] ❌ Exception installing hooks: %@", e);
    }
}

#pragma mark - Initialization

// COMPLETELY REMOVED ALL %hook DIRECTIVES - NO MORE OBJECTIVE-C METHOD HOOKS
// This eliminates crashes in non-scoped apps

%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        @try {
            NSString *bundleID = getCurrentBundleID();
            
            // Skip if we can't get bundle ID
            if (!bundleID || [bundleID length] == 0) {
                return;
            }
            
            // CRITICAL: Only install hooks if this app is actually scoped
            if (!isInScopedAppsList()) {
                // App is NOT scoped - no hooks, no interference, no crashes
                return;
            }
            
            PXLog(@"[BootTimeHooks] 🎯 Installing minimal system call hooks for scoped app: %@", bundleID);
            
            // Install the minimal system call hooks that App Store apps actually use immediately
            installSystemCallHooks();
            
        } @catch (NSException *e) {
            // Silent failure to prevent crashes
        }
    }
} 
