#import "AppIdentityHookSupport.h"

#if defined(PROJECTX_APP_IDENTITY_HOOK_SUPPORT_TESTING)
@interface IdentifierManager : NSObject
+ (instancetype)sharedManager;
- (BOOL)isApplicationEnabled:(NSString *)bundleIdentifier;
- (BOOL)isExtensionEnabled:(NSString *)bundleIdentifier;
- (NSString *)profileIdentityPath;
- (NSDictionary *)getApplicationInfo:(NSString *)bundleIdentifier;
- (BOOL)ensureApplicationIdentityForBundleIdentifier:(NSString *)bundleIdentifier
                                     groupIdentifiers:(NSSet<NSString *> *)groupIdentifiers
                                installIdentifierKeys:(NSSet<NSString *> *)installIdentifierKeys
                                                 error:(NSError **)error;
- (PXAppIdentityRecord *)appIdentityForBundleIdentifier:(NSString *)bundleIdentifier;
- (PXAppGroupIdentityRecord *)appGroupIdentityForGroupIdentifier:(NSString *)groupIdentifier;
@end
#else
#import "IdentifierManager.h"
#endif
#import "NetworkIdentity.h"
#import "ProfileManifest.h"
#import "ProjectXLogging.h"
#import "PXRootHidePath.h"

#include <signal.h>
#include <stdlib.h>

static volatile sig_atomic_t PXAppIdentityMappingsChanged = 0;
static volatile sig_atomic_t PXAppIdentityBootstrapDepth = 0;
static PXGraphicsIdentity *PXCachedGraphicsIdentity = nil;
static NSUUID *PXCachedVendorIdentifier = nil;
static NSString *PXCachedVendorGenerationID = nil;
static NSString *PXCachedVendorBundleIdentifier = nil;
static NSString *PXCachedVendorIdentityDirectory = nil;
static NSDictionary<NSString *, id> *PXCachedNetworkIdentity = nil;
static NSString *PXCachedNetworkGenerationID = nil;
static NSString *PXCachedNetworkBundleIdentifier = nil;
static NSString *PXCachedNetworkIdentityDirectory = nil;

static void PXInvalidateCurrentProcessVendorIdentifier(void) {
    @synchronized([PXProfileManifest class]) {
        PXCachedVendorIdentifier = nil;
        PXCachedVendorGenerationID = nil;
        PXCachedVendorBundleIdentifier = nil;
        PXCachedVendorIdentityDirectory = nil;
    }
}

static void PXInvalidateCurrentProcessNetworkIdentity(void) {
    @synchronized([PXProfileManifest class]) {
        PXCachedNetworkIdentity = nil;
        PXCachedNetworkGenerationID = nil;
        PXCachedNetworkBundleIdentifier = nil;
        PXCachedNetworkIdentityDirectory = nil;
    }
}

static void PXGraphicsIdentityChangedCallback(CFNotificationCenterRef center,
                                              void *observer,
                                              CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    PXInvalidateCurrentProcessGraphicsIdentity();
    PXInvalidateCurrentProcessVendorIdentifier();
    PXInvalidateCurrentProcessNetworkIdentity();
}

static void PXObserveGraphicsIdentityChanges(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *names = @[
            @"com.hydra.projectx.profileChanged",
            @"com.hydra.projectx.profileGenerationChanged",
            @"com.hydra.projectx.scopedAppsChanged",
            @"com.hydra.projectx.settings.changed",
            @"com.hydra.projectx.networkConnectionTypeChanged",
            @"com.hydra.projectx.carrierDetailsChanged",
            @"com.hydra.projectx.vpnDetectionBypassChanged",
            @"com.hydra.projectx.toggleCanvasFingerprint",
            @"com.hydra.projectx.canvasFingerprintToggleChanged",
            @"com.hydra.projectx.enableCanvasFingerprintProtection",
            @"com.hydra.projectx.disableCanvasFingerprintProtection",
            @"com.hydra.projectx.resetCanvasNoise"
        ];
        for (NSString *name in names) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL,
                                            PXGraphicsIdentityChangedCallback,
                                            (__bridge CFStringRef)name,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    });
}

static void PXAppIdentityMappingChangedCallback(CFNotificationCenterRef center,
                                                void *observer,
                                                CFStringRef name,
                                                const void *object,
                                                CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    if (PXAppIdentityBootstrapDepth > 0) {
        // ensureApplicationIdentity... publishes synchronously when this
        // process creates its initial app/group/install mapping. That is part
        // of bootstrap, not an external profile mutation.
        return;
    }
    PXAppIdentityMappingsChanged = 1;
}

static void PXProfileMappingChangedCallback(CFNotificationCenterRef center,
                                            void *observer,
                                            CFStringRef name,
                                            const void *object,
                                            CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    // Never suppress a profile-generation switch, including one racing with
    // first-launch identity bootstrap.
    PXAppIdentityMappingsChanged = 1;
}

static IdentifierManager *PXAppIdentityManagerForCurrentProcess(NSString **bundleIdentifier) {
    if (PXAppIdentityMappingsChanged != 0) {
        // Container/install mappings cannot be swapped safely in a running
        // process. Fail closed until the selected app is relaunched instead of
        // serving a mixture of two profile generations.
        return nil;
    }
    NSString *currentBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!PXAppIdentityBundleIsEligible(currentBundleIdentifier, YES, NO)) {
        return nil;
    }
    IdentifierManager *manager = [IdentifierManager sharedManager];
    if (!PXAppIdentityBundleIsEligible(currentBundleIdentifier,
                                       [manager isApplicationEnabled:currentBundleIdentifier],
                                       [manager isExtensionEnabled:currentBundleIdentifier])) {
        return nil;
    }
    if (bundleIdentifier) {
        *bundleIdentifier = currentBundleIdentifier;
    }
    return manager;
}

PXAppIdentityRecord *PXPrepareCurrentProcessAppIdentity(void) {
    NSString *bundleIdentifier = nil;
    IdentifierManager *manager = PXAppIdentityManagerForCurrentProcess(&bundleIdentifier);
    if (!manager) {
        return nil;
    }
    NSDictionary *appInfo = [manager getApplicationInfo:bundleIdentifier];
    NSArray *configuredKeys = [appInfo[@"installIdentifierKeys"] isKindOfClass:[NSArray class]]
        ? appInfo[@"installIdentifierKeys"]
        : @[];
    NSError *error = nil;
    __block BOOL ensured = NO;
    PXAppIdentityBootstrapDepth += 1;
    @try {
        ensured = [manager ensureApplicationIdentityForBundleIdentifier:bundleIdentifier
                                                        groupIdentifiers:[NSSet set]
                                                   installIdentifierKeys:[NSSet setWithArray:configuredKeys]
                                                                    error:&error];
    } @finally {
        PXAppIdentityBootstrapDepth -= 1;
    }
    if (!ensured || PXAppIdentityMappingsChangedSinceLaunch()) {
        return nil;
    }
    return [manager appIdentityForBundleIdentifier:bundleIdentifier];
}

PXAppGroupIdentityRecord *PXPrepareCurrentProcessGroupIdentity(NSString *groupIdentifier) {
    if (groupIdentifier.length == 0) {
        return nil;
    }
    return PXPrepareCurrentProcessGroupIdentities(
        [NSSet setWithObject:groupIdentifier]
    )[groupIdentifier];
}

NSDictionary<NSString *, PXAppGroupIdentityRecord *> *PXPrepareCurrentProcessGroupIdentities(
    NSSet<NSString *> *groupIdentifiers
) {
    if (groupIdentifiers.count == 0) {
        return @{};
    }
    NSString *bundleIdentifier = nil;
    IdentifierManager *manager = PXAppIdentityManagerForCurrentProcess(&bundleIdentifier);
    if (!manager) {
        return @{};
    }
    NSError *error = nil;
    __block BOOL ensured = NO;
    PXAppIdentityBootstrapDepth += 1;
    @try {
        ensured = [manager ensureApplicationIdentityForBundleIdentifier:bundleIdentifier
                                                        groupIdentifiers:groupIdentifiers
                                                   installIdentifierKeys:[NSSet set]
                                                                    error:&error];
    } @finally {
        PXAppIdentityBootstrapDepth -= 1;
    }
    if (!ensured || PXAppIdentityMappingsChangedSinceLaunch()) {
        return @{};
    }
    NSMutableDictionary<NSString *, PXAppGroupIdentityRecord *> *identities = [NSMutableDictionary dictionary];
    for (NSString *groupIdentifier in groupIdentifiers) {
        PXAppGroupIdentityRecord *identity = [manager appGroupIdentityForGroupIdentifier:groupIdentifier];
        if (identity) {
            identities[groupIdentifier] = identity;
        }
    }
    return [identities copy];
}

PXGraphicsIdentity *PXPrepareCurrentProcessGraphicsIdentity(void) {
    PXObserveGraphicsIdentityChanges();
    @synchronized([PXGraphicsIdentity class]) {
        if (PXCachedGraphicsIdentity) {
            return PXCachedGraphicsIdentity;
        }
        IdentifierManager *manager = PXAppIdentityManagerForCurrentProcess(NULL);
        NSString *identityDirectory = [manager profileIdentityPath];
        NSDictionary<NSString *, id> *settings =
            PXProfileReadDictionary(PXSecuritySettingsPath());
        if (!manager || !PXGraphicsProtectionIsEnabledForSettings(settings) ||
            identityDirectory.length == 0) {
            return nil;
        }
        PXProfileManifest *manifest = [[[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory]
            activeManifestWithError:nil];
        PXGraphicsIdentity *identity = [PXGraphicsIdentity
            identityWithPropertyList:manifest.graphics
            error:nil];
        if (!identity ||
            ![identity validateAgainstModelRecord:manifest.device
                                  hostCapabilities:identity.hostCapabilities
                                             error:nil]) {
            return nil;
        }
        PXCachedGraphicsIdentity = identity;
        return PXCachedGraphicsIdentity;
    }
}

NSUUID *PXPrepareScopedVendorIdentifier(NSString *bundleIdentifier,
                                       NSString *identityDirectory) {
    PXObserveGraphicsIdentityChanges();
    if (bundleIdentifier.length == 0 || identityDirectory.length == 0) {
        return nil;
    }

    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    NSString *activeGenerationID = [store activeGenerationIDWithError:nil];
    if (activeGenerationID.length == 0) {
        return nil;
    }

    @synchronized([PXProfileManifest class]) {
        if (PXCachedVendorIdentifier &&
            [PXCachedVendorGenerationID isEqualToString:activeGenerationID] &&
            [PXCachedVendorBundleIdentifier isEqualToString:bundleIdentifier] &&
            [PXCachedVendorIdentityDirectory isEqualToString:identityDirectory]) {
            return PXCachedVendorIdentifier;
        }
        PXProfileManifest *manifest = [store activeManifestWithError:nil];
        if (![manifest.generationID isEqualToString:activeGenerationID]) {
            return nil;
        }
        NSUUID *vendorIdentifier = PXProfileVendorIdentifierForBundleIdentifier(
            manifest,
            bundleIdentifier);
        if (!vendorIdentifier) {
            return nil;
        }
        PXCachedVendorIdentifier = vendorIdentifier;
        PXCachedVendorGenerationID = activeGenerationID;
        PXCachedVendorBundleIdentifier = bundleIdentifier;
        PXCachedVendorIdentityDirectory = identityDirectory;
        PXLog(@"[WeaponX] Native vendor identity ready for scoped app %@ generation %@",
              bundleIdentifier,
              manifest.generationID);
        return PXCachedVendorIdentifier;
    }
}

NSUUID *PXPrepareCurrentProcessVendorIdentifier(void) {
    NSString *bundleIdentifier = nil;
    IdentifierManager *manager = PXAppIdentityManagerForCurrentProcess(&bundleIdentifier);
    if (!manager) {
        return nil;
    }
    return PXPrepareScopedVendorIdentifier(bundleIdentifier, [manager profileIdentityPath]);
}

NSDictionary<NSString *, id> *PXPrepareScopedNetworkIdentity(NSString *bundleIdentifier,
                                                              NSString *identityDirectory) {
    PXObserveGraphicsIdentityChanges();
    if (bundleIdentifier.length == 0 || identityDirectory.length == 0) {
        return nil;
    }

    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    NSString *activeGenerationID = [store activeGenerationIDWithError:nil];
    if (activeGenerationID.length == 0) {
        return nil;
    }

    @synchronized([PXProfileManifest class]) {
        if (PXCachedNetworkIdentity &&
            [PXCachedNetworkGenerationID isEqualToString:activeGenerationID] &&
            [PXCachedNetworkBundleIdentifier isEqualToString:bundleIdentifier] &&
            [PXCachedNetworkIdentityDirectory isEqualToString:identityDirectory]) {
            return PXCachedNetworkIdentity;
        }
        PXProfileManifest *manifest = [store activeManifestWithError:nil];
        if (![manifest.generationID isEqualToString:activeGenerationID] ||
            !manifest.appIdentities[bundleIdentifier] ||
            !PXNetworkIdentityIsCoherent(manifest.network)) {
            return nil;
        }
        PXCachedNetworkIdentity = [manifest.network copy];
        PXCachedNetworkGenerationID = activeGenerationID;
        PXCachedNetworkBundleIdentifier = bundleIdentifier;
        PXCachedNetworkIdentityDirectory = identityDirectory;
        PXLog(@"[WeaponX] Network identity ready for selected target and current generation");
        return PXCachedNetworkIdentity;
    }
}

NSDictionary<NSString *, id> *PXPrepareCurrentProcessNetworkIdentity(void) {
    NSString *bundleIdentifier = nil;
    IdentifierManager *manager = PXAppIdentityManagerForCurrentProcess(&bundleIdentifier);
    if (!manager) {
        return nil;
    }
    return PXPrepareScopedNetworkIdentity(bundleIdentifier, [manager profileIdentityPath]);
}

void PXInvalidateCurrentProcessGraphicsIdentity(void) {
    @synchronized([PXGraphicsIdentity class]) {
        PXCachedGraphicsIdentity = nil;
    }
}

BOOL PXPrepareCurrentProcessDataPathMapping(PXAppIdentityRecord *identity) {
    if (!identity || PXAppIdentityMappingsChangedSinceLaunch()) {
        return NO;
    }
    const char *homeEnvironment = getenv("HOME");
    NSString *realHome = homeEnvironment ? [NSString stringWithUTF8String:homeEnvironment] : nil;
    if (realHome.length == 0 || !PXIsValidRealDataContainerRoot(realHome)) {
        return NO;
    }
    return [[PXAppIdentityRuntime sharedRuntime] configureRealDataRoot:realHome
                                                      virtualDataRoot:PXVirtualDataContainerRoot(identity.containerUUID)];
}

void PXObserveAppIdentityMappingChanges(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *profileNames = @[
            @"com.hydra.projectx.profileChanged",
            @"com.hydra.projectx.profileGenerationChanged"
        ];
        for (NSString *name in profileNames) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL,
                                            PXProfileMappingChangedCallback,
                                            (__bridge CFStringRef)name,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        // All three identity hook constructors bootstrap from the same image.
        // Register the app-identity observer on the first main-queue turn so
        // each constructor may create its own initial app/group/install
        // records without interpreting a sibling constructor's notification
        // as an external live mutation. Profile observers above remain active
        // immediately, so a real generation switch still fails closed.
        dispatch_async(dispatch_get_main_queue(), ^{
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL,
                                            PXAppIdentityMappingChangedCallback,
                                            CFSTR("com.hydra.projectx.appIdentityChanged"),
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        });
    });
}

BOOL PXAppIdentityMappingsChangedSinceLaunch(void) {
    return PXAppIdentityMappingsChanged != 0;
}

NSString *PXVirtualDataContainerRoot(NSString *containerUUID) {
    return [@"/var/mobile/Containers/Data/Application" stringByAppendingPathComponent:containerUUID];
}

NSString *PXVirtualAppGroupRoot(NSString *containerUUID) {
    return [@"/var/mobile/Containers/Shared/AppGroup" stringByAppendingPathComponent:containerUUID];
}
