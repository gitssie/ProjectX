#import "PXTargetSelectionReconciler.h"

#import "AppIdentity.h"
#import "PXTargetAppEligibility.h"
#import "PXScopedAppStore.h"

@interface LSApplicationWorkspace : NSObject
+ (nullable instancetype)defaultWorkspace;
- (nullable NSArray *)allInstalledApplications;
@end

@interface LSApplicationProxy : NSObject
+ (nullable instancetype)applicationProxyForIdentifier:(NSString *)bundleIdentifier;
@property (nonatomic, readonly, nullable) NSString *applicationIdentifier;
@property (nonatomic, readonly, nullable) NSString *localizedName;
@property (nonatomic, readonly, nullable) NSString *bundleExecutable;
@property (nonatomic, readonly, nullable) NSURL *bundleURL;
@property (nonatomic, readonly) BOOL isInstalled;
@end

NSString *const PXTargetSelectionReconciliationErrorDomain =
    @"com.hydra.projectx.target-selection-reconciliation";
NSString *const PXTargetSelectionAppIdentityChangedNotification =
    @"com.hydra.projectx.appIdentityChanged";
NSString *const PXTargetSelectionScopeChangedNotification =
    @"com.hydra.projectx.scopedAppsChanged";

@interface PXInstalledAppSnapshot ()
@property (nonatomic, assign, readwrite, getter=isTrusted) BOOL trusted;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *installedUserBundleIdentifiers;
@property (nonatomic, copy, readwrite) NSArray<NSDictionary<NSString *, id> *> *applicationCandidates;
@property (nonatomic, copy, readwrite, nullable) NSString *failureReason;
@end

@implementation PXInstalledAppSnapshot

+ (instancetype)trustedSnapshotWithInstalledUserBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                                             applicationCandidates:(NSArray<NSDictionary<NSString *, id> *> *)candidates {
    for (id bundleIdentifier in bundleIdentifiers) {
        if (![bundleIdentifier isKindOfClass:[NSString class]] ||
            [bundleIdentifier hasPrefix:@"com.apple."] ||
            !PXTargetBundleIdentifierIsValid(bundleIdentifier) ||
            !PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO)) {
            return [self untrustedSnapshotWithApplicationCandidates:candidates
                                                             reason:@"Installed Target snapshot contains an invalid user Bundle ID"];
        }
    }
    PXInstalledAppSnapshot *snapshot = [[self alloc] init];
    snapshot.trusted = YES;
    snapshot.installedUserBundleIdentifiers = bundleIdentifiers;
    snapshot.applicationCandidates = candidates;
    return snapshot;
}

+ (instancetype)untrustedSnapshotWithApplicationCandidates:(NSArray<NSDictionary<NSString *, id> *> *)candidates
                                                     reason:(NSString *)reason {
    PXInstalledAppSnapshot *snapshot = [[self alloc] init];
    snapshot.trusted = NO;
    snapshot.installedUserBundleIdentifiers = [NSSet set];
    snapshot.applicationCandidates = candidates;
    snapshot.failureReason = reason;
    return snapshot;
}

@end


@interface PXLaunchServicesInstalledAppSnapshotProvider ()
- (Class)launchServicesWorkspaceClass;
- (Class)launchServicesApplicationProxyClass;
@end

@implementation PXLaunchServicesInstalledAppSnapshotProvider

- (Class)launchServicesWorkspaceClass {
    return NSClassFromString(@"LSApplicationWorkspace");
}

- (Class)launchServicesApplicationProxyClass {
    return NSClassFromString(@"LSApplicationProxy");
}

- (PXInstalledAppSnapshot *)installedAppSnapshotForSelectedBundleIdentifiers:(NSSet<NSString *> *)selectedBundleIdentifiers
                                                                        error:(NSError **)error {
    Class workspaceClass = [self launchServicesWorkspaceClass];
    if (!workspaceClass || ![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        if (error) {
            *error = [NSError errorWithDomain:PXTargetSelectionReconciliationErrorDomain
                                         code:PXTargetSelectionReconciliationErrorSnapshotUnavailable
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"LaunchServices installed-app enumeration is unavailable"}];
        }
        return nil;
    }

    LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
    if (!workspace || ![workspace respondsToSelector:@selector(allInstalledApplications)]) {
        if (error) {
            *error = [NSError errorWithDomain:PXTargetSelectionReconciliationErrorDomain
                                         code:PXTargetSelectionReconciliationErrorSnapshotUnavailable
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"LaunchServices workspace is unavailable"}];
        }
        return nil;
    }

    NSArray *applications = nil;
    @try {
        applications = [workspace allInstalledApplications];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:PXTargetSelectionReconciliationErrorDomain
                                         code:PXTargetSelectionReconciliationErrorSnapshotUnavailable
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"LaunchServices installed-app enumeration failed",
                @"exceptionName": exception.name ?: @"unknown"
            }];
        }
        return nil;
    }
    if (![applications isKindOfClass:[NSArray class]] || applications.count == 0) {
        return [PXInstalledAppSnapshot
            untrustedSnapshotWithApplicationCandidates:@[]
            reason:@"LaunchServices did not return a complete installed-app snapshot"];
    }

    NSMutableSet<NSString *> *installedUserBundleIdentifiers = [NSMutableSet set];
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (id candidate in applications) {
        if (![candidate respondsToSelector:@selector(applicationIdentifier)] ||
            ![candidate respondsToSelector:@selector(isInstalled)]) {
            return [PXInstalledAppSnapshot
                untrustedSnapshotWithApplicationCandidates:candidates
                reason:@"LaunchServices returned a partial installed-app snapshot"];
        }
        LSApplicationProxy *proxy = candidate;
        NSString *bundleIdentifier = proxy.applicationIdentifier;
        if (!proxy.isInstalled || !PXTargetBundleIdentifierIsValid(bundleIdentifier)) {
            continue;
        }
        if (![bundleIdentifier hasPrefix:@"com.apple."] &&
            PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO)) {
            [installedUserBundleIdentifiers addObject:bundleIdentifier];
        }
        NSString *displayName = proxy.localizedName;
        NSString *executableName = proxy.bundleExecutable;
        NSURL *bundleURL = proxy.bundleURL;
        NSString *bundleExtension = bundleURL.path.pathExtension ?: @"";
        NSString *executablePath = executableName.length > 0
            ? [bundleURL.path stringByAppendingPathComponent:executableName]
            : nil;
        BOOL executableAvailable = executablePath.length > 0 &&
            [fileManager isExecutableFileAtPath:executablePath];
        NSDictionary<NSString *, id> *info = bundleURL
            ? [NSDictionary dictionaryWithContentsOfURL:
                [bundleURL URLByAppendingPathComponent:@"Info.plist"]]
            : nil;
        BOOL isAppClip = [info[@"NSAppClip"] isKindOfClass:[NSDictionary class]];
        NSArray<NSString *> *appTags = [info[@"SBAppTags"] isKindOfClass:[NSArray class]]
            ? info[@"SBAppTags"]
            : @[];
        BOOL isHidden = displayName.length == 0 || [appTags containsObject:@"hidden"] ||
            [appTags containsObject:@"system-service"];
        BOOL isPlaceholder = [bundleURL.path.lowercaseString containsString:@"placeholder"];
        NSString *applicationType = [info[@"ApplicationType"] isKindOfClass:[NSString class]]
            ? info[@"ApplicationType"]
            : ([bundleIdentifier hasPrefix:@"com.apple."] ? @"System" : @"User");
        [candidates addObject:@{
            @"bundleIdentifier": bundleIdentifier,
            @"displayName": displayName ?: @"",
            @"bundlePathExtension": bundleExtension,
            @"executableName": executableName ?: @"",
            @"applicationType": applicationType,
            @"installed": @YES,
            @"hidden": @(isHidden),
            @"plugin": @([bundleExtension.lowercaseString isEqualToString:@"appex"]),
            @"appClip": @(isAppClip),
            @"placeholder": @(isPlaceholder),
            @"launchProhibited": @(!executableAvailable),
            @"bundleURL": bundleURL ?: [NSURL fileURLWithPath:@"/"]
        }];
    }
    if (candidates.count == 0) {
        return [PXInstalledAppSnapshot
            untrustedSnapshotWithApplicationCandidates:@[]
            reason:@"LaunchServices did not return any addressable installed apps"];
    }
    Class proxyClass = [self launchServicesApplicationProxyClass];
    if (!proxyClass || ![proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        return [PXInstalledAppSnapshot
            untrustedSnapshotWithApplicationCandidates:candidates
            reason:@"LaunchServices cannot verify missing selected Target Apps"];
    }
    for (NSString *selectedBundleIdentifier in selectedBundleIdentifiers) {
        if ([selectedBundleIdentifier hasPrefix:@"com.apple."] ||
            !PXTargetBundleIdentifierIsValid(selectedBundleIdentifier) ||
            !PXAppIdentityBundleIsEligible(selectedBundleIdentifier, YES, NO) ||
            [installedUserBundleIdentifiers containsObject:selectedBundleIdentifier]) {
            continue;
        }
        LSApplicationProxy *selectedProxy = nil;
        @try {
            selectedProxy = [proxyClass applicationProxyForIdentifier:selectedBundleIdentifier];
        } @catch (NSException *exception) {
            return [PXInstalledAppSnapshot
                untrustedSnapshotWithApplicationCandidates:candidates
                reason:[NSString stringWithFormat:@"LaunchServices could not verify a missing Target App (%@)",
                    exception.name ?: @"unknown"]];
        }
        if (selectedProxy && (![selectedProxy respondsToSelector:@selector(isInstalled)] ||
                              selectedProxy.isInstalled)) {
            return [PXInstalledAppSnapshot
                untrustedSnapshotWithApplicationCandidates:candidates
                reason:@"LaunchServices returned a partial installed-app snapshot"];
        }
    }
    return [PXInstalledAppSnapshot
        trustedSnapshotWithInstalledUserBundleIdentifiers:installedUserBundleIdentifiers
        applicationCandidates:candidates];
}

@end


@interface PXAtomicTargetSelectionStateStore ()
@property (nonatomic, copy) NSString *scopeFilePath;
@property (nonatomic, strong) PXScopedAppStore *scopeStore;
@property (nonatomic, strong) id<PXTargetSelectionPolicyStoring> policyStore;
@property (nonatomic, strong) id<PXTargetSelectionIdentityStoring> identityStore;
@property (nonatomic, copy, nullable) PXTargetSelectionCacheInvalidator cacheInvalidator;
@property (nonatomic, copy, nullable) PXTargetSelectionNotificationPublisher notificationPublisher;
@end

@implementation PXAtomicTargetSelectionStateStore

- (instancetype)initWithScopeFilePath:(NSString *)scopeFilePath
                           policyStore:(id<PXTargetSelectionPolicyStoring>)policyStore
                         identityStore:(id<PXTargetSelectionIdentityStoring>)identityStore
                      cacheInvalidator:(PXTargetSelectionCacheInvalidator)cacheInvalidator
                 notificationPublisher:(PXTargetSelectionNotificationPublisher)notificationPublisher {
    self = [super init];
    if (self) {
        _scopeFilePath = [scopeFilePath.stringByStandardizingPath copy];
        _scopeStore = [[PXScopedAppStore alloc] initWithFilePath:_scopeFilePath];
        _policyStore = policyStore;
        _identityStore = identityStore;
        _cacheInvalidator = [cacheInvalidator copy];
        _notificationPublisher = [notificationPublisher copy];
    }
    return self;
}

- (NSError *)stateErrorWithCode:(PXTargetSelectionReconciliationError)code
                     description:(NSString *)description
                      underlying:(NSError *)underlyingError {
    NSMutableDictionary<NSString *, id> *userInfo = [@{
        NSLocalizedDescriptionKey: description
    } mutableCopy];
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:PXTargetSelectionReconciliationErrorDomain
                               code:code
                           userInfo:userInfo];
}

- (nullable NSDictionary<NSString *, id> *)scopePropertyListWithError:(NSError **)error {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopedApplications =
        [self.scopeStore scopedApplicationsWithError:error];
    return scopedApplications ? @{ @"ScopedApps": scopedApplications } : nil;
}

- (NSSet<NSString *> *)selectedTargetBundleIdentifiersWithError:(NSError **)error {
    NSDictionary<NSString *, id> *propertyList = [self scopePropertyListWithError:error];
    if (!propertyList) {
        return nil;
    }
    return PXEnabledEligibleAppBundleIdentifiers(propertyList[@"ScopedApps"]);
}

- (BOOL)writeScopePropertyList:(NSDictionary<NSString *, id> *)propertyList
                         error:(NSError **)error {
    if (self.failBeforeScopeCommitForTesting) {
        self.failBeforeScopeCommitForTesting = NO;
        if (error) {
            *error = [self stateErrorWithCode:PXTargetSelectionReconciliationErrorStateCommitFailed
                                  description:@"Selected Target scope could not be committed"
                                   underlying:nil];
        }
        return NO;
    }
    NSError *scopeError = nil;
    if (![self.scopeStore replaceScopedApplications:propertyList[@"ScopedApps"]
                                               error:&scopeError]) {
        if (error) {
            *error = [self stateErrorWithCode:PXTargetSelectionReconciliationErrorStateCommitFailed
                                  description:@"Selected Target scope could not be committed"
                                   underlying:scopeError];
        }
        return NO;
    }
    return YES;
}

- (BOOL)finishRollbackWithPolicyPending:(BOOL)pendingChanges
                prunedBundleIdentifiers:(NSSet<NSString *> *)prunedBundleIdentifiers
                         appIdentities:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)appIdentities
                         originalError:(NSError *)originalError
                                 error:(NSError **)error {
    NSError *policyError = nil;
    BOOL policyRestored = [self.policyStore
        setPendingChanges:pendingChanges
        prunedTargetBundleIdentifiers:prunedBundleIdentifiers
        error:&policyError];
    NSError *identityError = nil;
    BOOL identitiesRestored = [self.identityStore
        replaceActiveApplicationIdentityPropertyLists:appIdentities
        error:&identityError];
    if (policyRestored && identitiesRestored) {
        if (error) *error = originalError;
        return NO;
    }
    NSError *rollbackError = policyError ?: identityError;
    if (error) {
        *error = [self stateErrorWithCode:PXTargetSelectionReconciliationErrorStateRollbackFailed
                              description:@"Selected Target reconciliation rollback failed"
                               underlying:rollbackError ?: originalError];
    }
    return NO;
}

- (BOOL)pruneTargetBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                               error:(NSError **)error {
    if (bundleIdentifiers.count == 0) {
        return YES;
    }
    for (NSString *bundleIdentifier in bundleIdentifiers) {
        if ([bundleIdentifier hasPrefix:@"com.apple."] ||
            !PXTargetBundleIdentifierIsValid(bundleIdentifier) ||
            !PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO)) {
            if (error) {
                *error = [self stateErrorWithCode:PXTargetSelectionReconciliationErrorStateInvalid
                                      description:@"Only validated user Target Apps may be pruned"
                                       underlying:nil];
            }
            return NO;
        }
    }

    NSDictionary<NSString *, id> *originalScope = [self scopePropertyListWithError:error];
    if (!originalScope) {
        return NO;
    }
    NSError *pendingReadError = nil;
    BOOL originalPendingChanges = [self.policyStore hasPendingChangesWithError:&pendingReadError];
    if (pendingReadError) {
        if (error) *error = pendingReadError;
        return NO;
    }
    NSSet<NSString *> *originalPrunedBundleIdentifiers =
        [self.policyStore prunedTargetBundleIdentifiersWithError:&pendingReadError];
    if (!originalPrunedBundleIdentifiers) {
        if (error) *error = pendingReadError;
        return NO;
    }
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *originalIdentities =
        [self.identityStore activeApplicationIdentityPropertyListsWithError:error];
    if (!originalIdentities) {
        return NO;
    }

    NSMutableDictionary<NSString *, id> *updatedScope = [originalScope mutableCopy];
    NSMutableDictionary<NSString *, id> *updatedScopedApps =
        [originalScope[@"ScopedApps"] mutableCopy];
    [updatedScopedApps removeObjectsForKeys:bundleIdentifiers.allObjects];
    updatedScope[@"ScopedApps"] = [updatedScopedApps copy];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *updatedIdentities =
        [originalIdentities mutableCopy];
    [updatedIdentities removeObjectsForKeys:bundleIdentifiers.allObjects];

    NSError *commitError = nil;
    if (![self.identityStore replaceActiveApplicationIdentityPropertyLists:updatedIdentities
                                                                      error:&commitError]) {
        if (error) *error = commitError;
        return NO;
    }
    NSMutableSet<NSString *> *updatedPrunedBundleIdentifiers =
        [originalPrunedBundleIdentifiers mutableCopy];
    [updatedPrunedBundleIdentifiers unionSet:bundleIdentifiers];
    if (![self.policyStore
        setPendingChanges:YES
        prunedTargetBundleIdentifiers:updatedPrunedBundleIdentifiers
        error:&commitError]) {
        return [self finishRollbackWithPolicyPending:originalPendingChanges
                             prunedBundleIdentifiers:originalPrunedBundleIdentifiers
                                       appIdentities:originalIdentities
                                       originalError:commitError
                                               error:error];
    }
    if (![self writeScopePropertyList:updatedScope error:&commitError]) {
        return [self finishRollbackWithPolicyPending:originalPendingChanges
                             prunedBundleIdentifiers:originalPrunedBundleIdentifiers
                                       appIdentities:originalIdentities
                                       originalError:commitError
                                               error:error];
    }

    if (self.cacheInvalidator) {
        self.cacheInvalidator();
    }
    if (self.notificationPublisher) {
        self.notificationPublisher(PXTargetSelectionAppIdentityChangedNotification);
        self.notificationPublisher(PXTargetSelectionScopeChangedNotification);
    }
    return YES;
}

@end


@interface PXTargetSelectionReconciliationResult ()
@property (nonatomic, copy, readwrite) NSSet<NSString *> *selectedBundleIdentifiers;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *unavailableBundleIdentifiers;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *prunedBundleIdentifiers;
@property (nonatomic, strong, readwrite, nullable) PXInstalledAppSnapshot *snapshot;
@end

@implementation PXTargetSelectionReconciliationResult

+ (instancetype)resultWithSelectedBundleIdentifiers:(NSSet<NSString *> *)selectedBundleIdentifiers
                             prunedBundleIdentifiers:(NSSet<NSString *> *)prunedBundleIdentifiers {
    PXTargetSelectionReconciliationResult *result = [[self alloc] init];
    result.selectedBundleIdentifiers = selectedBundleIdentifiers;
    result.unavailableBundleIdentifiers = [NSSet set];
    result.prunedBundleIdentifiers = prunedBundleIdentifiers;
    return result;
}

+ (instancetype)resultWithSelectedBundleIdentifiers:(NSSet<NSString *> *)selectedBundleIdentifiers
                         unavailableBundleIdentifiers:(NSSet<NSString *> *)unavailableBundleIdentifiers {
    PXTargetSelectionReconciliationResult *result = [[self alloc] init];
    result.selectedBundleIdentifiers = selectedBundleIdentifiers;
    result.unavailableBundleIdentifiers = unavailableBundleIdentifiers;
    result.prunedBundleIdentifiers = [NSSet set];
    return result;
}

@end


@interface PXTargetSelectionReconciler ()
@property (nonatomic, strong) id<PXInstalledAppSnapshotProviding> snapshotProvider;
@property (nonatomic, strong) id<PXTargetSelectionStateStoring> stateStore;
- (nullable PXTargetSelectionReconciliationResult *)reconcileSelectedBundleIdentifiers:(NSSet<NSString *> *)selected
                                                                           withSnapshot:(PXInstalledAppSnapshot *)snapshot
                                                                                   error:(NSError * _Nullable * _Nullable)error;
@end

@implementation PXTargetSelectionReconciler

- (instancetype)initWithSnapshotProvider:(id<PXInstalledAppSnapshotProviding>)snapshotProvider
                               stateStore:(id<PXTargetSelectionStateStoring>)stateStore {
    self = [super init];
    if (self) {
        _snapshotProvider = snapshotProvider;
        _stateStore = stateStore;
    }
    return self;
}

- (PXTargetSelectionReconciliationResult *)reconcileWithError:(NSError **)error {
    NSSet<NSString *> *selected = [self.stateStore selectedTargetBundleIdentifiersWithError:error];
    if (!selected) {
        return nil;
    }
    PXInstalledAppSnapshot *snapshot = [self.snapshotProvider
        installedAppSnapshotForSelectedBundleIdentifiers:selected
        error:error];
    if (!snapshot) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:PXTargetSelectionReconciliationErrorDomain
                                         code:PXTargetSelectionReconciliationErrorSnapshotUnavailable
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Installed Target enumeration is unavailable"}];
        }
        return nil;
    }
    PXTargetSelectionReconciliationResult *result = [self
        reconcileSelectedBundleIdentifiers:selected
        withSnapshot:snapshot
        error:error];
    result.snapshot = snapshot;
    return result;
}

- (PXTargetSelectionReconciliationResult *)reconcileWithSnapshot:(PXInstalledAppSnapshot *)snapshot
                                                            error:(NSError **)error {
    NSSet<NSString *> *selected = [self.stateStore selectedTargetBundleIdentifiersWithError:error];
    if (!selected) {
        return nil;
    }
    PXTargetSelectionReconciliationResult *result = [self
        reconcileSelectedBundleIdentifiers:selected
        withSnapshot:snapshot
        error:error];
    result.snapshot = snapshot;
    return result;
}

- (PXTargetSelectionReconciliationResult *)reconcileSelectedBundleIdentifiers:(NSSet<NSString *> *)selected
                                                                  withSnapshot:(PXInstalledAppSnapshot *)snapshot
                                                                          error:(NSError **)error {
    if (!snapshot.isTrusted) {
        if (error) {
            *error = [NSError errorWithDomain:PXTargetSelectionReconciliationErrorDomain
                                         code:PXTargetSelectionReconciliationErrorSnapshotUntrusted
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         snapshot.failureReason ?: @"Installed Target enumeration is not trustworthy"}];
        }
        return nil;
    }
    NSMutableSet<NSString *> *unavailable = [NSMutableSet set];
    for (NSString *bundleIdentifier in selected) {
        BOOL protectedSystemTarget = [bundleIdentifier hasPrefix:@"com.apple."];
        if (!protectedSystemTarget &&
            PXTargetBundleIdentifierIsValid(bundleIdentifier) &&
            PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO) &&
            ![snapshot.installedUserBundleIdentifiers containsObject:bundleIdentifier]) {
            [unavailable addObject:bundleIdentifier];
        }
    }
    NSMutableSet<NSString *> *effectiveSelection = [selected mutableCopy];
    [effectiveSelection minusSet:unavailable];
    return [PXTargetSelectionReconciliationResult
        resultWithSelectedBundleIdentifiers:effectiveSelection
        unavailableBundleIdentifiers:unavailable];
}

@end
