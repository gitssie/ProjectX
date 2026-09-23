#import "IdentifierManager.h"
#import "DeviceModelManager.h"
#import "IDFAManager.h"
#import "IDFVManager.h"
#import "DeviceNameManager.h"
#import "SerialNumberManager.h"
#import "IOSVersionInfo.h"
#import "ProjectXLogging.h"
#import "PXRootHidePath.h"
#import "PXScopedAppStore.h"
#import "WiFiManager.h"
#import "StorageManager.h"
#import "BatteryManager.h"
#import "SystemUUIDManager.h"
#import "DyldCacheUUIDManager.h"
#import "PasteboardUUIDManager.h"
#import "KeychainUUIDManager.h"
#import "UserDefaultsUUIDManager.h"
#import "UptimeManager.h"
#import "CoreDataUUIDManager.h"
#import "NetworkIdentity.h"
#import "AppIdentity.h"
#import "ProfileManifest.h"
#import "RegionIdentity.h"
#import "TrustedCarrierPolicy.h"
#import "LocationSpoofingManager.h"
#import "PXEnvironmentModelSelection.h"
#import "PXEnvironmentPolicy.h"
#import <Security/Security.h>

@interface LSApplicationWorkspace
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface LSApplicationProxy
+ (id)applicationProxyForIdentifier:(id)identifier;
@property(readonly) NSString *applicationIdentifier;
@property(readonly) NSString *localizedName;
@property(readonly) NSString *shortVersionString;
@property(readonly) NSString *bundleVersion;
@end

@interface IdentifierManager ()
@property (nonatomic, strong) NSMutableDictionary *settings;
@property (nonatomic, strong) NSMutableDictionary *scopedApps;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSMutableDictionary *spoofCache;
- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedAppsSnapshot;
- (void)publishScopedAppsSnapshot:
    (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApps;
- (BOOL)writeScopedApps:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApps
                  error:(NSError **)error;
- (BOOL)persistAndPublishScopedAppsSnapshot:
            (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApps
                                      error:(NSError **)error;
@end

static NSMutableDictionary *_appEnabledCache = nil;
static NSTimeInterval _cacheExpirationTime = 30.0;

static NSArray<NSString *> *PXScopeKeysMatchingBundleIdentifier(
    NSDictionary<NSString *, id> *scopedApps,
    NSString *bundleIdentifier
) {
    if (bundleIdentifier.length == 0) {
        return @[];
    }
    NSString *normalizedBundleIdentifier = bundleIdentifier.lowercaseString;
    NSMutableArray<NSString *> *matchingKeys = [NSMutableArray array];
    for (id key in scopedApps) {
        if ([key isKindOfClass:[NSString class]] &&
            [[(NSString *)key lowercaseString] isEqualToString:normalizedBundleIdentifier]) {
            [matchingKeys addObject:key];
        }
    }
    return [matchingKeys copy];
}

static NSDictionary<NSString *, id> *PXScopeRecordForBundleIdentifier(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopedApps,
    NSString *bundleIdentifier
) {
    NSString *matchingKey = PXScopeKeysMatchingBundleIdentifier(scopedApps,
                                                                 bundleIdentifier).firstObject;
    return matchingKey ? scopedApps[matchingKey] : nil;
}

static void PXIdentifierManagerScopedAppsChanged(CFNotificationCenterRef center,
                                                 void *observer,
                                                 CFStringRef name,
                                                 const void *object,
                                                 CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;
    IdentifierManager *manager = (__bridge IdentifierManager *)observer;
    [manager reloadApplicationScope];
}

@implementation IdentifierManager

#pragma mark - Device Model

- (NSString *)generateDeviceModel {
    NSError *generationError = nil;
    if (![self regenerateAllEnabledIdentifiersWithError:&generationError]) {
        self.error = generationError;
        return nil;
    }
    return [self currentValueForIdentifier:@"DeviceModel"];
}

- (BOOL)setCustomDeviceModel:(NSString *)value {
    DeviceModelManager *deviceManager = [DeviceModelManager sharedManager];
    NSDictionary<NSString *, id> *selectedRecord = nil;
    for (NSDictionary<NSString *, id> *record in [deviceManager allDeviceSpecificationRecords]) {
        if ([record[@"identifier"] isEqualToString:value]) {
            selectedRecord = record;
            break;
        }
    }
    if (!selectedRecord) {
        self.error = [NSError errorWithDomain:@"com.hydra.projectx" code:2003
            userInfo:@{NSLocalizedDescriptionKey: @"Invalid Device Model"}];
        return NO;
    }
    NSError *generationError = nil;
    PXEnvironmentPolicyStore *policy = [PXEnvironmentPolicyStore sharedStore];
    if (![policy saveSelectedModelRecord:selectedRecord
                      physicalModelRecord:[deviceManager physicalDeviceSpecificationRecord]
                  hostGraphicsCapabilities:PXCurrentGraphicsHostCapabilities()
                                    error:&generationError] ||
        ![self regenerateAllEnabledIdentifiersWithError:&generationError]) {
        self.error = generationError;
        return NO;
    }
    return YES;
}

+ (instancetype)sharedManager {
    static IdentifierManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
        [sharedManager loadSettings];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)sharedManager,
                                        PXIdentifierManagerScopedAppsChanged,
                                        CFSTR("com.hydra.projectx.scopedAppsChanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    return sharedManager;
}

- (instancetype)init {
    if (self = [super init]) {
        _settings = [NSMutableDictionary dictionary];
        _scopedApps = [NSMutableDictionary dictionary];
        _spoofCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedAppsSnapshot {
    @synchronized(self) {
        return [self.scopedApps copy] ?: @{};
    }
}

- (void)publishScopedAppsSnapshot:
    (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApps {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *eligibleScopedApps =
        PXEligibleScopedApplications(scopedApps ?: @{});
    @synchronized(self) {
        self.scopedApps = [eligibleScopedApps mutableCopy];
        [_appEnabledCache removeAllObjects];
        [self.spoofCache removeAllObjects];
    }
}

- (BOOL)persistAndPublishScopedAppsSnapshot:
            (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApps
                                      error:(NSError **)error {
    @synchronized(self) {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *eligibleScopedApps =
        PXEligibleScopedApplications(scopedApps ?: @{});
    if (![self writeScopedApps:eligibleScopedApps error:error]) {
        return NO;
    }
    [self publishScopedAppsSnapshot:eligibleScopedApps];
    return YES;
    }
}

#pragma mark - Profile Integration

- (NSString *)profileIdentityPath {
    return PXCurrentProfileIdentityValuesPath();
}

#pragma mark - Identifier Management

- (NSString *)generateIDFA {
    self.error = nil;
    NSString *value = [[IDFAManager sharedManager] generateIDFA];
    if (!value) {
        self.error = [[IDFAManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"IDFA"] ? value : nil;
}

- (NSString *)generateIDFV {
    self.error = nil;
    NSString *value = [[IDFVManager sharedManager] generateIDFV];
    if (!value) {
        self.error = [[IDFVManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"IDFV"] ? value : nil;
}

- (NSString *)generateDeviceName {
    self.error = nil;
    NSString *value = [[DeviceNameManager sharedManager] generateDeviceName];
    if (!value) {
        self.error = [[DeviceNameManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"DeviceName"] ? value : nil;
}

- (NSString *)generateSerialNumber {
    self.error = nil;
    NSString *value = [[SerialNumberManager sharedManager] generateSerialNumber];
    if (!value) {
        self.error = [[SerialNumberManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"SerialNumber"] ? value : nil;
}

- (NSDictionary *)generateIOSVersion {
    NSError *generationError = nil;
    if (![self regenerateAllEnabledIdentifiersWithError:&generationError]) {
        self.error = generationError;
        return nil;
    }
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:[self profileIdentityPath]];
    NSError *readError = nil;
    PXProfileManifest *manifest = [store activeManifestWithError:&readError];
    self.error = readError;
    return manifest.operatingSystem;
}

- (NSDictionary *)generateiOSVersion {
    return [self generateIOSVersion];
}

- (NSString *)generateSystemBootUUID {
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:[self profileIdentityPath]];
    NSError *readError = nil;
    PXProfileManifest *manifest = [store activeManifestWithError:&readError];
    self.error = readError;
    return manifest.virtualSession.bootUUID;
}

- (NSString *)generateDyldCacheUUID {
    self.error = nil;
    NSString *value = [[DyldCacheUUIDManager sharedManager] generateDyldCacheUUID];
    if (!value) {
        self.error = [[DyldCacheUUIDManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"DyldCacheUUID"] ? value : nil;
}

- (NSString *)generatePasteboardUUID {
    self.error = nil;
    NSString *value = [[PasteboardUUIDManager sharedManager] generatePasteboardUUID];
    if (!value) {
        self.error = [[PasteboardUUIDManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"PasteboardUUID"] ? value : nil;
}

- (NSString *)generateKeychainUUID {
    self.error = nil;
    NSString *value = [[KeychainUUIDManager sharedManager] generateKeychainUUID];
    if (!value) {
        self.error = [[KeychainUUIDManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"KeychainUUID"] ? value : nil;
}

- (NSString *)generateUserDefaultsUUID {
    self.error = nil;
    NSString *value = [[UserDefaultsUUIDManager sharedManager] generateUserDefaultsUUID];
    if (!value) {
        self.error = [[UserDefaultsUUIDManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"UserDefaultsUUID"] ? value : nil;
}

- (NSString *)generateAppGroupUUID {
    self.error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"App Group identities are managed per entitlement group"}];
    return nil;
}

- (NSString *)generateCoreDataUUID {
    self.error = nil;
    NSString *value = [[CoreDataUUIDManager sharedManager] generateCoreDataUUID];
    if (!value) {
        self.error = [[CoreDataUUIDManager sharedManager] lastError];
        return nil;
    }
    return [self saveCustomValue:value forType:@"CoreDataUUID"] ? value : nil;
}

- (NSString *)generateSystemUptime {
    NSTimeInterval uptime = [[UptimeManager sharedManager] currentUptime];
    if (uptime <= 0) {
        self.error = [[UptimeManager sharedManager] lastError];
        return nil;
    }
    return [NSString stringWithFormat:@"%.2f hours", uptime / 3600.0];
}

- (NSString *)generateBootTime {
    NSDate *bootTime = [[UptimeManager sharedManager] currentBootTime];
    if (!bootTime) {
        self.error = [[UptimeManager sharedManager] lastError];
        return nil;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    return [formatter stringFromDate:bootTime];
}

- (NSString *)generateAppInstallUUID {
    self.error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"App Install identities are managed per Scoped App"}];
    return nil;
}

- (NSString *)generateAppContainerUUID {
    self.error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"App Container identities are managed per bundle"}];
    return nil;
}

- (void)regenerateAllEnabledIdentifiers {
    NSError *generationError = nil;
    if (![self regenerateAllEnabledIdentifiersWithError:&generationError]) {
        self.error = generationError;
        PXLog(@"[WeaponX] Profile generation failed: %@", generationError.localizedDescription);
    }
}

- (BOOL)regenerateAllEnabledIdentifiersWithError:(NSError **)error {
    NSString *identityDirectory = [self profileIdentityPath];
    if (!identityDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.hydra.projectx.profile-manifest"
                                         code:100
                                     userInfo:@{NSLocalizedDescriptionKey: @"No active Profile identity directory"}];
        }
        return NO;
    }

    return [self regenerateProfileAtIdentityDirectory:identityDirectory error:error];
}

- (BOOL)regenerateProfileAtIdentityDirectory:(NSString *)identityDirectory error:(NSError **)error {
    return [self regenerateProfileAtIdentityDirectory:identityDirectory publishNotifications:YES error:error];
}

- (BOOL)regenerateProfileAtIdentityDirectory:(NSString *)identityDirectory
                         publishNotifications:(BOOL)publishNotifications
                                        error:(NSError **)error {

    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    PXProfileManifest *previousManifest = [store activeManifestWithError:nil];

    PXTrustedCarrierPolicyStore *carrierPolicyStore = [[PXTrustedCarrierPolicyStore alloc] init];
    NSError *carrierPolicyError = nil;
    NSSet<NSString *> *trustedCarrierIDs = [carrierPolicyStore trustedCarrierIDsWithError:&carrierPolicyError];
    if (!trustedCarrierIDs) {
        if (error) *error = carrierPolicyError;
        return NO;
    }

    uint8_t seedBytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(seedBytes), seedBytes) != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.hydra.projectx.profile-manifest"
                                         code:101
                                     userInfo:@{NSLocalizedDescriptionKey: @"Secure Profile seed generation failed"}];
        }
        return NO;
    }

    DeviceModelManager *deviceManager = [DeviceModelManager sharedManager];
    PXEnvironmentPolicyStore *environmentPolicy = [PXEnvironmentPolicyStore sharedStore];
    NSError *environmentPolicyError = nil;
    NSDictionary<NSString *, id> *graphicsHostCapabilities = PXCurrentGraphicsHostCapabilities();
    NSDictionary<NSString *, id> *physicalModelRecord =
        [deviceManager physicalDeviceSpecificationRecord];
    NSDictionary<NSString *, id> *selectedModelRecord = PXResolveEnvironmentModelSelection(
        environmentPolicy,
        [deviceManager allDeviceSpecificationRecords],
        physicalModelRecord,
        graphicsHostCapabilities,
        nil,
        &environmentPolicyError);
    if (!selectedModelRecord || environmentPolicyError) {
        if (error) *error = environmentPolicyError;
        return NO;
    }
    PXEnvironmentModelSelectionMode modelSelectionMode = [environmentPolicy
        selectedModelSelectionModeWithError:&environmentPolicyError];
    if (environmentPolicyError) {
        if (error) *error = environmentPolicyError;
        return NO;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *iOSCatalog = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *tuple in [[IOSVersionInfo sharedManager] availableIOSVersions]) {
        NSMutableDictionary<NSString *, id> *enrichedTuple = [tuple mutableCopy];
        enrichedTuple[@"majorVersion"] = @([[tuple[@"version"] componentsSeparatedByString:@"."].firstObject integerValue]);
        [iOSCatalog addObject:[enrichedTuple copy]];
    }

    NSDictionary *configuredLocation = [environmentPolicy configuredLocationWithError:&environmentPolicyError];
    BOOL locationWasCleared = [environmentPolicy locationWasExplicitlyClearedWithError:&environmentPolicyError];
    if (environmentPolicyError) {
        if (error) *error = environmentPolicyError;
        return NO;
    }
    NSDictionary *pinnedLocation = configuredLocation;
    if (!pinnedLocation && !locationWasCleared) {
        pinnedLocation = [[LocationSpoofingManager sharedManager] loadSpoofingLocation];
        if (pinnedLocation.count == 0 && [previousManifest.location[@"pinned"] boolValue]) {
            pinnedLocation = previousManifest.location;
        }
    }

    PXProfileGenerationInput *input = [[PXProfileGenerationInput alloc] init];
    input.seed = [NSData dataWithBytes:seedBytes length:sizeof(seedBytes)];
    input.generatedAt = [NSDate date];
    input.modelCatalog = @[selectedModelRecord];
    input.physicalModelRecord = physicalModelRecord ?: @{};
    input.usesPhysicalDeviceModel =
        modelSelectionMode == PXEnvironmentModelSelectionModePhysicalDevice;
    input.iOSCatalog = [iOSCatalog copy];
    input.carrierCatalog = PXCarrierCatalog();
    input.trustedCarrierIDs = trustedCarrierIDs;
    input.pinnedLocation = pinnedLocation ?: @{};
    NSString *selectedCarrierID = [trustedCarrierIDs.allObjects
        sortedArrayUsingSelector:@selector(compare:)].firstObject;
    NSDictionary<NSString *, id> *selectedCarrier = nil;
    for (NSDictionary<NSString *, id> *carrier in PXCarrierCatalog()) {
        if ([carrier[@"carrierID"] isEqualToString:selectedCarrierID]) {
            selectedCarrier = carrier;
            break;
        }
    }
    PXRegionIdentity *pendingRegion = selectedCarrier
        ? PXRegionIdentityForCountryCode(selectedCarrier[@"isoCountryCode"],
            [selectedCarrierID dataUsingEncoding:NSUTF8StringEncoding])
        : nil;
    input.region = pendingRegion ? [pendingRegion propertyListRepresentation] : @{};
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopeSnapshot =
        [self scopedAppsSnapshot];
    NSSet<NSString *> *appBundleIdentifiers =
        PXEnabledEligibleAppBundleIdentifiers(scopeSnapshot);
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *installIdentifierKeys = [NSMutableDictionary dictionary];
    [previousManifest.appIdentities enumerateKeysAndObjectsUsingBlock:^(NSString *bundleIdentifier,
                                                                        PXAppIdentityRecord *identity,
                                                                        BOOL *stop) {
        (void)stop;
        installIdentifierKeys[bundleIdentifier] = identity.installIdentifierKeys;
    }];
    for (NSString *bundleIdentifier in appBundleIdentifiers) {
        NSDictionary *appInfo = scopeSnapshot[bundleIdentifier];
        NSArray *configuredKeys = [appInfo[@"installIdentifierKeys"] isKindOfClass:[NSArray class]]
            ? appInfo[@"installIdentifierKeys"]
            : @[];
        if (configuredKeys.count > 0) {
            installIdentifierKeys[bundleIdentifier] = [NSSet setWithArray:configuredKeys];
        }
    }
    input.appBundleIdentifiers = appBundleIdentifiers;
    input.appGroupIdentifiers = [NSSet setWithArray:previousManifest.appGroupIdentities.allKeys ?: @[]];
    input.installIdentifierKeysByBundleIdentifier = [installIdentifierKeys copy];
    input.graphicsHostCapabilities = graphicsHostCapabilities;
    input.networkType = [environmentPolicy selectedNetworkTypeWithError:&environmentPolicyError];
    input.networkTypes = [environmentPolicy selectedNetworkTypesWithError:&environmentPolicyError];
    if (environmentPolicyError) {
        if (error) *error = environmentPolicyError;
        return NO;
    }

    NSError *draftError = nil;
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init] generateManifestWithInput:input error:&draftError];
    if (!manifest) {
        if (error) *error = draftError;
        return NO;
    }
    if (![store promoteManifest:manifest error:&draftError]) {
        if (error) *error = draftError;
        return NO;
    }

    [[IOSVersionInfo sharedManager] setCurrentIOSVersionInfo:manifest.operatingSystem];
    if (configuredLocation) {
        [[LocationSpoofingManager sharedManager]
            enableSpoofingWithLatitude:[configuredLocation[@"latitude"] doubleValue]
            longitude:[configuredLocation[@"longitude"] doubleValue]];
    } else if (locationWasCleared) {
        [[LocationSpoofingManager sharedManager] disableSpoofing];
    }
    [self saveSettings];

    if (publishNotifications) {
        [self publishProfileGenerationNotifications];
    }
    return YES;
}

- (void)publishProfileGenerationNotifications {
    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterPostNotification(darwinCenter,
                                         CFSTR("com.hydra.projectx.profileGenerationChanged"),
                                         NULL,
                                         NULL,
                                         YES);
    CFNotificationCenterPostNotification(darwinCenter, CFSTR("com.hydra.projectx.profileChanged"), NULL, NULL, YES);
    CFNotificationCenterPostNotification(darwinCenter, CFSTR("com.hydra.projectx.carrierDetailsChanged"), NULL, NULL, YES);
    CFNotificationCenterPostNotification(darwinCenter, CFSTR("com.hydra.projectx.networkConnectionTypeChanged"), NULL, NULL, YES);
    CFNotificationCenterPostNotification(darwinCenter, CFSTR("com.hydra.projectx.settings.changed"), NULL, NULL, YES);
}

#pragma mark - Settings Management

// Helper methods for file checks
- (BOOL)fileExistsAtPath:(NSString *)path {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (NSDictionary *)dictionaryAtPath:(NSString *)path {
    return PXProfileReadDictionary(path);
}

- (void)setIdentifierEnabled:(BOOL)enabled forType:(NSString *)type {
    // Set the enabled state in settings
    self.settings[type] = @(enabled);
    
    // If enabling an identifier, check if we need to generate a value
    if (enabled) {
        // Check if a value exists
        NSString *currentValue = [self currentValueForIdentifier:type];
        if (!currentValue) {
            PXLog(@"No value exists for %@ - generating new value...", type);
            
            // Generate a value based on the identifier type
            if ([type isEqualToString:@"IDFA"]) {
                [self generateIDFA];
            } 
            else if ([type isEqualToString:@"IDFV"]) {
                [self generateIDFV];
            }
            else if ([type isEqualToString:@"DeviceName"]) {
                [self generateDeviceName];
            }
            else if ([type isEqualToString:@"SerialNumber"]) {
                [self generateSerialNumber];
            }
            else if ([type isEqualToString:@"IMEI"]) {
                NSString *imei = [self generateIMEI];
                if (imei) [self setCustomIMEI:imei];
            }
            else if ([type isEqualToString:@"MEID"]) {
                NSString *meid = [self generateMEID];
                if (meid) [self setCustomMEID:meid];
            }
            else if ([type isEqualToString:@"IOSVersion"]) {
                [self generateIOSVersion];
            }
            else if ([type isEqualToString:@"SystemBootUUID"]) {
                [self generateSystemBootUUID];
            }
            else if ([type isEqualToString:@"DyldCacheUUID"]) {
                [self generateDyldCacheUUID];
            }
            else if ([type isEqualToString:@"PasteboardUUID"]) {
                [self generatePasteboardUUID];
            }
            else if ([type isEqualToString:@"KeychainUUID"]) {
                [self generateKeychainUUID];
            }
            else if ([type isEqualToString:@"UserDefaultsUUID"]) {
                [self generateUserDefaultsUUID];
            }
            else if ([type isEqualToString:@"AppGroupUUID"]) {
                [self generateAppGroupUUID];
            }
            else if ([type isEqualToString:@"CoreDataUUID"]) {
                [self generateCoreDataUUID];
            }
            else if ([type isEqualToString:@"SystemUptime"]) {
                [[UptimeManager sharedManager] currentUptime];
            }
            else if ([type isEqualToString:@"BootTime"]) {
                [[UptimeManager sharedManager] currentBootTime];
            }
            else if ([type isEqualToString:@"WiFi"]) {
                // Use WiFiManager to generate new WiFi info
                id wifiManager = NSClassFromString(@"WiFiManager");
                if (wifiManager && [wifiManager respondsToSelector:@selector(sharedManager)]) {
                    id sharedManager = [wifiManager sharedManager];
                    if (sharedManager && [sharedManager respondsToSelector:@selector(generateWiFiInfo)]) {
                        [sharedManager generateWiFiInfo];
                        PXLog(@"Generated new WiFi information");
                    }
                }
            }
            else if ([type isEqualToString:@"StorageSystem"]) {
                // Use StorageManager to generate new storage info
                id storageManager = NSClassFromString(@"StorageManager");
                if (storageManager && [storageManager respondsToSelector:@selector(sharedManager)]) {
                    id sharedManager = [storageManager sharedManager];
                    if (sharedManager && [sharedManager respondsToSelector:@selector(generateStorageForCapacity:)]) {
                        // Randomly choose between 64GB and 128GB
                        NSString *capacity = [sharedManager respondsToSelector:@selector(randomizeStorageCapacity)] ? 
                                               [sharedManager randomizeStorageCapacity] : @"64";
                        
                        NSDictionary *storageInfo = [sharedManager generateStorageForCapacity:capacity];
                        if (storageInfo) {
                            [sharedManager setTotalStorageCapacity:storageInfo[@"TotalStorage"]];
                            [sharedManager setFreeStorageSpace:storageInfo[@"FreeStorage"]];
                            [sharedManager setFilesystemType:storageInfo[@"FilesystemType"]];
                            PXLog(@"[WeaponX] 💾 Generated new storage information: %@ GB", storageInfo[@"TotalStorage"]);
                        }
                    }
                }
            }
            else if ([type isEqualToString:@"Battery"]) {
                // Use BatteryManager to generate new battery info
                id batteryManager = NSClassFromString(@"BatteryManager");
                if (batteryManager && [batteryManager respondsToSelector:@selector(sharedManager)]) {
                    id sharedManager = [batteryManager sharedManager];
                    if (sharedManager && [sharedManager respondsToSelector:@selector(generateBatteryInfo)]) {
                        NSDictionary *batteryInfo = [sharedManager generateBatteryInfo];
                        if (batteryInfo) {
                            PXLog(@"[WeaponX] 🔋 Generated new battery information: %@%%", 
                                 @([batteryInfo[@"BatteryLevel"] floatValue] * 100));
                        }
                    }
                }
            }
            else if ([type isEqualToString:@"AppInstallUUID"]) {
                [self generateAppInstallUUID];
            }
            else if ([type isEqualToString:@"AppContainerUUID"]) {
                [self generateAppContainerUUID];
            }
            else if ([type isEqualToString:@"DeviceTheme"]) {
                NSString *theme = [self generateDeviceTheme];
                if (theme) {
                    PXLog(@"[WeaponX] 🎨 Generated device theme: %@", theme);
                }
            }
        }
    }
    
    // For WiFi specifically, also update the SystemConfiguration plist
    if ([type isEqualToString:@"WiFi"]) {
        NSString *securitySettingsPath = PXSecuritySettingsPath();
        NSMutableDictionary *settingsDict = [PXProfileReadDictionary(securitySettingsPath) mutableCopy] ?: [NSMutableDictionary dictionary];
        settingsDict[@"wifiSpoofEnabled"] = @(enabled);
        PXProfileWriteDictionary(settingsDict, securitySettingsPath);
        
        // Also update in UserDefaults for compatibility
        NSUserDefaults *settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.weaponx.securitySettings"];
        [settings setBool:enabled forKey:@"wifiSpoofEnabled"];
        [settings synchronize];
        
        // Post notification to inform system about WiFi spoofing change
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                           CFSTR("com.hydra.projectx.toggleWifiSpoof"),
                                           NULL, NULL, YES);
    }
    // For Battery specifically, update the SystemConfiguration plist
    else if ([type isEqualToString:@"Battery"]) {
        NSString *securitySettingsPath = PXSecuritySettingsPath();
        NSMutableDictionary *settingsDict = [PXProfileReadDictionary(securitySettingsPath) mutableCopy] ?: [NSMutableDictionary dictionary];
        settingsDict[@"batterySpoofEnabled"] = @(enabled);
        PXProfileWriteDictionary(settingsDict, securitySettingsPath);
        
        // Also update in UserDefaults for compatibility
        NSUserDefaults *settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.weaponx.securitySettings"];
        [settings setBool:enabled forKey:@"batterySpoofEnabled"];
        [settings synchronize];
        
        // Post notification to inform system about Battery spoofing change
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                           CFSTR("com.hydra.projectx.toggleBatterySpoof"),
                                           NULL, NULL, YES);
    }
    // For DeviceTheme, update the SystemConfiguration plist
    else if ([type isEqualToString:@"DeviceTheme"]) {
        NSString *securitySettingsPath = PXSecuritySettingsPath();
        NSMutableDictionary *settingsDict = [PXProfileReadDictionary(securitySettingsPath) mutableCopy] ?: [NSMutableDictionary dictionary];
        settingsDict[@"deviceThemeSpoofEnabled"] = @(enabled);
        PXProfileWriteDictionary(settingsDict, securitySettingsPath);
        
        // Also update in UserDefaults for compatibility
        NSUserDefaults *settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.weaponx.securitySettings"];
        [settings setBool:enabled forKey:@"deviceThemeSpoofEnabled"];
        [settings synchronize];
        
        // Post notification to inform system about DeviceTheme spoofing change
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                           CFSTR("com.hydra.projectx.toggleDeviceThemeSpoof"),
                                           NULL, NULL, YES);
    }
    
    [self saveSettings];
}

- (BOOL)isIdentifierEnabled:(NSString *)type {
    return [self.settings[type] boolValue];
}

#pragma mark - Current Values

- (NSString *)currentValueForIdentifier:(NSString *)type {
    if ([type isEqualToString:@"DeviceTheme"]) {
        NSString *theme = PXCurrentProfileValue(@"deviceTheme")[@"value"];
        return [theme isKindOfClass:[NSString class]] ? theme : nil;
    }
    // First try to get from profile-specific storage
    NSString *identityDir = [self profileIdentityPath];
    if (identityDir) {
        NSString *deviceIdsPath = [identityDir stringByAppendingPathComponent:@"device_ids.plist"];
        NSDictionary *deviceIds = PXProfileReadDictionary(deviceIdsPath);
        NSString *value = deviceIds[type];
        
        if (value) {
            PXLog(@"Found %@ value in device_ids.plist: %@", type, value);
            return value;
        }
        
        // If not found in combined file, try type-specific files
        if ([type isEqualToString:@"IDFA"]) {
            NSString *idfaPath = [identityDir stringByAppendingPathComponent:@"advertising_id.plist"];
            NSDictionary *idfaDict = PXProfileReadDictionary(idfaPath);
            if (idfaDict && idfaDict[@"value"]) {
                PXLog(@"Found IDFA in advertising_id.plist: %@", idfaDict[@"value"]);
                return idfaDict[@"value"];
            }
        } 
        else if ([type isEqualToString:@"IDFV"]) {
            NSString *idfvPath = [identityDir stringByAppendingPathComponent:@"vendor_id.plist"];
            NSDictionary *idfvDict = PXProfileReadDictionary(idfvPath);
            if (idfvDict && idfvDict[@"value"]) {
                PXLog(@"Found IDFV in vendor_id.plist: %@", idfvDict[@"value"]);
                return idfvDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"SystemBootUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"system_boot_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found SystemBootUUID in system_boot_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"DyldCacheUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"dyld_cache_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found DyldCacheUUID in dyld_cache_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"PasteboardUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"pasteboard_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found PasteboardUUID in pasteboard_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"KeychainUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"keychain_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found KeychainUUID in keychain_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"UserDefaultsUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"userdefaults_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found UserDefaultsUUID in userdefaults_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"CoreDataUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"coredata_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found CoreDataUUID in coredata_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"AppInstallUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"appinstall_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found AppInstallUUID in appinstall_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"AppContainerUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"appcontainer_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found AppContainerUUID in appcontainer_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"AppGroupUUID"]) {
            NSString *uuidPath = [identityDir stringByAppendingPathComponent:@"appgroup_uuid.plist"];
            NSDictionary *uuidDict = PXProfileReadDictionary(uuidPath);
            if (uuidDict && uuidDict[@"value"]) {
                PXLog(@"Found AppGroupUUID in appgroup_uuid.plist: %@", uuidDict[@"value"]);
                return uuidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"IMEI"]) {
            NSString *imeiPath = [identityDir stringByAppendingPathComponent:@"imei.plist"];
            NSDictionary *imeiDict = PXProfileReadDictionary(imeiPath);
            if (imeiDict && imeiDict[@"value"]) {
                PXLog(@"Found IMEI in imei.plist: %@", imeiDict[@"value"]);
                return imeiDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"MEID"]) {
            NSString *meidPath = [identityDir stringByAppendingPathComponent:@"meid.plist"];
            NSDictionary *meidDict = PXProfileReadDictionary(meidPath);
            if (meidDict && meidDict[@"value"]) {
                PXLog(@"Found MEID in meid.plist: %@", meidDict[@"value"]);
                return meidDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"DeviceModel"]) {
            NSString *modelPath = [identityDir stringByAppendingPathComponent:@"device_model.plist"];
            NSDictionary *modelDict = PXProfileReadDictionary(modelPath);
            if (modelDict && modelDict[@"value"]) {
                PXLog(@"Found DeviceModel in device_model.plist: %@", modelDict[@"value"]);
                return modelDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"DeviceName"]) {
            NSString *deviceNamePath = [identityDir stringByAppendingPathComponent:@"device_name.plist"];
            NSDictionary *deviceNameDict = PXProfileReadDictionary(deviceNamePath);
            if (deviceNameDict && deviceNameDict[@"value"]) {
                PXLog(@"Found DeviceName in device_name.plist: %@", deviceNameDict[@"value"]);
                return deviceNameDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"SerialNumber"]) {
            NSString *serialPath = [identityDir stringByAppendingPathComponent:@"serial_number.plist"];
            NSDictionary *serialDict = PXProfileReadDictionary(serialPath);
            if (serialDict && serialDict[@"value"]) {
                PXLog(@"Found SerialNumber in serial_number.plist: %@", serialDict[@"value"]);
                return serialDict[@"value"];
            }
        }
        else if ([type isEqualToString:@"WiFi"]) {
            // Check for WiFi info in the profile
            NSString *wifiInfoPath = [identityDir stringByAppendingPathComponent:@"wifi_info.plist"];
            NSDictionary *wifiInfo = PXProfileReadDictionary(wifiInfoPath);
            if (wifiInfo && wifiInfo[@"ssid"] && wifiInfo[@"bssid"]) {
                NSString *formattedValue = [NSString stringWithFormat:@"%@ (%@)", wifiInfo[@"ssid"], wifiInfo[@"bssid"]];
                PXLog(@"Found WiFi info in wifi_info.plist: %@", formattedValue);
                return formattedValue;
            }
        }
        else if ([type isEqualToString:@"StorageSystem"]) {
            NSDictionary *storageDict = PXCurrentProfileValue(@"storage");
            if (storageDict && storageDict[@"TotalStorage"] && storageDict[@"FreeStorage"]) {
                NSString *formattedStorage = [NSString stringWithFormat:@"Total: %@ GB, Free: %@ GB", 
                                             storageDict[@"TotalStorage"], 
                                             storageDict[@"FreeStorage"]];
                PXLog(@"Found Storage info in current Profile: %@", formattedStorage);
                return formattedStorage;
            }
        }
        else if ([type isEqualToString:@"BatteryLevel"] || [type isEqualToString:@"LowPowerMode"]) {
            NSDictionary *batteryDict = PXCurrentProfileValue(@"batteryInfo");
            if (batteryDict && batteryDict[type]) {
                PXLog(@"Found %@ in current Profile: %@", type, batteryDict[type]);
                return batteryDict[type];
            }
        }
        else if ([type isEqualToString:@"SystemUptime"]) {
            NSString *profilePath = [self profileIdentityPath];
NSString *uptimePath = [profilePath stringByAppendingPathComponent:@"system_uptime.plist"];
NSDictionary *uptimeDict = PXProfileReadDictionary(uptimePath);
if (uptimeDict && uptimeDict[@"value"]) {
    NSTimeInterval uptime = [uptimeDict[@"value"] doubleValue];
    if (uptime > 0) {
        NSString *formattedUptime = [NSString stringWithFormat:@"%.2f hours", uptime / 3600.0];
        PXLog(@"[WeaponX] 📄 Showing SystemUptime from system_uptime.plist: %@", formattedUptime);
        return formattedUptime;
    }
}
return @"Not Set";
        }
        else if ([type isEqualToString:@"BootTime"]) {
            NSString *profilePath = [self profileIdentityPath];
NSString *bootTimePath = [profilePath stringByAppendingPathComponent:@"boot_time.plist"];
NSDictionary *bootTimeDict = PXProfileReadDictionary(bootTimePath);
if (bootTimeDict && bootTimeDict[@"value"]) {
    NSDate *bootTime = bootTimeDict[@"value"];
    if ([bootTime isKindOfClass:[NSDate class]]) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterMediumStyle;
        NSString *formattedBootTime = [formatter stringFromDate:bootTime];
        PXLog(@"[WeaponX] 📄 Showing BootTime from boot_time.plist: %@", formattedBootTime);
        return formattedBootTime;
    }
}
return @"Not Set";
        }
        
        PXLog(@"No %@ value found in profile-specific files", type);
    } else {
        PXLog(@"Could not access identity directory for profile");
    }
    
    // Special handling for IOS Version which returns a composite string
    if ([type isEqualToString:@"IOSVersion"]) {
        // First try to get from profile-specific storage
        NSString *identityDir = [self profileIdentityPath];
        if (identityDir) {
            // First try to get from device_ids.plist
            NSString *deviceIdsPath = [identityDir stringByAppendingPathComponent:@"device_ids.plist"];
            NSDictionary *deviceIds = PXProfileReadDictionary(deviceIdsPath);
            NSString *version = deviceIds[@"IOSVersion"];
            
            // If we have a pre-formatted version string, use it
            if (version && [version containsString:@"("]) {
                PXLog(@"[WeaponX] Found pre-formatted iOS version: %@", version);
                return version;
            }
            
            // If not pre-formatted, try to combine version and build
            NSString *build = deviceIds[@"IOSBuild"];
            if (version && build) {
                NSString *formattedVersion = [NSString stringWithFormat:@"%@ (%@)", version, build];
                PXLog(@"[WeaponX] Formatted iOS version from components: %@", formattedVersion);
                return formattedVersion;
            }
            
            // If not found in combined file, try ios_version.plist
            NSString *versionPath = [identityDir stringByAppendingPathComponent:@"ios_version.plist"];
            NSDictionary *versionDict = PXProfileReadDictionary(versionPath);
            if (versionDict && versionDict[@"version"] && versionDict[@"build"]) {
                NSString *formattedVersion = [NSString stringWithFormat:@"%@ (%@)", versionDict[@"version"], versionDict[@"build"]];
                PXLog(@"[WeaponX] Formatted iOS version from ios_version.plist: %@", formattedVersion);
                return formattedVersion;
            }
        }
        
        PXLog(@"[WeaponX] No iOS version information found");
        return nil;
    }
    
    // Special handling for WiFi which needs the WiFiManager
    if ([type isEqualToString:@"WiFi"]) {
        // Try to get WiFi info from WiFiManager
        id wifiManager = NSClassFromString(@"WiFiManager");
        if (wifiManager && [wifiManager respondsToSelector:@selector(sharedManager)]) {
            id sharedManager = [wifiManager sharedManager];
            if (sharedManager) {
                // Get WiFi info based on available methods
                NSString *ssid = nil;
                NSString *bssid = nil;
                
                if ([sharedManager respondsToSelector:@selector(currentSSID)]) {
                    ssid = [sharedManager currentSSID];
                }
                
                if ([sharedManager respondsToSelector:@selector(currentBSSID)]) {
                    bssid = [sharedManager currentBSSID];
                }
                
                if (ssid && bssid) {
                    NSString *formattedValue = [NSString stringWithFormat:@"%@ (%@)", ssid, bssid];
                    PXLog(@"[WeaponX] WiFi info from WiFiManager: %@", formattedValue);
                    return formattedValue;
                } else if (ssid) {
                    PXLog(@"[WeaponX] WiFi SSID only from WiFiManager: %@", ssid);
                    return ssid;
                }
            }
        }
    }
    
    // Special handling for StorageSystem - try to get from StorageManager
    if ([type isEqualToString:@"StorageSystem"]) {
        id storageManager = NSClassFromString(@"StorageManager");
        if (storageManager && [storageManager respondsToSelector:@selector(sharedManager)]) {
            id sharedManager = [storageManager sharedManager];
            if (sharedManager) {
                NSString *totalStorage = nil;
                NSString *freeStorage = nil;
                
                if ([sharedManager respondsToSelector:@selector(totalStorageCapacity)]) {
                    totalStorage = [sharedManager totalStorageCapacity];
                }
                
                if ([sharedManager respondsToSelector:@selector(freeStorageSpace)]) {
                    freeStorage = [sharedManager freeStorageSpace];
                }
                
                if (totalStorage && freeStorage) {
                    NSString *formattedStorage = [NSString stringWithFormat:@"Total: %@ GB, Free: %@ GB", 
                                               totalStorage, freeStorage];
                    return formattedStorage;
                }
                
                // Try to generate new values if we couldn't get existing ones
                if ([sharedManager respondsToSelector:@selector(generateStorageForCapacity:)]) {
                    // Randomly choose between 64GB and 128GB
                    NSString *capacity = [sharedManager respondsToSelector:@selector(randomizeStorageCapacity)] ? 
                                           [sharedManager randomizeStorageCapacity] : @"64";
                    
                    NSDictionary *storageInfo = [sharedManager generateStorageForCapacity:capacity];
                    if (storageInfo) {
                        [sharedManager setTotalStorageCapacity:storageInfo[@"TotalStorage"]];
                        [sharedManager setFreeStorageSpace:storageInfo[@"FreeStorage"]];
                        [sharedManager setFilesystemType:storageInfo[@"FilesystemType"]];
                        
                        NSString *formattedStorage = [NSString stringWithFormat:@"Total: %@ GB, Free: %@ GB", 
                                                  storageInfo[@"TotalStorage"], 
                                                  storageInfo[@"FreeStorage"]];
                        return formattedStorage;
                    }
                }
            }
        }
        
        // Final fallback for storage - 40% chance for 64GB, 60% chance for 128GB
        BOOL use128GB = (arc4random_uniform(100) < 60);
        NSString *storageCapacity = use128GB ? @"128" : @"64";
        NSString *freeSpaceValue = use128GB ? @"38.4" : @"19.8";
        
        // Save these values to StorageManager to ensure consistency
        if (storageManager && [storageManager respondsToSelector:@selector(sharedManager)]) {
            id sharedManager = [storageManager sharedManager];
            if (sharedManager) {
                [sharedManager setTotalStorageCapacity:storageCapacity];
                [sharedManager setFreeStorageSpace:freeSpaceValue];
                [sharedManager setFilesystemType:@"0x1A"];
            }
        }
        
        return [NSString stringWithFormat:@"Total: %@ GB, Free: %@ GB", storageCapacity, freeSpaceValue];
    }
    
    // Special handling for Battery info - try to get from BatteryManager
    if ([type isEqualToString:@"BatteryLevel"] || [type isEqualToString:@"LowPowerMode"] || [type isEqualToString:@"Battery"]) {
        id batteryManager = NSClassFromString(@"BatteryManager");
        if (batteryManager && [batteryManager respondsToSelector:@selector(sharedManager)]) {
            id sharedManager = [batteryManager sharedManager];
            if (sharedManager) {
                // Force a reload from disk first to ensure fresh values
                if ([sharedManager respondsToSelector:@selector(loadBatteryInfoFromDisk)]) {
                    [sharedManager loadBatteryInfoFromDisk];
                }
                
                // Handle Battery identifier which includes both level and low power mode
                if ([type isEqualToString:@"Battery"]) {
                    if ([sharedManager respondsToSelector:@selector(batteryLevel)]) {
                        
                        // Use explicit cast to BatteryManager to avoid confusion with UIDevice method
                        NSString *level = [(BatteryManager *)sharedManager batteryLevel];
                        
                        if (level) {
                            float levelFloat = [level floatValue];
                            int percentage = (int)(levelFloat * 100);
                            
                            NSString *displayValue = [NSString stringWithFormat:@"%d%%", percentage];
                                 
                            PXLog(@"[WeaponX] 🔋 Battery info from BatteryManager: %@", displayValue);
                            return displayValue;
                        }
                    }
                    
                    // If we couldn't get both values, try to get a pre-formatted display value
                    if ([sharedManager respondsToSelector:@selector(generateBatteryInfo)]) {
                        NSDictionary *batteryInfo = [sharedManager generateBatteryInfo];
                        if (batteryInfo) {
                            // Check if we have a pre-formatted display value
                            if (batteryInfo[@"DisplayValue"]) {
                                return batteryInfo[@"DisplayValue"];
                            }
                            
                            // Otherwise, format it ourselves
                            NSString *level = batteryInfo[@"BatteryLevel"];
                            
                            if (level) {
                                float levelFloat = [level floatValue];
                                int percentage = (int)(levelFloat * 100);
                                
                                NSString *displayValue = [NSString stringWithFormat:@"%d%%", percentage];
                                     
                                PXLog(@"[WeaponX] 🔋 Generated battery info: %@", displayValue);
                                return displayValue;
                            }
                        }
                    }
                } 
                // Handle individual battery values
                else if ([type isEqualToString:@"BatteryLevel"] && [sharedManager respondsToSelector:@selector(batteryLevel)]) {
                    NSString *level = [(BatteryManager *)sharedManager batteryLevel];
                    if (level) {
                        PXLog(@"[WeaponX] 🔋 Battery level from BatteryManager: %@", level);
                        return level;
                    }
                }
            }
        }
    }
    
    // Special handling for SystemUptime/BootTime
    if ([type isEqualToString:@"SystemUptime"]) {
        NSTimeInterval uptime = [[UptimeManager sharedManager] currentUptime];
        if (uptime <= 0) return nil;
        NSString *result = [NSString stringWithFormat:@"%.2f hours", uptime / 3600.0];
        PXLog(@"Default SystemUptime value: %@", result);
        return result;
    }
    else if ([type isEqualToString:@"BootTime"]) {
        NSDate *bootTime = [[UptimeManager sharedManager] currentBootTime];
        if (!bootTime) return nil;
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterMediumStyle;
        NSString *result = [formatter stringFromDate:bootTime];
        PXLog(@"Default BootTime value: %@", result);
        return result;
    }
    
    return nil;
}

#pragma mark - App Management

- (void)refreshScopedAppsInfoIfNeeded {
    @synchronized(self) {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *updatedApps =
        [[self scopedAppsSnapshot] mutableCopy];
    // Iterate through all scoped apps and update their version/build info
    for (NSString *bundleID in updatedApps) {
        LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
        if (appProxy) {
            NSString *currentVersion = appProxy.shortVersionString;
            NSString *currentBuild = appProxy.bundleVersion ?: @"";
            NSMutableDictionary *appInfo = [updatedApps[bundleID] mutableCopy];
            BOOL needsUpdate = ![appInfo[@"version"] isEqualToString:currentVersion] ||
                               ![appInfo[@"build"] isEqualToString:currentBuild];
            if (needsUpdate) {
                appInfo[@"version"] = currentVersion ?: @"";
                appInfo[@"build"] = currentBuild ?: @"";
                updatedApps[bundleID] = appInfo;
            }
        }
    }
    [self publishScopedAppsSnapshot:updatedApps];
    [self saveSettings];
    }
}

- (void)addApplicationToScope:(NSString *)bundleID {
    @synchronized(self) {
    if (!bundleID.length || !PXAppIdentityBundleIsEligible(bundleID, YES, NO)) {
        self.error = [NSError errorWithDomain:@"com.hydra.projectx" 
                                       code:3001 
                                   userInfo:@{NSLocalizedDescriptionKey: @"Target App is not eligible"}];
        return;
    }
    
    // Get app info using LSApplicationProxy
    LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!appProxy) {
        self.error = [NSError errorWithDomain:@"com.hydra.projectx" 
                                       code:3002 
                                   userInfo:@{NSLocalizedDescriptionKey: @"Application not found"}];
        return;
    }
    
    NSMutableDictionary *appInfo = [NSMutableDictionary dictionary];
    appInfo[@"name"] = appProxy.localizedName ?: bundleID;
    appInfo[@"version"] = appProxy.shortVersionString ?: @"App Not Found";
    NSString *buildVersion = nil;
    id proxy = (id)appProxy;
    if ([proxy respondsToSelector:@selector(bundleVersion)]) {
        buildVersion = [proxy performSelector:@selector(bundleVersion)];
    } else if ([proxy respondsToSelector:@selector(valueForKey:)]) {
        buildVersion = [proxy valueForKey:@"bundleVersion"];
        if (!buildVersion) {
            buildVersion = [proxy valueForKey:@"CFBundleVersion"];
        }
    }
    appInfo[@"build"] = buildVersion ?: @"Unknown";  // Add build number
    appInfo[@"installed"] = @YES;
    appInfo[@"enabled"] = @YES;
    
    // Store using the original case-sensitive bundle ID
    appInfo[@"bundleID"] = bundleID;
    appInfo[@"originalBundleID"] = bundleID;  // Store original case-sensitive version
    
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *updatedApps =
        [[self scopedAppsSnapshot] mutableCopy];
    [updatedApps removeObjectsForKeys:PXScopeKeysMatchingBundleIdentifier(updatedApps, bundleID)];
    updatedApps[bundleID] = appInfo;
    NSError *persistenceError = nil;
    if (![self persistAndPublishScopedAppsSnapshot:updatedApps error:&persistenceError]) {
        self.error = persistenceError;
        return;
    }
    NSError *identityError = nil;
    if (![self ensureApplicationIdentityForBundleIdentifier:bundleID
                                           groupIdentifiers:[NSSet set]
                                      installIdentifierKeys:[NSSet set]
                                                       error:&identityError]) {
        self.error = identityError;
    }
    }
}

- (void)removeApplicationFromScope:(NSString *)bundleID {
    @synchronized(self) {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *updatedApps =
        [[self scopedAppsSnapshot] mutableCopy];
    [updatedApps removeObjectsForKeys:PXScopeKeysMatchingBundleIdentifier(updatedApps, bundleID)];
    NSError *persistenceError = nil;
    if (![self persistAndPublishScopedAppsSnapshot:updatedApps error:&persistenceError]) {
        self.error = persistenceError;
    }
    }
}

- (BOOL)isApplicationInScope:(NSString *)bundleID {
    if (!PXAppIdentityBundleIsEligible(bundleID, YES, NO)) {
        return NO;
    }
    NSDictionary<NSString *, id> *appInfo =
        PXScopeRecordForBundleIdentifier([self scopedAppsSnapshot], bundleID);
    return [appInfo[@"enabled"] boolValue];
}

- (BOOL)writeScopedApps:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApps
                  error:(NSError **)error {
    NSString *scopedAppsFile = PXGlobalScopePreferencesPath();
    PXScopedAppStore *scopeStore = [[PXScopedAppStore alloc]
        initWithFilePath:scopedAppsFile];
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *eligibleScopedApps =
        PXEligibleScopedApplications(scopedApps ?: @{});
    if (![scopeStore replaceScopedApplications:eligibleScopedApps error:error]) {
        return NO;
    }
    NSError *permissionError = nil;
    if (![[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions: @0644, NSFileOwnerAccountName: @"mobile"}
        ofItemAtPath:scopedAppsFile
        error:&permissionError]) {
        PXLog(@"[WeaponX] Scoped App permissions could not be updated: %@",
              permissionError.localizedDescription);
    }
    return YES;
}

- (BOOL)setApplicationInScope:(NSString *)bundleID enabled:(BOOL)enabled error:(NSError **)error {
    return [self applyApplicationScopeChanges:@{bundleID ?: @"": @(enabled)} error:error];
}

- (BOOL)applyApplicationScopeChanges:(NSDictionary<NSString *, NSNumber *> *)changes
                               error:(NSError **)error {
    @synchronized(self) {
    if (changes.count == 0) return YES;
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *updatedApps =
        [PXEligibleScopedApplications([self scopedAppsSnapshot]) mutableCopy];
    for (NSString *bundleID in changes) {
        if (bundleID.length == 0 || !PXAppIdentityBundleIsEligible(bundleID, YES, NO) ||
            ![changes[bundleID] isKindOfClass:[NSNumber class]]) {
            if (error) *error = [NSError errorWithDomain:@"com.hydra.projectx" code:3001
                userInfo:@{NSLocalizedDescriptionKey: @"Target App is not eligible"}];
            return NO;
        }
        [updatedApps removeObjectsForKeys:PXScopeKeysMatchingBundleIdentifier(updatedApps, bundleID)];
        if (![changes[bundleID] boolValue]) continue;
        LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
        if (!appProxy) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.hydra.projectx"
                                             code:3002
                                         userInfo:@{NSLocalizedDescriptionKey: @"Target App is not installed"}];
            }
            return NO;
        }
        updatedApps[bundleID] = [@{
            @"name": appProxy.localizedName ?: bundleID,
            @"version": appProxy.shortVersionString ?: @"",
            @"build": appProxy.bundleVersion ?: @"",
            @"installed": @YES,
            @"enabled": @YES,
            @"bundleID": bundleID,
            @"originalBundleID": bundleID,
            @"extensionPattern": [bundleID stringByAppendingString:@".*"]
        } mutableCopy];
    }
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *previousApps =
        [self scopedAppsSnapshot];
    NSError *persistenceError = nil;
    if (![self writeScopedApps:updatedApps error:&persistenceError]) {
        self.error = persistenceError;
        if (error) *error = persistenceError;
        return NO;
    }
    NSError *pendingStateError = nil;
    if (![[PXEnvironmentPolicyStore sharedStore] markPendingChangeWithError:&pendingStateError]) {
        NSError *rollbackError = nil;
        if (![self writeScopedApps:previousApps error:&rollbackError]) {
            PXLog(@"[WeaponX] Scoped App rollback failed: %@", rollbackError.localizedDescription);
        }
        self.error = pendingStateError;
        if (error) *error = pendingStateError;
        return NO;
    }
    [self publishScopedAppsSnapshot:updatedApps];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.hydra.projectx.scopedAppsChanged"),
                                         NULL,
                                         NULL,
                                         YES);
    return YES;
    }
}

- (void)setApplication:(NSString *)bundleID enabled:(BOOL)enabled {
    @synchronized(self) {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *updatedApps =
        [[self scopedAppsSnapshot] mutableCopy];
    NSArray<NSString *> *matchingKeys = PXScopeKeysMatchingBundleIdentifier(updatedApps,
                                                                             bundleID);
    if (!PXAppIdentityBundleIsEligible(bundleID, YES, NO)) {
        if (bundleID.length == 0) {
            self.error = [NSError errorWithDomain:@"com.hydra.projectx"
                                             code:3001
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"Target App is not eligible"}];
            return;
        }
        [updatedApps removeObjectsForKeys:matchingKeys];
        if (enabled) {
            self.error = [NSError errorWithDomain:@"com.hydra.projectx"
                                             code:3001
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"Target App is not eligible"}];
        }
        NSError *persistenceError = nil;
        if (![self persistAndPublishScopedAppsSnapshot:updatedApps error:&persistenceError]) {
            self.error = persistenceError;
        }
        return;
    }
    NSString *matchingKey = matchingKeys.firstObject;
    NSMutableDictionary *appInfo = [updatedApps[matchingKey] mutableCopy];
    if (appInfo) {
        appInfo[@"enabled"] = @(enabled);
        [updatedApps removeObjectsForKeys:matchingKeys];
        updatedApps[bundleID] = appInfo;
        NSError *persistenceError = nil;
        if (![self persistAndPublishScopedAppsSnapshot:updatedApps error:&persistenceError]) {
            self.error = persistenceError;
            return;
        }
        if (enabled) {
            NSError *identityError = nil;
            NSSet<NSString *> *configuredKeys = [appInfo[@"installIdentifierKeys"] isKindOfClass:[NSArray class]]
                ? [NSSet setWithArray:appInfo[@"installIdentifierKeys"]]
                : [NSSet set];
            if (![self ensureApplicationIdentityForBundleIdentifier:bundleID
                                                   groupIdentifiers:[NSSet set]
                                              installIdentifierKeys:configuredKeys
                                                               error:&identityError]) {
                self.error = identityError;
            }
        }
    }
    }
}

- (nullable PXAppIdentityRecord *)appIdentityForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *identityDirectory = [self profileIdentityPath];
    if (!identityDirectory) {
        return nil;
    }
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    return [store activeManifestWithError:nil].appIdentities[bundleIdentifier];
}

- (nullable PXAppGroupIdentityRecord *)appGroupIdentityForGroupIdentifier:(NSString *)groupIdentifier {
    NSString *identityDirectory = [self profileIdentityPath];
    if (!identityDirectory) {
        return nil;
    }
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    return [store activeManifestWithError:nil].appGroupIdentities[groupIdentifier];
}

- (BOOL)ensureApplicationIdentityForBundleIdentifier:(NSString *)bundleIdentifier
                                     groupIdentifiers:(NSSet<NSString *> *)groupIdentifiers
                                installIdentifierKeys:(NSSet<NSString *> *)installIdentifierKeys
                                                 error:(NSError **)error {
    NSString *identityDirectory = [self profileIdentityPath];
    if (!identityDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"No active Profile identity directory"}];
        }
        return NO;
    }
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    PXProfileManifest *beforeUpdate = [store activeManifestWithError:nil];
    PXAppIdentityRecord *existingIdentity = beforeUpdate.appIdentities[bundleIdentifier];
    NSError *prunedStateError = nil;
    NSSet<NSString *> *prunedTargetBundleIdentifiers = [[PXEnvironmentPolicyStore sharedStore]
        prunedTargetBundleIdentifiersWithError:&prunedStateError];
    if (!prunedTargetBundleIdentifiers) {
        if (error) *error = prunedStateError;
        return NO;
    }
    if (!PXEnvironmentAllowsApplicationIdentityEnsure(bundleIdentifier,
                                                       existingIdentity != nil,
                                                       prunedTargetBundleIdentifiers)) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"A reinstalled Target App requires a new environment generation"}];
        }
        return NO;
    }
    BOOL needsNotification = existingIdentity == nil ||
        ![installIdentifierKeys isSubsetOfSet:existingIdentity.installIdentifierKeys];
    if (!needsNotification) {
        for (NSString *groupIdentifier in groupIdentifiers) {
            if (!beforeUpdate.appGroupIdentities[groupIdentifier]) {
                needsNotification = YES;
                break;
            }
        }
    }
    if (![store ensureApplicationIdentityForBundleIdentifier:bundleIdentifier
                                             groupIdentifiers:groupIdentifiers
                                        installIdentifierKeys:installIdentifierKeys
                                                         error:error]) {
        return NO;
    }
    if (needsNotification) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.hydra.projectx.appIdentityChanged"),
                                             NULL,
                                             NULL,
                                             YES);
    }
    return YES;
}

- (NSDictionary *)getApplicationInfo:(NSString *)bundleID {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopeSnapshot =
        [self scopedAppsSnapshot];
    if (bundleID) {
        if (!PXAppIdentityBundleIsEligible(bundleID, YES, NO)) {
            return nil;
        }
        NSDictionary *appInfo = PXScopeRecordForBundleIdentifier(scopeSnapshot, bundleID);
        if (appInfo) {
            return [appInfo mutableCopy];
        }
        return nil;
    }
    
    // Return all apps with their original case-preserved bundle IDs
    NSMutableDictionary *displayApps = [NSMutableDictionary dictionary];
    [PXEligibleScopedApplications(scopeSnapshot)
        enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *appInfo, BOOL *stop) {
        NSMutableDictionary *displayInfo = [appInfo mutableCopy];
        NSString *originalBundleID = appInfo[@"originalBundleID"];
        if (originalBundleID) {
            // Use the original case-sensitive bundle ID
            displayInfo[@"bundleID"] = originalBundleID;
            displayApps[key] = displayInfo;
        } else {
            displayApps[key] = displayInfo;
        }
    }];
    return displayApps;
}

- (BOOL)isApplicationEnabled:(NSString *)bundleID {
    // Initialize cache if needed
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _appEnabledCache = [NSMutableDictionary dictionary];
    });

    @synchronized(self) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    // Treat persisted scope as untrusted input. Legacy releases could write Apple
    // system bundles here, so every runtime consumer must enforce current policy.
    if (!PXDeviceIdentifierSpoofingIsAllowedForBundle(bundleID, YES)) {
        if (bundleID.length > 0) {
            _appEnabledCache[bundleID] = @{@"enabled": @NO, @"timestamp": @(now)};
        }
        return NO;
    }
    
    // Check if we have a cached result that's still valid
    NSDictionary *cachedResult = _appEnabledCache[bundleID];
    if (cachedResult) {
        NSTimeInterval timestamp = [cachedResult[@"timestamp"] doubleValue];
        
        // If the cache hasn't expired, use it
        if (now - timestamp < _cacheExpirationTime) {
            return [cachedResult[@"enabled"] boolValue];
        }
    }
    
    // Only log once every 30 seconds per app to avoid spamming logs
    static NSString *lastLoggedApp = nil;
    static NSTimeInterval lastLogTime = 0;
    BOOL shouldLog = ![lastLoggedApp isEqualToString:bundleID] || (now - lastLogTime > 30.0);
    
    if (shouldLog) {
        PXLog(@"[WeaponX] IdentifierManager DEBUG: Checking if app is enabled: %@", bundleID);
        lastLoggedApp = [bundleID copy];
        lastLogTime = now;
    }
    
    // Never consider the WeaponX app itself as enabled for spoofing
    if ([bundleID isEqualToString:@"com.hydra.projectx"]) {
        if (shouldLog) {
            PXLog(@"[WeaponX] IdentifierManager DEBUG: WeaponX app itself is never considered enabled for spoofing");
        }
        
        // Cache the result
        _appEnabledCache[bundleID] = @{@"enabled": @NO, @"timestamp": @(now)};
        return NO;
    }
    
    // Direct equality check first for performance
    if (self.scopedApps[bundleID]) {
        BOOL isEnabled = [self.scopedApps[bundleID][@"enabled"] boolValue];
        
        if (shouldLog) {
            PXLog(@"[WeaponX] IdentifierManager DEBUG: Found app %@ in scopedApps, enabled = %@", bundleID, isEnabled ? @"YES" : @"NO");
        }
        
        // Cache the result
        _appEnabledCache[bundleID] = @{@"enabled": @(isEnabled), @"timestamp": @(now)};
        return isEnabled;
    }
    
    // Ensure we have the latest scoped apps data
    // Only reload scoped apps if we haven't reloaded recently
    static NSTimeInterval lastReloadTime = 0;
    if (now - lastReloadTime > 60.0) { // Only reload every minute at most
        if (shouldLog) {
            PXLog(@"[WeaponX] IdentifierManager DEBUG: App not found directly, reloading scoped apps");
        }
        [self loadScopedApps];
        lastReloadTime = now;
    }
    
    // Check again after potentially reloading the scoped apps
    if (self.scopedApps[bundleID]) {
        BOOL isEnabled = [self.scopedApps[bundleID][@"enabled"] boolValue];
        
        if (shouldLog) {
            PXLog(@"[WeaponX] IdentifierManager DEBUG: Found app %@ after reload, enabled = %@", bundleID, isEnabled ? @"YES" : @"NO");
        }
        
        // Cache the result
        _appEnabledCache[bundleID] = @{@"enabled": @(isEnabled), @"timestamp": @(now)};
        return isEnabled;
    }
    
    // Fallback to case-insensitive comparison if needed (this is expensive, so only log if needed)
    if (shouldLog) {
        PXLog(@"[WeaponX] IdentifierManager DEBUG: App still not found, trying case-insensitive match");
    }
    
    NSString *lowercaseBundleID = [bundleID lowercaseString];
    for (NSString *key in self.scopedApps) {
        if ([[key lowercaseString] isEqualToString:lowercaseBundleID]) {
            BOOL isEnabled = [self.scopedApps[key][@"enabled"] boolValue];
            
            if (shouldLog) {
                PXLog(@"[WeaponX] IdentifierManager DEBUG: Found app %@ via case-insensitive match with %@, enabled = %@", 
                      bundleID, key, isEnabled ? @"YES" : @"NO");
            }
            
            // Cache the result using the original bundle ID
            _appEnabledCache[bundleID] = @{@"enabled": @(isEnabled), @"timestamp": @(now)};
            return isEnabled;
        }
    }
    
    // App not found, only log this information sparingly
    if (shouldLog) {
        // Limit the keys we log to avoid excessive memory usage
        NSArray *allKeys = [self.scopedApps allKeys];
        NSArray *limitedKeys = allKeys.count > 10 ? [allKeys subarrayWithRange:NSMakeRange(0, 10)] : allKeys;
        
        PXLog(@"[WeaponX] IdentifierManager DEBUG: App %@ not found in scoped apps list", bundleID);
        PXLog(@"[WeaponX] IdentifierManager DEBUG: First %lu scoped apps: %@", (unsigned long)limitedKeys.count, limitedKeys);
    }
    
    // Cache the negative result
    _appEnabledCache[bundleID] = @{@"enabled": @NO, @"timestamp": @(now)};
    
    return NO;
    }
}

// New method to load scoped apps configuration explicitly
- (void)loadScopedApps {
    @synchronized(self) {
    NSString *scopedAppsFile = PXGlobalScopePreferencesPath();
    PXLog(@"[WeaponX] IdentifierManager DEBUG: Trying to load scoped apps from: %@", scopedAppsFile);

    NSFileManager *fileManager = [NSFileManager defaultManager];

    PXLog(@"[WeaponX] IdentifierManager DEBUG: Loading scoped apps from: %@", scopedAppsFile);
    PXLog(@"[WeaponX] IdentifierManager DEBUG: File exists: %@", [fileManager fileExistsAtPath:scopedAppsFile] ? @"YES" : @"NO");
    
    NSError *scopeError = nil;
    NSDictionary *savedApps = [[[PXScopedAppStore alloc] initWithFilePath:scopedAppsFile]
        scopedApplicationsWithError:&scopeError];
    PXLog(@"[WeaponX] IdentifierManager DEBUG: Loaded dictionary: %@", savedApps ? @"YES" : @"NO");
    PXLog(@"[WeaponX] IdentifierManager DEBUG: Scoped apps entry found in dictionary: %@", savedApps ? @"YES" : @"NO");
    
    if (savedApps) {
        NSDictionary<NSString *, NSDictionary<NSString *, id> *> *eligibleSavedApps =
            PXEligibleScopedApplications(savedApps);
        PXLog(@"[WeaponX] IdentifierManager DEBUG: Number of scoped apps found: %lu", (unsigned long)savedApps.count);
        if (savedApps.count > 0) {
            PXLog(@"[WeaponX] IdentifierManager DEBUG: App list includes: %@", [savedApps allKeys]);
        }
        [self publishScopedAppsSnapshot:eligibleSavedApps];
        PXLog(@"[WeaponX] IdentifierManager: Loaded %lu scoped apps from %@", (unsigned long)savedApps.count, scopedAppsFile);
    } else {
        [self publishScopedAppsSnapshot:@{}];
        PXLog(@"[WeaponX] IdentifierManager: ⚠️ Failed to load scoped apps, using empty list: %@",
              scopeError.localizedDescription ?: @"invalid scope");
    }
    }
}

- (void)reloadApplicationScope {
    [self loadScopedApps];
}

#pragma mark - Persistence

- (void)saveSettings {
    @synchronized(self) {
    NSString *prefsPath = PXPreferencesDirectoryPath();
    NSString *prefsFile = PXPreferencesFilePath(@"com.hydra.projectx.settings.plist");
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Ensure preferences directory exists with proper permissions
    NSError *dirError = nil;
    
    // Create all intermediate directories with proper permissions
    if (![fileManager fileExistsAtPath:prefsPath]) {
        NSDictionary *attributes = @{NSFilePosixPermissions: @0755,
                                    NSFileOwnerAccountName: @"mobile"};
        
        if (![fileManager createDirectoryAtPath:prefsPath 
                    withIntermediateDirectories:YES 
                                     attributes:attributes
                                          error:&dirError]) {
            self.error = [NSError errorWithDomain:@"com.hydra.projectx" 
                                            code:4004 
                                        userInfo:@{NSLocalizedDescriptionKey: 
                                                  [NSString stringWithFormat:@"Failed to create preferences directory: %@", 
                                                   dirError.localizedDescription]}];
            return;
        }
    }
    
    // Create dictionary to save for main settings
    NSMutableDictionary *saveDict = [NSMutableDictionary dictionary];
    
    // Save enabled states - these are still global settings
    saveDict[@"EnabledIdentifiers"] = [self.settings copy];
    
    // Mark settings as initialized
    saveDict[@"SettingsInitialized"] = @YES;
    
    // Save main settings
    BOOL success = PXProfileWriteDictionary(saveDict, prefsFile);
    if (!success) {
        self.error = [NSError errorWithDomain:@"com.hydra.projectx" 
                                      code:4005 
                                  userInfo:@{NSLocalizedDescriptionKey: @"Failed to save settings"}];
        return;
    }
    
    // Save scoped apps separately in the global scope file
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *eligibleScopedApps =
        PXEligibleScopedApplications([self scopedAppsSnapshot]);
    NSError *scopeError = nil;
    if (![self writeScopedApps:eligibleScopedApps error:&scopeError]) {
        self.error = scopeError;
        return;
    }
    [self publishScopedAppsSnapshot:eligibleScopedApps];

    // Set proper permissions
    NSError *permError = nil;
    NSDictionary *fileAttributes = @{NSFilePosixPermissions: @0644,
                                   NSFileOwnerAccountName: @"mobile"};
    if (![fileManager setAttributes:fileAttributes
                      ofItemAtPath:prefsFile
                             error:&permError]) {
        NSLog(@"[ProjectX] Warning: Failed to set preferences file permissions: %@", permError);
    }
    }
}

- (void)loadSettings {
    @synchronized(self) {
    NSString *prefsFile = PXPreferencesFilePath(@"com.hydra.projectx.settings.plist");
    NSString *scopedAppsFile = PXGlobalScopePreferencesPath();
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Preserve the previous settings filename only within the RootHide directory.
    if (![fileManager fileExistsAtPath:prefsFile]) {
        prefsFile = PXPreferencesFilePath(@"com.hydra.projectx.plist");
    }
    
    // Load dictionary from main settings file
    NSDictionary *loadedDict = PXProfileReadDictionary(prefsFile);

    // Load scope before any settings migration writes. A missing or malformed
    // main settings plist must never erase a valid global target selection.
    BOOL globalScopeExists = [fileManager fileExistsAtPath:scopedAppsFile];
    NSError *scopeError = nil;
    NSDictionary *savedApps = [[[PXScopedAppStore alloc] initWithFilePath:scopedAppsFile]
        scopedApplicationsWithError:&scopeError];
    if (!globalScopeExists && [loadedDict[@"ScopedApps"] isKindOfClass:[NSDictionary class]]) {
        savedApps = loadedDict[@"ScopedApps"];
        NSLog(@"[ProjectX] Loaded scoped apps from legacy location, will migrate to global file");
    }
    if (savedApps) {
        [self publishScopedAppsSnapshot:PXEligibleScopedApplications(savedApps)];
    } else {
        [self publishScopedAppsSnapshot:@{}];
        PXLog(@"[WeaponX] Invalid scoped-app state ignored: %@",
              scopeError.localizedDescription ?: @"invalid scope");
    }
    
    // Check if settings are initialized
    if (!loadedDict || ![loadedDict[@"SettingsInitialized"] boolValue]) {
        // Initialize with default values
        self.settings = [NSMutableDictionary dictionaryWithDictionary:@{
            @"IDFA": @NO,
            @"IDFV": @NO,
            @"DeviceName": @NO,
            @"SerialNumber": @NO,
            @"UDID": @NO,
            @"IMEI": @NO,
            @"SystemVersion": @NO,
            @"BuildVersion": @NO,
            @"StorageSystem": @NO,
            @"SystemBootUUID": @NO,
            @"DyldCacheUUID": @NO,
            @"PasteboardUUID": @NO,
            @"KeychainUUID": @NO,
            @"UserDefaultsUUID": @NO,
            @"AppGroupUUID": @NO,
            @"CoreDataUUID": @NO,
            @"AppInstallUUID": @NO,
            @"AppContainerUUID": @NO,
            @"SystemUptime": @NO,
            @"BootTime": @NO
        }];
        [self saveSettings];
        return;
    }
    
    // Load enabled states
    NSDictionary *savedSettings = loadedDict[@"EnabledIdentifiers"];
    if (savedSettings) {
        [self.settings setDictionary:savedSettings];
    }
    
    // We no longer load identifier values from global settings as they're profile-specific
    }
}

#pragma mark - Error Handling

- (NSError *)lastError {
    return self.error;
}

- (NSString *)generateWiFiInformation {
    // Use WiFiManager to generate new WiFi info
    id wifiManager = NSClassFromString(@"WiFiManager");
    if (wifiManager && [wifiManager respondsToSelector:@selector(sharedManager)]) {
        id sharedManager = [wifiManager sharedManager];
        if (sharedManager && [sharedManager respondsToSelector:@selector(generateWiFiInfo)]) {
            NSDictionary *wifiInfo = [sharedManager generateWiFiInfo];
            if (wifiInfo && wifiInfo[@"ssid"] && wifiInfo[@"bssid"]) {
                NSString *formattedValue = [NSString stringWithFormat:@"%@ (%@)", wifiInfo[@"ssid"], wifiInfo[@"bssid"]];
                PXLog(@"Generated new WiFi information: %@", formattedValue);
                return formattedValue;
            }
        }
    }
    
    PXLog(@"Failed to generate WiFi information");
    return nil;
}

- (NSArray *)availableIdentifiers {
    // Return all available identifiers
    NSArray *identifiers = @[
        @"IDFA",
        @"IDFV",
        @"DeviceName",
        @"SerialNumber",
        @"IOSVersion",
        @"WiFi",
        @"StorageSystem",
        @"Battery",
        @"SystemBootUUID",
        @"DyldCacheUUID",
        @"PasteboardUUID",
        @"KeychainUUID",
        @"UserDefaultsUUID",
        @"AppGroupUUID",
        @"CoreDataUUID",
        @"AppInstallUUID",
        @"AppContainerUUID",
        @"SystemUptime",
        @"BootTime"
    ];
    
    return identifiers;
}

- (void)addApplicationWithExtensionsToScope:(NSString *)bundleID {
    @synchronized(self) {
    if (!PXAppIdentityBundleIsEligible(bundleID, YES, NO)) {
        return;
    }
    
    // First add the main app
    [self addApplicationToScope:bundleID];
    
    // Create a more specific extension pattern
    // Instead of just using first component, use the main app's bundle ID as base
    NSString *extensionPattern = [NSString stringWithFormat:@"%@.*", bundleID];
    
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *updatedApps =
        [[self scopedAppsSnapshot] mutableCopy];
    NSArray<NSString *> *matchingKeys = PXScopeKeysMatchingBundleIdentifier(updatedApps,
                                                                             bundleID);
    NSString *matchingKey = matchingKeys.firstObject;
    // Store the extension pattern in the app's info
    NSMutableDictionary *appInfo = [updatedApps[matchingKey] mutableCopy];
    if (appInfo) {
        appInfo[@"extensionPattern"] = extensionPattern;
        [updatedApps removeObjectsForKeys:matchingKeys];
        updatedApps[bundleID] = appInfo;
        NSError *persistenceError = nil;
        if (![self persistAndPublishScopedAppsSnapshot:updatedApps error:&persistenceError]) {
            self.error = persistenceError;
            return;
        }
        
        PXLog(@"[WeaponX] Added extension pattern: %@ for app: %@", extensionPattern, bundleID);
    }
    }
}

- (BOOL)isBundleIDMatch:(NSString *)targetBundleID withPattern:(NSString *)patternBundleID {
    if (!targetBundleID || !patternBundleID) return NO;
    
    // Convert pattern to regex, escaping all dots except the wildcard
    NSString *regexPattern = [patternBundleID stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
    regexPattern = [regexPattern stringByReplacingOccurrencesOfString:@"\\.*" withString:@".*"];
    regexPattern = [NSString stringWithFormat:@"^%@$", regexPattern];
    
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:regexPattern
                                                                         options:NSRegularExpressionCaseInsensitive
                                                                           error:&error];
    if (error) {
        PXLog(@"[WeaponX] Error creating regex for pattern %@: %@", patternBundleID, error);
        return NO;
    }
    
    NSRange range = NSMakeRange(0, targetBundleID.length);
    NSTextCheckingResult *match = [regex firstMatchInString:targetBundleID options:0 range:range];
    
    BOOL matches = (match != nil);
    if (matches) {
        PXLog(@"[WeaponX] Bundle ID: %@ matches pattern: %@", targetBundleID, patternBundleID);
    }
    
    return matches;
}

- (BOOL)shouldSpoofForBundle:(NSString *)bundleID {
    if (!PXDeviceIdentifierSpoofingIsAllowedForBundle(bundleID, YES)) return NO;
    @synchronized(self) {
    
    // Check cache first
    NSNumber *cachedDecision = self.spoofCache[bundleID];
    if (cachedDecision) {
        return [cachedDecision boolValue];
    }
    
    // Check if the app is directly in scope
    NSDictionary<NSString *, id> *appInfo =
        PXScopeRecordForBundleIdentifier(self.scopedApps, bundleID);
    BOOL isInScope = appInfo != nil;
    
    // If not directly in scope, check if it's an extension of a scoped app
    if (!isInScope) {
        isInScope = [self isExtensionEnabled:bundleID];
        
        // If it's an extension, log this for debugging
        if (isInScope) {
            PXLog(@"[WeaponX] Bundle ID %@ is enabled as an extension", bundleID);
        }
    } else {
        // If directly in scope, check if it's enabled
        isInScope = [appInfo[@"enabled"] boolValue];
        
        if (isInScope) {
            PXLog(@"[WeaponX] Bundle ID %@ is directly enabled in scope", bundleID);
        }
    }
    
    // Cache the decision with a timestamp
    self.spoofCache[bundleID] = @(isInScope);
    self.spoofCache[[bundleID stringByAppendingString:@"_timestamp"]] = [NSDate date];
    
    return isInScope;
    }
}

- (void)saveScopedApps {
    @synchronized(self) {
    NSError *persistenceError = nil;
    if (![self persistAndPublishScopedAppsSnapshot:[self scopedAppsSnapshot]
                                             error:&persistenceError]) {
        self.error = persistenceError;
    }
    }
}

- (BOOL)isExtensionEnabled:(NSString *)bundleID {
    if (!PXAppIdentityBundleIsEligible(bundleID, NO, YES)) {
        return NO;
    }
    
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopeSnapshot =
        [self scopedAppsSnapshot];
    // Check each scoped app's extension pattern
    for (NSString *scopedBundleID in scopeSnapshot) {
        NSDictionary *appInfo = scopeSnapshot[scopedBundleID];
        NSString *extensionPattern = appInfo[@"extensionPattern"];
        
        if (extensionPattern && [self isBundleIDMatch:bundleID withPattern:extensionPattern]) {
            PXLog(@"[WeaponX] Bundle ID %@ matches extension pattern %@ from app %@", bundleID, extensionPattern, scopedBundleID);
            return [appInfo[@"enabled"] boolValue];
        }
    }
    
    return NO;
}

#pragma mark - Custom Values

- (BOOL)saveCustomValue:(NSString *)value forType:(NSString *)type {
    NSDictionary<NSString *, NSString *> *keys = @{
        @"IDFA": @"idfa", @"IDFV": @"idfv", @"DeviceName": @"deviceName",
        @"SerialNumber": @"serialNumber", @"IMEI": @"imei", @"MEID": @"meid",
        @"DyldCacheUUID": @"dyldCacheUUID", @"PasteboardUUID": @"pasteboardUUID",
        @"KeychainUUID": @"keychainUUID", @"UserDefaultsUUID": @"userDefaultsUUID",
        @"CoreDataUUID": @"coreDataUUID"
    };
    NSString *key = keys[type];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:[self profileIdentityPath]];
    NSError *saveError = nil;
    if (![store replaceActiveIdentifierValue:value forKey:key error:&saveError]) {
        self.error = saveError;
        return NO;
    }
    self.error = nil;
    [self publishProfileGenerationNotifications];
    return YES;
}

- (BOOL)setCustomIDFA:(NSString *)value {
    // Validate UUID format
    if (![self validateUUID:value]) return NO;
    return [self saveCustomValue:value forType:@"IDFA"];
}

#pragma mark - IMEI/MEID Spoofing

- (BOOL)setCustomIMEI:(NSString *)value {
    // Validate IMEI: must be 15 digits, Luhn valid, and start with a US TAC (e.g., 353918, 356938, 359254, etc.)
    if (![self isValidIMEI:value]) return NO;
    return [self saveCustomValue:value forType:@"IMEI"];
}

- (BOOL)setCustomMEID:(NSString *)value {
    // Validate MEID: must be 14 hex digits, and start with a US prefix (e.g., A00000, A10000, 990000, etc.)
    if (![self isValidMEID:value]) return NO;
    return [self saveCustomValue:value forType:@"MEID"];
}

- (NSString *)generateIMEI {
    // Use a realistic US iPhone TAC (Type Allocation Code)
    NSArray *usTACs = @[ @"353918", @"356938", @"359254", @"353915", @"353920", @"353929", @"353997", @"354994" ];
    NSString *tac = usTACs[arc4random_uniform((uint32_t)usTACs.count)];
    NSMutableString *imei = [NSMutableString stringWithString:tac];
    // 8 digits for SNR
    for (int i = 0; i < 8; i++) {
        [imei appendFormat:@"%d", arc4random_uniform(10)];
    }
    // Luhn check digit
    int sum = 0;
    for (int i = 0; i < 14; i++) {
        int digit = [imei characterAtIndex:i] - '0';
        if (i % 2 == 1) digit *= 2;
        if (digit > 9) digit -= 9;
        sum += digit;
    }
    int checkDigit = (10 - (sum % 10)) % 10;
    [imei appendFormat:@"%d", checkDigit];
    return imei;
}

- (NSString *)generateMEID {
    // Use a realistic US MEID prefix (A00000, A10000, 990000)
    NSArray *usMEIDPrefixes = @[ @"A00000", @"A10000", @"990000" ];
    NSString *prefix = usMEIDPrefixes[arc4random_uniform((uint32_t)usMEIDPrefixes.count)];
    NSMutableString *meid = [NSMutableString stringWithString:prefix];
    // 8 hex digits for the rest
    for (int i = 0; i < 8; i++) {
        [meid appendFormat:@"%X", arc4random_uniform(16)];
    }
    return meid;
}

// IMEI validation: 15 digits, Luhn valid, US TAC
- (BOOL)isValidIMEI:(NSString *)imei {
    if (imei.length != 15) return NO;
    if (![self isAllDigits:imei]) return NO;
    // Check TAC
    NSArray *usTACs = @[ @"353918", @"356938", @"359254", @"353915", @"353920", @"353929", @"353997", @"354994" ];
    NSString *tac = [imei substringToIndex:6];
    if (![usTACs containsObject:tac]) return NO;
    // Luhn check
    int sum = 0;
    for (int i = 0; i < 14; i++) {
        int digit = [imei characterAtIndex:i] - '0';
        if (i % 2 == 1) digit *= 2;
        if (digit > 9) digit -= 9;
        sum += digit;
    }
    int checkDigit = (10 - (sum % 10)) % 10;
    return (checkDigit == ([imei characterAtIndex:14] - '0'));
}

// MEID validation: 14 hex digits, US prefix
- (BOOL)isValidMEID:(NSString *)meid {
    if (meid.length != 14) return NO;
    NSArray *usMEIDPrefixes = @[ @"A00000", @"A10000", @"990000" ];
    NSString *prefix = [meid substringToIndex:6];
    if (![usMEIDPrefixes containsObject:prefix]) return NO;
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"];
    for (NSUInteger i = 0; i < meid.length; i++) {
        unichar c = [meid characterAtIndex:i];
        if (![hexSet characterIsMember:c]) return NO;
    }
    return YES;
}

- (BOOL)isAllDigits:(NSString *)string {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return ([string rangeOfCharacterFromSet:nonDigits].location == NSNotFound);
}

- (BOOL)setCustomIDFV:(NSString *)value {
    // Validate UUID format
    if (![self validateUUID:value]) return NO;
    return [self saveCustomValue:value forType:@"IDFV"];
}

- (BOOL)setCustomDeviceName:(NSString *)value {
    // No special validation for device name
    return [self saveCustomValue:value forType:@"DeviceName"];
}

- (BOOL)setCustomSerialNumber:(NSString *)value {
    // Serial numbers have specific format requirements
    // This is a simplified validation - implement appropriate validation for serial numbers
    if (!value || value.length < 8) return NO;
    return [self saveCustomValue:value forType:@"SerialNumber"];
}

- (BOOL)setCustomSystemBootUUID:(NSString *)value {
    if (![self validateUUID:value]) return NO;
    NSDictionary *projection = PXProfileReadDictionary(
        [[self profileIdentityPath] stringByAppendingPathComponent:@"system_boot_uuid.plist"]);
    if ([projection[@"value"] isEqualToString:value]) {
        return YES;
    }
    self.error = [NSError errorWithDomain:@"com.hydra.projectx.profile-manifest"
                                     code:103
                                 userInfo:@{NSLocalizedDescriptionKey: @"Boot UUID changes require explicit Profile/session regeneration"}];
    return NO;
}

- (BOOL)setCustomDyldCacheUUID:(NSString *)value {
    // Validate UUID format
    if (![self validateUUID:value]) return NO;
    return [self saveCustomValue:value forType:@"DyldCacheUUID"];
}

- (BOOL)setCustomPasteboardUUID:(NSString *)value {
    // Validate UUID format
    if (![self validateUUID:value]) return NO;
    return [self saveCustomValue:value forType:@"PasteboardUUID"];
}

- (BOOL)setCustomKeychainUUID:(NSString *)value {
    // Validate UUID format
    if (![self validateUUID:value]) return NO;
    return [self saveCustomValue:value forType:@"KeychainUUID"];
}

- (BOOL)setCustomUserDefaultsUUID:(NSString *)value {
    // Validate UUID format
    if (![self validateUUID:value]) return NO;
    return [self saveCustomValue:value forType:@"UserDefaultsUUID"];
}

- (BOOL)setCustomAppGroupUUID:(NSString *)value {
    (void)value;
    self.error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Global App Group UUID values are no longer supported"}];
    return NO;
}

- (BOOL)setCustomCoreDataUUID:(NSString *)value {
    // Validate UUID format
    if (![self validateUUID:value]) return NO;
    return [self saveCustomValue:value forType:@"CoreDataUUID"];
}

- (BOOL)setCustomAppInstallUUID:(NSString *)value {
    (void)value;
    self.error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Global App Install UUID values are no longer supported"}];
    return NO;
}

- (BOOL)setCustomAppContainerUUID:(NSString *)value {
    (void)value;
    self.error = [NSError errorWithDomain:@"com.hydra.projectx.app-identity"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Global App Container UUID values are no longer supported"}];
    return NO;
}

- (BOOL)validateUUID:(NSString *)uuid {
    if (!uuid) return NO;
    
    // Verify format: 8-4-4-4-12 hexadecimal characters
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" 
                                                                           options:NSRegularExpressionCaseInsensitive 
                                                                             error:nil];
    
    NSUInteger matches = [regex numberOfMatchesInString:uuid 
                                                options:0 
                                                  range:NSMakeRange(0, uuid.length)];
    
    return matches == 1;
}

#pragma mark - Device Model Specifications

- (NSDictionary *)getDeviceModelSpecifications {
    NSString *identityDir = [self profileIdentityPath];
    if (!identityDir) return nil;
    
    // First, check the device_model.plist file for detailed specifications
    NSString *modelPath = [identityDir stringByAppendingPathComponent:@"device_model.plist"];
    NSDictionary *modelDict = PXProfileReadDictionary(modelPath);
    
    if (modelDict && modelDict.count > 0) {
        return modelDict;
    }
    
    // If not found in dedicated file, check the combined device_ids.plist
    NSString *deviceIdsPath = [identityDir stringByAppendingPathComponent:@"device_ids.plist"];
    NSDictionary *deviceIds = PXProfileReadDictionary(deviceIdsPath);
    
    if (deviceIds && deviceIds[@"DeviceModel"]) {
        NSMutableDictionary *specs = [NSMutableDictionary dictionary];
        
        specs[@"value"] = deviceIds[@"DeviceModel"];
        specs[@"name"] = deviceIds[@"DeviceModelName"] ?: @"Unknown";
        specs[@"screenResolution"] = deviceIds[@"ScreenResolution"] ?: @"Unknown";
        specs[@"viewportResolution"] = deviceIds[@"ViewportResolution"] ?: @"Unknown";
        specs[@"devicePixelRatio"] = deviceIds[@"DevicePixelRatio"] ?: @(0);
        specs[@"screenDensity"] = deviceIds[@"ScreenDensityPPI"] ?: @(0);
        specs[@"cpuArchitecture"] = deviceIds[@"CPUArchitecture"] ?: @"Unknown";
        specs[@"deviceMemory"] = deviceIds[@"DeviceMemory"] ?: @(0);
        specs[@"gpuFamily"] = deviceIds[@"GPUFamily"] ?: @"Unknown";
        specs[@"cpuCoreCount"] = deviceIds[@"CPUCoreCount"] ?: @(0);
        specs[@"metalFeatureSet"] = deviceIds[@"MetalFeatureSet"] ?: @"Unknown";
        
        // Rebuild webGLInfo from simplified fields
        NSMutableDictionary *webGLInfo = [NSMutableDictionary dictionary];
        webGLInfo[@"webglVendor"] = deviceIds[@"WebGLVendor"] ?: @"Apple";
        webGLInfo[@"webglRenderer"] = deviceIds[@"WebGLRenderer"] ?: @"Apple GPU";
        webGLInfo[@"unmaskedVendor"] = @"Apple Inc.";
        webGLInfo[@"unmaskedRenderer"] = deviceIds[@"GPUFamily"] ?: @"Apple GPU";
        webGLInfo[@"webglVersion"] = @"WebGL 2.0";
        webGLInfo[@"maxTextureSize"] = @(16384);
        webGLInfo[@"maxRenderBufferSize"] = @(16384);
        
        specs[@"webGLInfo"] = webGLInfo;
        
        return specs;
    }
    
    // If still not found, get the current device model and fetch its specs
    NSString *currentDeviceModel = [self currentValueForIdentifier:@"DeviceModel"];
    if (currentDeviceModel) {
        DeviceModelManager *deviceManager = [DeviceModelManager sharedManager];
        NSMutableDictionary *specs = [NSMutableDictionary dictionary];
        
        specs[@"value"] = currentDeviceModel;
        specs[@"name"] = [deviceManager deviceModelNameForString:currentDeviceModel] ?: @"Unknown";
        specs[@"screenResolution"] = [deviceManager screenResolutionForModel:currentDeviceModel] ?: @"Unknown";
        specs[@"viewportResolution"] = [deviceManager viewportResolutionForModel:currentDeviceModel] ?: @"Unknown";
        specs[@"devicePixelRatio"] = @([deviceManager devicePixelRatioForModel:currentDeviceModel]);
        specs[@"screenDensity"] = @([deviceManager screenDensityForModel:currentDeviceModel]);
        specs[@"cpuArchitecture"] = [deviceManager cpuArchitectureForModel:currentDeviceModel] ?: @"Unknown";
        specs[@"deviceMemory"] = @([deviceManager deviceMemoryForModel:currentDeviceModel]);
        specs[@"gpuFamily"] = [deviceManager gpuFamilyForModel:currentDeviceModel] ?: @"Unknown";
        specs[@"cpuCoreCount"] = @([deviceManager cpuCoreCountForModel:currentDeviceModel]);
        specs[@"metalFeatureSet"] = [deviceManager metalFeatureSetForModel:currentDeviceModel] ?: @"Unknown";
        specs[@"webGLInfo"] = [deviceManager webGLInfoForModel:currentDeviceModel] ?: @{};
        
        return specs;
    }
    
    
    return nil;
}

- (NSString *)getScreenResolution {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? specs[@"screenResolution"] : @"Unknown";
}

- (NSString *)getViewportResolution {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? specs[@"viewportResolution"] : @"Unknown";
}

- (CGFloat)getDevicePixelRatio {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? [specs[@"devicePixelRatio"] floatValue] : 0.0;
}

- (NSInteger)getScreenDensity {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? [specs[@"screenDensity"] integerValue] : 0;
}

- (NSString *)getCPUArchitecture {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? specs[@"cpuArchitecture"] : @"Unknown";
}

- (NSInteger)getDeviceMemory {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? [specs[@"deviceMemory"] integerValue] : 0;
}

- (NSString *)getGPUFamily {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? specs[@"gpuFamily"] : @"Unknown";
}

- (NSDictionary *)getWebGLInfo {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? specs[@"webGLInfo"] : @{};
}

- (NSInteger)getCPUCoreCount {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? [specs[@"cpuCoreCount"] integerValue] : 0;
}

- (NSString *)getMetalFeatureSet {
    NSDictionary *specs = [self getDeviceModelSpecifications];
    return specs ? specs[@"metalFeatureSet"] : @"Unknown";
}

// Device Theme Methods
- (NSString *)generateDeviceTheme {
    // Generate a random theme (Light or Dark)
    NSArray *themes = @[@"Light", @"Dark"];
    NSInteger randomIndex = arc4random_uniform(2);
    NSString *theme = themes[randomIndex];
    
    // Save the theme to the profile
    return [self setCustomDeviceTheme:theme] ? theme : nil;
}

- (NSString *)toggleDeviceTheme {
    // Get current theme
    NSString *currentTheme = [self currentValueForIdentifier:@"DeviceTheme"];
    
    // Toggle between Light and Dark
    NSString *newTheme;
    if ([currentTheme isEqualToString:@"Light"]) {
        newTheme = @"Dark";
    } else {
        newTheme = @"Light";
    }
    
    // Save the new theme
    return [self setCustomDeviceTheme:newTheme] ? newTheme : nil;
}

- (BOOL)setCustomDeviceTheme:(NSString *)value {
    // Validate theme value
    if (![value isEqualToString:@"Light"] && ![value isEqualToString:@"Dark"]) {
        self.error = [NSError errorWithDomain:@"com.hydra.projectx" code:2004 userInfo:@{NSLocalizedDescriptionKey: @"Invalid Device Theme (must be 'Light' or 'Dark')"}];
        return NO;
    }
    
    BOOL success = PXSetCurrentProfileValue(@"deviceTheme", @{@"value": value});
    if (!success) {
        self.error = [NSError errorWithDomain:@"com.hydra.projectx.profile"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to save Device Theme"}];
    } else {
        self.error = nil;
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.hydra.projectx.toggleDeviceThemeSpoof"),
                                             NULL, NULL, YES);
    }
    return success;
}

#pragma mark - Canvas Fingerprinting Protection

- (BOOL)toggleCanvasFingerprintProtection {
    BOOL currentValue = [self isCanvasFingerprintProtectionEnabled];
    BOOL newValue = !currentValue;
    
    // Update settings
    [self setCanvasFingerprintProtection:newValue];
    
    // Notify change
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.hydra.projectx.toggleCanvasFingerprint"),
        NULL, NULL, TRUE
    );
    
    PXLog(@"[WeaponX] 🎨 Canvas Fingerprint Protection %@", newValue ? @"ENABLED" : @"DISABLED");
    
    return newValue;
}

- (BOOL)isCanvasFingerprintProtectionEnabled {
    // Read directly from the plist file - SINGLE SOURCE OF TRUTH
    NSString *securitySettingsPath = PXSecuritySettingsPath();
    NSDictionary *settingsDict = PXProfileReadDictionary(securitySettingsPath);
    return PXGraphicsProtectionIsEnabledForSettings(settingsDict);
}

- (BOOL)setCanvasFingerprintProtection:(BOOL)enabled {
    // Read and update the plist file directly - SINGLE SOURCE OF TRUTH
    NSString *securitySettingsPath = PXSecuritySettingsPath();
    NSMutableDictionary *settingsDict = [PXProfileReadDictionary(securitySettingsPath) mutableCopy] ?: [NSMutableDictionary dictionary];
    
    // Update with both key names for compatibility
    settingsDict[@"canvasFingerprintingEnabled"] = @(enabled);
    settingsDict[@"CanvasFingerprint"] = @(enabled);
    
    // Write back to the file
    BOOL success = PXProfileWriteDictionary(settingsDict, securitySettingsPath);
    
    // Also update our in-memory settings to keep them in sync
    if (success) {
        NSMutableDictionary *updatedSettings = [self.settings mutableCopy];
        updatedSettings[@"canvasFingerprintingEnabled"] = @(enabled);
        updatedSettings[@"CanvasFingerprint"] = @(enabled);
        self.settings = updatedSettings;
    }
    
    // Notify about the change
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.hydra.projectx.settings.changed"),
        NULL, NULL, TRUE
    );
    
    return YES;
}

- (void)resetCanvasNoise {
    // Post notification to reset canvas noise seeds
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.hydra.projectx.resetCanvasNoise"),
        NULL, NULL, TRUE
    );
    
    PXLog(@"[WeaponX] 🎨 Canvas Fingerprint Noise patterns reset");
}

@end
