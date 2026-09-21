#import <Foundation/Foundation.h>
#include <assert.h>

#import "PXTargetAppEligibility.h"
#import "PXTargetSelectionReconciler.h"

@interface PXTestLaunchServicesWorkspace : NSObject
+ (instancetype)defaultWorkspace;
+ (void)setInstalledApplicationsForTesting:(NSArray *)applications;
- (NSArray *)allInstalledApplications;
@end

static NSArray *PXTestInstalledApplications;

@implementation PXTestLaunchServicesWorkspace

+ (instancetype)defaultWorkspace {
    static PXTestLaunchServicesWorkspace *workspace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        workspace = [[self alloc] init];
    });
    return workspace;
}

+ (void)setInstalledApplicationsForTesting:(NSArray *)applications {
    PXTestInstalledApplications = [applications copy];
}

- (NSArray *)allInstalledApplications {
    return PXTestInstalledApplications;
}

@end


@interface PXTestLaunchServicesProxy : NSObject
@property (nonatomic, copy, nullable) NSString *applicationIdentifier;
@property (nonatomic, copy, nullable) NSString *localizedName;
@property (nonatomic, copy, nullable) NSString *bundleExecutable;
@property (nonatomic, strong, nullable) NSURL *bundleURL;
@property (nonatomic, assign, getter=isInstalled) BOOL installed;
+ (nullable id)applicationProxyForIdentifier:(NSString *)bundleIdentifier;
+ (void)setSelectedApplicationProxiesForTesting:(NSDictionary<NSString *, id> *)proxies;
+ (nullable NSString *)lastVerifiedBundleIdentifierForTesting;
@end

static NSDictionary<NSString *, id> *PXTestSelectedApplicationProxies;
static NSString *PXTestLastVerifiedBundleIdentifier;

@implementation PXTestLaunchServicesProxy

+ (id)applicationProxyForIdentifier:(NSString *)bundleIdentifier {
    PXTestLastVerifiedBundleIdentifier = [bundleIdentifier copy];
    return PXTestSelectedApplicationProxies[bundleIdentifier];
}

+ (void)setSelectedApplicationProxiesForTesting:(NSDictionary<NSString *, id> *)proxies {
    PXTestSelectedApplicationProxies = [proxies copy];
    PXTestLastVerifiedBundleIdentifier = nil;
}

+ (NSString *)lastVerifiedBundleIdentifierForTesting {
    return PXTestLastVerifiedBundleIdentifier;
}

@end


@interface PXTestPartialLaunchServicesProxy : NSObject
@end

@implementation PXTestPartialLaunchServicesProxy
@end


@interface PXTestLaunchServicesSnapshotProvider : PXLaunchServicesInstalledAppSnapshotProvider
- (Class)launchServicesWorkspaceClass;
- (Class)launchServicesApplicationProxyClass;
@end

@implementation PXTestLaunchServicesSnapshotProvider

- (Class)launchServicesWorkspaceClass {
    return [PXTestLaunchServicesWorkspace class];
}

- (Class)launchServicesApplicationProxyClass {
    return [PXTestLaunchServicesProxy class];
}

@end

@interface PXTestInstalledAppSnapshotProvider : NSObject <PXInstalledAppSnapshotProviding>
@property (nonatomic, strong) PXInstalledAppSnapshot *snapshot;
@property (nonatomic, copy) NSSet<NSString *> *requestedBundleIdentifiers;
@end

@implementation PXTestInstalledAppSnapshotProvider

- (PXInstalledAppSnapshot *)installedAppSnapshotForSelectedBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                                                                        error:(NSError **)error {
    (void)error;
    self.requestedBundleIdentifiers = bundleIdentifiers;
    return self.snapshot;
}

@end


@interface PXTestTargetSelectionStateStore : NSObject <PXTargetSelectionStateStoring>
@property (nonatomic, copy) NSSet<NSString *> *selectedBundleIdentifiers;
@end

@implementation PXTestTargetSelectionStateStore

- (NSSet<NSString *> *)selectedTargetBundleIdentifiersWithError:(NSError **)error {
    (void)error;
    return self.selectedBundleIdentifiers;
}

- (BOOL)pruneTargetBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                               error:(NSError **)error {
    (void)error;
    NSMutableSet<NSString *> *remaining = [self.selectedBundleIdentifiers mutableCopy];
    [remaining minusSet:bundleIdentifiers];
    self.selectedBundleIdentifiers = remaining;
    return YES;
}

@end


@interface PXTestTargetSelectionPolicyStore : NSObject <PXTargetSelectionPolicyStoring>
@property (nonatomic, assign) BOOL pendingChanges;
@property (nonatomic, copy) NSSet<NSString *> *prunedBundleIdentifiers;
@end

@implementation PXTestTargetSelectionPolicyStore

- (BOOL)hasPendingChangesWithError:(NSError **)error {
    (void)error;
    return self.pendingChanges;
}

- (NSSet<NSString *> *)prunedTargetBundleIdentifiersWithError:(NSError **)error {
    (void)error;
    return self.prunedBundleIdentifiers ?: [NSSet set];
}

- (BOOL)setPendingChanges:(BOOL)pendingChanges
    prunedTargetBundleIdentifiers:(NSSet<NSString *> *)prunedTargetBundleIdentifiers
                    error:(NSError **)error {
    (void)error;
    self.pendingChanges = pendingChanges;
    self.prunedBundleIdentifiers = prunedTargetBundleIdentifiers;
    return YES;
}

@end


@interface PXTestTargetIdentityStore : NSObject <PXTargetSelectionIdentityStoring>
@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, id> *> *appIdentities;
@end

@implementation PXTestTargetIdentityStore

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)activeApplicationIdentityPropertyListsWithError:(NSError **)error {
    (void)error;
    return self.appIdentities;
}

- (BOOL)replaceActiveApplicationIdentityPropertyLists:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)appIdentities
                                                 error:(NSError **)error {
    (void)error;
    self.appIdentities = appIdentities;
    return YES;
}

@end


static NSString *CreateScopePath(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    return [directory stringByAppendingPathComponent:@"global_scope.plist"];
}

static NSDictionary<NSString *, id> *ScopeEntry(NSString *bundleIdentifier) {
    return @{
        @"bundleID": bundleIdentifier,
        @"enabled": @YES,
        @"installed": @YES
    };
}


static PXTestLaunchServicesProxy *CreateInstalledApplicationProxy(NSString *bundleIdentifier,
                                                                  NSString *displayName) {
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *bundleURL = [[NSURL fileURLWithPath:directory]
        URLByAppendingPathComponent:@"Fixture.app"
        isDirectory:YES];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    assert([fileManager createDirectoryAtURL:bundleURL
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:nil]);
    NSString *executableName = @"Fixture";
    NSString *executablePath = [bundleURL.path stringByAppendingPathComponent:executableName];
    assert([[@"fixture" dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:executablePath
             options:NSDataWritingAtomic
               error:nil]);
    assert([fileManager setAttributes:@{NSFilePosixPermissions: @0755}
                            ofItemAtPath:executablePath
                                   error:nil]);

    PXTestLaunchServicesProxy *proxy = [[PXTestLaunchServicesProxy alloc] init];
    proxy.applicationIdentifier = bundleIdentifier;
    proxy.localizedName = displayName;
    proxy.bundleExecutable = executableName;
    proxy.bundleURL = bundleURL;
    proxy.installed = YES;
    return proxy;
}

static void testAnonymousLaunchServicesEntriesDoNotInvalidateTrustedSnapshot(void) {
    PXTestLaunchServicesProxy *first = CreateInstalledApplicationProxy(@"com.example.first", @"First");
    PXTestLaunchServicesProxy *second = CreateInstalledApplicationProxy(@"com.example.second", @"Second");
    PXTestLaunchServicesProxy *anonymous = [[PXTestLaunchServicesProxy alloc] init];
    anonymous.installed = YES;
    PXTestLaunchServicesProxy *malformed = [[PXTestLaunchServicesProxy alloc] init];
    malformed.applicationIdentifier = @"com.example/bad";
    malformed.installed = YES;
    [PXTestLaunchServicesWorkspace setInstalledApplicationsForTesting:@[
        first,
        anonymous,
        malformed,
        second
    ]];
    [PXTestLaunchServicesProxy setSelectedApplicationProxiesForTesting:@{}];

    NSSet<NSString *> *historicalSelection = [NSSet setWithArray:@[
        first.applicationIdentifier,
        second.applicationIdentifier
    ]];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    stateStore.selectedBundleIdentifiers = historicalSelection;
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:[[PXTestLaunchServicesSnapshotProvider alloc] init]
        stateStore:stateStore];

    NSError *error = nil;
    PXTargetSelectionReconciliationResult *result = [reconciler reconcileWithError:&error];

    assert(![error.localizedDescription
        isEqualToString:@"LaunchServices returned an installed app without a Bundle ID"]);
    assert(result != nil);
    assert(error == nil);
    assert(result.snapshot.isTrusted);
    assert([result.snapshot.installedUserBundleIdentifiers isEqualToSet:historicalSelection]);
    NSArray<NSDictionary<NSString *, id> *> *eligible =
        PXEligibleTargetAppCandidates(result.snapshot.applicationCandidates);
    assert(eligible.count == 2);
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:historicalSelection]);

    NSFileManager *fileManager = [NSFileManager defaultManager];
    assert([fileManager removeItemAtURL:first.bundleURL.URLByDeletingLastPathComponent error:nil]);
    assert([fileManager removeItemAtURL:second.bundleURL.URLByDeletingLastPathComponent error:nil]);
}


static void testMissingSelectedTargetIsVerifiedButDurableSelectionIsPreserved(void) {
    PXTestLaunchServicesProxy *installed =
        CreateInstalledApplicationProxy(@"com.example.installed", @"Installed");
    [PXTestLaunchServicesWorkspace setInstalledApplicationsForTesting:@[installed]];
    [PXTestLaunchServicesProxy setSelectedApplicationProxiesForTesting:@{}];

    NSString *missingBundleIdentifier = @"com.example.missing";
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    stateStore.selectedBundleIdentifiers = [NSSet setWithObjects:
        installed.applicationIdentifier,
        missingBundleIdentifier,
        nil];
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:[[PXTestLaunchServicesSnapshotProvider alloc] init]
        stateStore:stateStore];

    NSError *error = nil;
    PXTargetSelectionReconciliationResult *result = [reconciler reconcileWithError:&error];

    assert(result != nil);
    assert(error == nil);
    assert([result.selectedBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:installed.applicationIdentifier]]);
    assert([result.unavailableBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:missingBundleIdentifier]]);
    assert(result.prunedBundleIdentifiers.count == 0);
    NSSet<NSString *> *expectedDurableSelection = [NSSet setWithObjects:
        installed.applicationIdentifier,
        missingBundleIdentifier,
        nil];
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:expectedDurableSelection]);
    assert([[PXTestLaunchServicesProxy lastVerifiedBundleIdentifierForTesting]
        isEqualToString:missingBundleIdentifier]);
    assert([[NSFileManager defaultManager]
        removeItemAtURL:installed.bundleURL.URLByDeletingLastPathComponent
                  error:nil]);
}

static void testUncertainSelectedTargetVerificationFailsClosed(void) {
    PXTestLaunchServicesProxy *installed =
        CreateInstalledApplicationProxy(@"com.example.installed", @"Installed");
    [PXTestLaunchServicesWorkspace setInstalledApplicationsForTesting:@[installed]];
    NSString *uncertainBundleIdentifier = @"com.example.uncertain";
    NSSet<NSString *> *historicalSelection = [NSSet setWithObjects:
        installed.applicationIdentifier,
        uncertainBundleIdentifier,
        nil];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    stateStore.selectedBundleIdentifiers = historicalSelection;
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:[[PXTestLaunchServicesSnapshotProvider alloc] init]
        stateStore:stateStore];

    PXTestLaunchServicesProxy *ambiguous = [[PXTestLaunchServicesProxy alloc] init];
    ambiguous.installed = YES;
    [PXTestLaunchServicesProxy setSelectedApplicationProxiesForTesting:@{
        uncertainBundleIdentifier: ambiguous
    }];
    NSError *error = nil;
    assert([reconciler reconcileWithError:&error] == nil);
    assert(error.code == PXTargetSelectionReconciliationErrorSnapshotUntrusted);
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:historicalSelection]);
    assert([[PXTestLaunchServicesProxy lastVerifiedBundleIdentifierForTesting]
        isEqualToString:uncertainBundleIdentifier]);

    [PXTestLaunchServicesProxy setSelectedApplicationProxiesForTesting:@{
        uncertainBundleIdentifier: [[PXTestPartialLaunchServicesProxy alloc] init]
    }];
    error = nil;
    assert([reconciler reconcileWithError:&error] == nil);
    assert(error.code == PXTargetSelectionReconciliationErrorSnapshotUntrusted);
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:historicalSelection]);
    assert([[NSFileManager defaultManager]
        removeItemAtURL:installed.bundleURL.URLByDeletingLastPathComponent
                  error:nil]);
}

static void testEmptyAndWhollyUnusableEnumerationsFailClosed(void) {
    NSString *historicalBundleIdentifier = @"com.example.historical";
    NSSet<NSString *> *historicalSelection =
        [NSSet setWithObject:historicalBundleIdentifier];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    stateStore.selectedBundleIdentifiers = historicalSelection;
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:[[PXTestLaunchServicesSnapshotProvider alloc] init]
        stateStore:stateStore];
    [PXTestLaunchServicesProxy setSelectedApplicationProxiesForTesting:@{}];

    [PXTestLaunchServicesWorkspace setInstalledApplicationsForTesting:@[]];
    NSError *error = nil;
    assert([reconciler reconcileWithError:&error] == nil);
    assert(error.code == PXTargetSelectionReconciliationErrorSnapshotUntrusted);
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:historicalSelection]);

    PXTestLaunchServicesProxy *anonymous = [[PXTestLaunchServicesProxy alloc] init];
    anonymous.installed = YES;
    PXTestLaunchServicesProxy *malformed = [[PXTestLaunchServicesProxy alloc] init];
    malformed.applicationIdentifier = @"not a.bundle";
    malformed.installed = YES;
    [PXTestLaunchServicesWorkspace setInstalledApplicationsForTesting:@[
        anonymous,
        malformed
    ]];
    error = nil;
    assert([reconciler reconcileWithError:&error] == nil);
    assert(error.code == PXTargetSelectionReconciliationErrorSnapshotUntrusted);
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:historicalSelection]);
    assert([PXTestLaunchServicesProxy lastVerifiedBundleIdentifierForTesting] == nil);
}


static void testTrustedSnapshotTemporarilyExcludesAbsentUserTarget(void) {
    PXTestInstalledAppSnapshotProvider *provider = [[PXTestInstalledAppSnapshotProvider alloc] init];
    provider.snapshot = [PXInstalledAppSnapshot
        trustedSnapshotWithInstalledUserBundleIdentifiers:[NSSet setWithObject:@"com.example.installed"]
        applicationCandidates:@[]];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    stateStore.selectedBundleIdentifiers = [NSSet setWithArray:@[
        @"com.example.installed",
        @"com.example.deleted"
    ]];
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:provider
        stateStore:stateStore];

    NSError *error = nil;
    PXTargetSelectionReconciliationResult *result = [reconciler reconcileWithError:&error];

    assert(result != nil);
    assert(error == nil);
    assert([result.selectedBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.installed"]]);
    assert([result.unavailableBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.deleted"]]);
    assert(result.prunedBundleIdentifiers.count == 0);
    NSSet<NSString *> *expectedDurableSelection = [NSSet setWithArray:@[
        @"com.example.installed",
        @"com.example.deleted"
    ]];
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:expectedDurableSelection]);
    NSSet<NSString *> *expectedRequestedBundleIdentifiers = [NSSet setWithArray:@[
        @"com.example.installed",
        @"com.example.deleted"
    ]];
    assert([provider.requestedBundleIdentifiers isEqualToSet:expectedRequestedBundleIdentifiers]);
}

static void testUntrustedSnapshotFailsClosedAndPreservesSelection(void) {
    PXTestInstalledAppSnapshotProvider *provider = [[PXTestInstalledAppSnapshotProvider alloc] init];
    provider.snapshot = [PXInstalledAppSnapshot
        untrustedSnapshotWithApplicationCandidates:@[]
        reason:@"LaunchServices returned a partial result"];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    NSSet<NSString *> *historicalSelection = [NSSet setWithObject:@"com.example.historical"];
    stateStore.selectedBundleIdentifiers = historicalSelection;
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:provider
        stateStore:stateStore];

    NSError *error = nil;
    PXTargetSelectionReconciliationResult *result = [reconciler reconcileWithError:&error];

    assert(result == nil);
    assert([error.domain isEqualToString:PXTargetSelectionReconciliationErrorDomain]);
    assert(error.code == PXTargetSelectionReconciliationErrorSnapshotUntrusted);
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:historicalSelection]);
}

static void testUnavailableSnapshotFailsClosedAndPreservesSelection(void) {
    PXTestInstalledAppSnapshotProvider *provider = [[PXTestInstalledAppSnapshotProvider alloc] init];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    NSSet<NSString *> *historicalSelection = [NSSet setWithObject:@"com.example.historical"];
    stateStore.selectedBundleIdentifiers = historicalSelection;
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:provider
        stateStore:stateStore];

    NSError *error = nil;
    assert([reconciler reconcileWithError:&error] == nil);
    assert(error.code == PXTargetSelectionReconciliationErrorSnapshotUnavailable);
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:historicalSelection]);
}

static void testTrustedEmptyUserSnapshotPreservesProtectedTarget(void) {
    PXTestInstalledAppSnapshotProvider *provider = [[PXTestInstalledAppSnapshotProvider alloc] init];
    provider.snapshot = [PXInstalledAppSnapshot
        trustedSnapshotWithInstalledUserBundleIdentifiers:[NSSet set]
        applicationCandidates:@[]];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    stateStore.selectedBundleIdentifiers = [NSSet setWithArray:@[
        @"com.apple.mobilesafari",
        @"com.example.deleted"
    ]];
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:provider
        stateStore:stateStore];

    PXTargetSelectionReconciliationResult *result = [reconciler reconcileWithError:nil];

    assert([result.selectedBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.apple.mobilesafari"]]);
    assert([result.unavailableBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.deleted"]]);
    assert(result.prunedBundleIdentifiers.count == 0);
    NSSet<NSString *> *expectedDurableSelection = [NSSet setWithArray:@[
        @"com.apple.mobilesafari",
        @"com.example.deleted"
    ]];
    assert([stateStore.selectedBundleIdentifiers isEqualToSet:expectedDurableSelection]);
}

static void testScopeWriteFailureRollsBackPolicyAndIdentityState(void) {
    NSString *scopePath = CreateScopePath();
    NSDictionary<NSString *, id> *scope = @{
        @"ScopedApps": @{
            @"com.example.installed": ScopeEntry(@"com.example.installed"),
            @"com.example.deleted": ScopeEntry(@"com.example.deleted")
        }
    };
    assert([scope writeToFile:scopePath atomically:YES]);
    PXTestTargetSelectionPolicyStore *policyStore = [[PXTestTargetSelectionPolicyStore alloc] init];
    policyStore.pendingChanges = NO;
    PXTestTargetIdentityStore *identityStore = [[PXTestTargetIdentityStore alloc] init];
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *originalIdentities = @{
        @"com.example.installed": @{@"installIdentifier": @"installed-id"},
        @"com.example.deleted": @{@"installIdentifier": @"deleted-id"}
    };
    identityStore.appIdentities = originalIdentities;
    __block NSUInteger notificationCount = 0;
    PXAtomicTargetSelectionStateStore *stateStore = [[PXAtomicTargetSelectionStateStore alloc]
        initWithScopeFilePath:scopePath
        policyStore:policyStore
        identityStore:identityStore
        cacheInvalidator:^{}
        notificationPublisher:^(NSString *notificationName) {
            (void)notificationName;
            notificationCount += 1;
        }];
    stateStore.failBeforeScopeCommitForTesting = YES;

    NSError *error = nil;
    assert(![stateStore pruneTargetBundleIdentifiers:
        [NSSet setWithObject:@"com.example.deleted"] error:&error]);

    assert(error != nil);
    assert(!policyStore.pendingChanges);
    assert(policyStore.prunedBundleIdentifiers.count == 0);
    assert([identityStore.appIdentities isEqualToDictionary:originalIdentities]);
    assert([[NSDictionary dictionaryWithContentsOfFile:scopePath] isEqualToDictionary:scope]);
    assert(notificationCount == 0);
    [[NSFileManager defaultManager] removeItemAtPath:scopePath.stringByDeletingLastPathComponent
                                               error:nil];
}

static void testSuccessfulCommitInvalidatesCachesBeforeOrderedNotifications(void) {
    NSString *scopePath = CreateScopePath();
    NSDictionary<NSString *, id> *scope = @{
        @"ScopedApps": @{
            @"com.example.installed": ScopeEntry(@"com.example.installed"),
            @"com.example.deleted": ScopeEntry(@"com.example.deleted")
        }
    };
    assert([scope writeToFile:scopePath atomically:YES]);
    PXTestTargetSelectionPolicyStore *policyStore = [[PXTestTargetSelectionPolicyStore alloc] init];
    PXTestTargetIdentityStore *identityStore = [[PXTestTargetIdentityStore alloc] init];
    identityStore.appIdentities = @{
        @"com.example.installed": @{@"installIdentifier": @"installed-id"},
        @"com.example.deleted": @{@"installIdentifier": @"deleted-id"}
    };
    NSMutableArray<NSString *> *events = [NSMutableArray array];
    void (^assertCommittedState)(void) = ^{
        NSDictionary<NSString *, id> *persisted =
            [NSDictionary dictionaryWithContentsOfFile:scopePath];
        assert(persisted[@"ScopedApps"][@"com.example.deleted"] == nil);
        assert(policyStore.pendingChanges);
        assert([policyStore.prunedBundleIdentifiers containsObject:@"com.example.deleted"]);
        assert(identityStore.appIdentities[@"com.example.deleted"] == nil);
    };
    PXAtomicTargetSelectionStateStore *stateStore = [[PXAtomicTargetSelectionStateStore alloc]
        initWithScopeFilePath:scopePath
        policyStore:policyStore
        identityStore:identityStore
        cacheInvalidator:^{
            assertCommittedState();
            [events addObject:@"cache"];
        }
        notificationPublisher:^(NSString *notificationName) {
            assertCommittedState();
            [events addObject:notificationName];
        }];

    assert([stateStore pruneTargetBundleIdentifiers:
        [NSSet setWithObject:@"com.example.deleted"] error:nil]);

    NSArray<NSString *> *expectedEvents = @[
        @"cache",
        PXTargetSelectionAppIdentityChangedNotification,
        PXTargetSelectionScopeChangedNotification
    ];
    assert([events isEqualToArray:expectedEvents]);
    [[NSFileManager defaultManager] removeItemAtPath:scopePath.stringByDeletingLastPathComponent
                                               error:nil];
}

static void testReinstalledBundleAutomaticallyReturnsToEffectiveSelection(void) {
    PXTestInstalledAppSnapshotProvider *provider = [[PXTestInstalledAppSnapshotProvider alloc] init];
    provider.snapshot = [PXInstalledAppSnapshot
        trustedSnapshotWithInstalledUserBundleIdentifiers:[NSSet set]
        applicationCandidates:@[]];
    PXTestTargetSelectionStateStore *stateStore = [[PXTestTargetSelectionStateStore alloc] init];
    stateStore.selectedBundleIdentifiers = [NSSet setWithObject:@"com.example.reinstalled"];
    PXTargetSelectionReconciler *reconciler = [[PXTargetSelectionReconciler alloc]
        initWithSnapshotProvider:provider
        stateStore:stateStore];
    PXTargetSelectionReconciliationResult *whileUninstalled =
        [reconciler reconcileWithError:nil];
    assert(whileUninstalled != nil);
    assert(whileUninstalled.selectedBundleIdentifiers.count == 0);
    assert([whileUninstalled.unavailableBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.reinstalled"]]);
    assert([stateStore.selectedBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.reinstalled"]]);

    provider.snapshot = [PXInstalledAppSnapshot
        trustedSnapshotWithInstalledUserBundleIdentifiers:
            [NSSet setWithObject:@"com.example.reinstalled"]
        applicationCandidates:@[]];
    PXTargetSelectionReconciliationResult *afterReinstall =
        [reconciler reconcileWithError:nil];

    assert([afterReinstall.selectedBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.reinstalled"]]);
    assert(afterReinstall.unavailableBundleIdentifiers.count == 0);
    assert(afterReinstall.prunedBundleIdentifiers.count == 0);
    assert([stateStore.selectedBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.reinstalled"]]);
}

int main(void) {
    @autoreleasepool {
        testAnonymousLaunchServicesEntriesDoNotInvalidateTrustedSnapshot();
        testMissingSelectedTargetIsVerifiedButDurableSelectionIsPreserved();
        testUncertainSelectedTargetVerificationFailsClosed();
        testEmptyAndWhollyUnusableEnumerationsFailClosed();
        testTrustedSnapshotTemporarilyExcludesAbsentUserTarget();
        testUntrustedSnapshotFailsClosedAndPreservesSelection();
        testUnavailableSnapshotFailsClosedAndPreservesSelection();
        testTrustedEmptyUserSnapshotPreservesProtectedTarget();
        testScopeWriteFailureRollsBackPolicyAndIdentityState();
        testSuccessfulCommitInvalidatesCachesBeforeOrderedNotifications();
        testReinstalledBundleAutomaticallyReturnsToEffectiveSelection();
    }
    return 0;
}
