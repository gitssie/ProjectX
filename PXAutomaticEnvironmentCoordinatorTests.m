#import <Foundation/Foundation.h>
#import <assert.h>

#import "PXAutomaticEnvironmentCoordinator.h"
#import "PXTargetSelectionReconciler.h"

@interface PXRecordingTargetSelectionReconciler : NSObject <PXTargetSelectionReconciling>
@property (nonatomic, copy) NSSet<NSString *> *selectedBundleIdentifiers;
@property (nonatomic, copy) NSSet<NSString *> *prunedBundleIdentifiers;
@property (nonatomic, strong) NSError *errorToReturn;
@end

@implementation PXRecordingTargetSelectionReconciler

- (PXTargetSelectionReconciliationResult *)reconcileWithError:(NSError **)error {
    if (self.errorToReturn) {
        if (error) *error = self.errorToReturn;
        return nil;
    }
    return [PXTargetSelectionReconciliationResult
        resultWithSelectedBundleIdentifiers:self.selectedBundleIdentifiers
        prunedBundleIdentifiers:self.prunedBundleIdentifiers];
}

@end

@interface PXRecordingEnvironmentOperations : NSObject <PXAutomaticEnvironmentOperations>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, copy) NSSet<NSString *> *targetBundleIdentifiers;
@property (nonatomic, copy) NSSet<NSString *> *keychainCleanupFailures;
@property (nonatomic, copy) NSSet<NSString *> *cleanupFailures;
@property (nonatomic, assign) BOOL activationSucceeds;
@property (nonatomic, assign) BOOL pasteboardCleanupSucceeds;
@property (nonatomic, assign) BOOL safariCleanupSucceeds;
@property (nonatomic, assign) BOOL holdsTargetCleanup;
@property (nonatomic, assign) BOOL candidateActivationCommitted;
@property (nonatomic, copy) void (^pendingTargetCleanup)(void);
@property (nonatomic, strong) dispatch_semaphore_t cleanupStarted;
@end

@implementation PXRecordingEnvironmentOperations

- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
        _keychainCleanupFailures = [NSSet set];
        _cleanupFailures = [NSSet set];
        _activationSucceeds = YES;
        _pasteboardCleanupSucceeds = YES;
        _safariCleanupSucceeds = YES;
        _cleanupStarted = dispatch_semaphore_create(0);
    }
    return self;
}

- (BOOL)terminateTargetBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    (void)error;
    assert(self.candidateActivationCommitted);
    [self.events addObject:[@"terminate:" stringByAppendingString:bundleIdentifier]];
    return YES;
}

- (void)clearKeychainForTargetBundleIdentifier:(NSString *)bundleIdentifier
                                     completion:(void (^)(BOOL success, NSError *error))completion {
    assert(self.candidateActivationCommitted);
    [self.events addObject:[@"clear-keychain:" stringByAppendingString:bundleIdentifier]];
    BOOL success = ![self.keychainCleanupFailures containsObject:bundleIdentifier];
    NSError *error = success ? nil : [NSError errorWithDomain:@"test-keychain" code:5 userInfo:@{
        NSLocalizedDescriptionKey: @"target Keychain cleanup failed"
    }];
    completion(success, error);
}

- (void)clearTargetBundleIdentifier:(NSString *)bundleIdentifier
                         completion:(void (^)(BOOL success, NSError *error))completion {
    assert(self.candidateActivationCommitted);
    [self.events addObject:[@"clear:" stringByAppendingString:bundleIdentifier]];
    BOOL success = ![self.cleanupFailures containsObject:bundleIdentifier];
    NSError *error = success ? nil : [NSError errorWithDomain:@"test" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"target cleanup failed"
    }];
    if (self.holdsTargetCleanup) {
        self.pendingTargetCleanup = ^{
            completion(success, error);
        };
        dispatch_semaphore_signal(self.cleanupStarted);
        return;
    }
    completion(success, error);
}

- (BOOL)clearPasteboardWithError:(NSError **)error {
    assert(self.candidateActivationCommitted);
    [self.events addObject:@"clear:pasteboard"];
    if (!self.pasteboardCleanupSucceeds && error) {
        *error = [NSError errorWithDomain:@"test" code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"pasteboard cleanup failed"
        }];
    }
    return self.pasteboardCleanupSucceeds;
}

- (BOOL)clearSafariWithError:(NSError **)error {
    assert(self.candidateActivationCommitted);
    [self.events addObject:@"clear:safari"];
    if (!self.safariCleanupSucceeds && error) {
        *error = [NSError errorWithDomain:@"test" code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"web cleanup failed"
        }];
    }
    return self.safariCleanupSucceeds;
}

- (BOOL)generateAndActivateEnvironmentWithError:(NSError **)error {
    [self.events addObject:@"activate"];
    if (!self.activationSucceeds && error) {
        *error = [NSError errorWithDomain:@"test" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"activation failed"
        }];
    }
    self.candidateActivationCommitted = self.activationSucceeds;
    return self.activationSucceeds;
}

@end

static PXAutomaticEnvironmentResult *runCoordinator(PXAutomaticEnvironmentCoordinator *coordinator,
                                                     NSSet<NSString *> *targets) {
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block PXAutomaticEnvironmentResult *capturedResult = nil;
    [coordinator runWithTargetBundleIdentifiers:targets completion:^(PXAutomaticEnvironmentResult *result) {
        capturedResult = result;
        dispatch_semaphore_signal(completed);
    }];
    assert(dispatch_semaphore_wait(completed,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    return capturedResult;
}

static void testSuccessfulRunUsesOneOrderedAutomaticEnvironmentFlow(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithArray:@[@"com.example.alpha", @"com.example.beta"]]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomeSuccess);
    assert(result.failures.count == 0);
    assert([[result displayMessage] isEqualToString:@"Environment ready for selected apps."]);
    NSArray<NSString *> *expectedEvents = @[
        @"activate",
        @"terminate:com.example.alpha",
        @"clear-keychain:com.example.alpha",
        @"clear:com.example.alpha",
        @"terminate:com.example.beta",
        @"clear-keychain:com.example.beta",
        @"clear:com.example.beta",
        @"clear:pasteboard",
        @"clear:safari"
    ];
    assert([operations.events isEqualToArray:expectedEvents]);
}

static void testNoTargetsReturnsWithoutRunningDestructiveOperations(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-empty-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(coordinator, [NSSet set]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomeNoTargets);
    assert(operations.events.count == 0);
}

static void testTrustedReconciliationRemovesDeletedTargetBeforeGeneration(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    PXRecordingTargetSelectionReconciler *reconciler =
        [[PXRecordingTargetSelectionReconciler alloc] init];
    reconciler.selectedBundleIdentifiers = [NSSet setWithObject:@"com.example.installed"];
    reconciler.prunedBundleIdentifiers = [NSSet setWithObject:@"com.example.deleted"];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        targetSelectionReconciler:reconciler
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-reconciliation-tests",
                                        DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithArray:@[@"com.example.installed", @"com.example.deleted"]]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomeSuccess);
    assert([operations.targetBundleIdentifiers
        isEqualToSet:[NSSet setWithObject:@"com.example.installed"]]);
    assert([operations.events containsObject:@"terminate:com.example.installed"]);
    assert(![operations.events containsObject:@"terminate:com.example.deleted"]);
}

static void testOnlyDeletedTargetReturnsNoTargetsBeforeActivation(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    PXRecordingTargetSelectionReconciler *reconciler =
        [[PXRecordingTargetSelectionReconciler alloc] init];
    reconciler.selectedBundleIdentifiers = [NSSet set];
    reconciler.prunedBundleIdentifiers = [NSSet setWithObject:@"com.example.deleted"];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        targetSelectionReconciler:reconciler
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-only-stale-tests",
                                        DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithObject:@"com.example.deleted"]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomeNoTargets);
    assert(operations.events.count == 0);
}

static void testEnumerationFailurePreservesTargetsAndSkipsAllOperations(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    PXRecordingTargetSelectionReconciler *reconciler =
        [[PXRecordingTargetSelectionReconciler alloc] init];
    reconciler.errorToReturn = [NSError
        errorWithDomain:PXTargetSelectionReconciliationErrorDomain
        code:PXTargetSelectionReconciliationErrorSnapshotUnavailable
        userInfo:@{NSLocalizedDescriptionKey: @"LaunchServices is unavailable"}];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        targetSelectionReconciler:reconciler
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-enumeration-failure-tests",
                                        DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithObject:@"com.example.historical"]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomeFailure);
    assert(result.failures.count == 1);
    assert([result.failures.firstObject.action isEqualToString:@"Installed Target enumeration"]);
    assert(operations.events.count == 0);
    assert(operations.targetBundleIdentifiers == nil);
}

static void testActivationFailureNeverReportsSuccessOrRelaunchesTargets(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    operations.activationSucceeds = NO;
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-activation-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithObject:@"com.example.target"]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomeFailure);
    assert(result.failures.count == 1);
    assert([result.failures.firstObject.action isEqualToString:@"Environment activation"]);
    assert([result.failures.firstObject.errorDomain isEqualToString:@"test"]);
    assert(result.failures.firstObject.errorCode == 2);
    assert([operations.events isEqualToArray:@[@"activate"]]);
    assert(![operations.events containsObject:@"clear:com.example.target"]);
}

static void testTargetCleanupFailureProducesConcretePartialFailureAfterActivation(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    operations.cleanupFailures = [NSSet setWithObject:@"com.example.beta"];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-partial-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithArray:@[@"com.example.alpha", @"com.example.beta"]]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomePartialFailure);
    assert(result.failures.count == 1);
    assert(![[result displayMessage] isEqualToString:@"Environment ready for selected apps."]);
    PXAutomaticEnvironmentFailure *failure = result.failures.firstObject;
    assert([failure.bundleIdentifier isEqualToString:@"com.example.beta"]);
    assert([failure.action isEqualToString:@"Target data cleanup"]);
    assert([failure.message isEqualToString:@"target cleanup failed"]);
    assert([failure.errorDomain isEqualToString:@"test"]);
    assert(failure.errorCode == 1);
    NSArray<NSString *> *expectedEvents = @[
        @"activate",
        @"terminate:com.example.alpha",
        @"clear-keychain:com.example.alpha",
        @"clear:com.example.alpha",
        @"terminate:com.example.beta",
        @"clear-keychain:com.example.beta",
        @"clear:com.example.beta",
        @"clear:pasteboard",
        @"clear:safari"
    ];
    assert([operations.events isEqualToArray:expectedEvents]);
}

static void testKeychainCleanupFailureIsTargetScopedAndSkipsTargetDataCleanup(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    operations.keychainCleanupFailures = [NSSet setWithObject:@"com.example.alpha"];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-keychain-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithArray:@[@"com.example.alpha", @"com.example.beta"]]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomePartialFailure);
    assert(result.failures.count == 1);
    PXAutomaticEnvironmentFailure *failure = result.failures.firstObject;
    assert([failure.bundleIdentifier isEqualToString:@"com.example.alpha"]);
    assert([failure.action isEqualToString:@"Target Keychain cleanup"]);
    assert([failure.message isEqualToString:@"target Keychain cleanup failed"]);
    assert([failure.errorDomain isEqualToString:@"test-keychain"]);
    assert(failure.errorCode == 5);
    NSArray<NSString *> *expectedEvents = @[
        @"activate",
        @"terminate:com.example.alpha",
        @"clear-keychain:com.example.alpha",
        @"terminate:com.example.beta",
        @"clear-keychain:com.example.beta",
        @"clear:com.example.beta",
        @"clear:pasteboard",
        @"clear:safari"
    ];
    assert([operations.events isEqualToArray:expectedEvents]);
}

static void testAncillaryCleanupFailuresProducePartialFailureAfterActivation(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    operations.pasteboardCleanupSucceeds = NO;
    operations.safariCleanupSucceeds = NO;
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-ancillary-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithObject:@"com.example.target"]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomePartialFailure);
    assert(result.failures.count == 2);
    assert([result.failures[0].action isEqualToString:@"Pasteboard cleanup"]);
    assert([result.failures[1].action isEqualToString:@"Web data cleanup"]);
    assert([operations.events containsObject:@"activate"]);
    assert([operations.events.lastObject isEqualToString:@"clear:safari"]);
}

static void testConcurrentRunIsRejectedWithoutDuplicatingOperations(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    operations.holdsTargetCleanup = YES;
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-concurrency-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];
    dispatch_semaphore_t firstCompleted = dispatch_semaphore_create(0);
    dispatch_semaphore_t secondCompleted = dispatch_semaphore_create(0);
    __block PXAutomaticEnvironmentResult *secondResult = nil;

    [coordinator runWithTargetBundleIdentifiers:[NSSet setWithObject:@"com.example.target"]
                                      completion:^(PXAutomaticEnvironmentResult *result) {
        assert(result.outcome == PXAutomaticEnvironmentOutcomeSuccess);
        dispatch_semaphore_signal(firstCompleted);
    }];
    assert(dispatch_semaphore_wait(operations.cleanupStarted,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    [coordinator runWithTargetBundleIdentifiers:[NSSet setWithObject:@"com.example.target"]
                                      completion:^(PXAutomaticEnvironmentResult *result) {
        secondResult = result;
        dispatch_semaphore_signal(secondCompleted);
    }];

    assert(dispatch_semaphore_wait(secondCompleted,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(secondResult.outcome == PXAutomaticEnvironmentOutcomeBusy);
    NSPredicate *terminationPredicate = [NSPredicate predicateWithFormat:@"SELF == %@",
                                                                      @"terminate:com.example.target"];
    NSUInteger terminationCount = [operations.events
        filteredArrayUsingPredicate:terminationPredicate].count;
    assert(terminationCount == 1);

    operations.pendingTargetCleanup();
    assert(dispatch_semaphore_wait(firstCompleted,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
}

static void testIneligibleTargetsAreRejectedBeforeDestructiveOperations(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-validation-tests", DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithArray:@[@"com.apple.Preferences", @"com.example.target"]]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomePartialFailure);
    assert(result.failures.count == 1);
    assert([result.failures.firstObject.bundleIdentifier isEqualToString:@"com.apple.Preferences"]);
    assert([result.failures.firstObject.action isEqualToString:@"Target validation"]);
    assert(![operations.events containsObject:@"terminate:com.apple.Preferences"]);
    assert([operations.events containsObject:@"terminate:com.example.target"]);
}

static void testMalformedBundleIdentifierIsRejectedBeforeDestructiveOperations(void) {
    PXRecordingEnvironmentOperations *operations = [[PXRecordingEnvironmentOperations alloc] init];
    PXAutomaticEnvironmentCoordinator *coordinator = [[PXAutomaticEnvironmentCoordinator alloc]
        initWithOperations:operations
        workQueue:dispatch_queue_create("com.hydra.projectx.environment-bundle-validation-tests",
                                        DISPATCH_QUEUE_SERIAL)
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];

    PXAutomaticEnvironmentResult *result = runCoordinator(
        coordinator,
        [NSSet setWithArray:@[@"not a bundle/id", @"com.example.target"]]);

    assert(result.outcome == PXAutomaticEnvironmentOutcomePartialFailure);
    assert(result.failures.count == 1);
    assert([result.failures.firstObject.bundleIdentifier isEqualToString:@"not a bundle/id"]);
    assert(![operations.events containsObject:@"terminate:not a bundle/id"]);
    assert([operations.events containsObject:@"terminate:com.example.target"]);
}

int main(void) {
    @autoreleasepool {
        testSuccessfulRunUsesOneOrderedAutomaticEnvironmentFlow();
        testNoTargetsReturnsWithoutRunningDestructiveOperations();
        testTrustedReconciliationRemovesDeletedTargetBeforeGeneration();
        testOnlyDeletedTargetReturnsNoTargetsBeforeActivation();
        testEnumerationFailurePreservesTargetsAndSkipsAllOperations();
        testActivationFailureNeverReportsSuccessOrRelaunchesTargets();
        testTargetCleanupFailureProducesConcretePartialFailureAfterActivation();
        testKeychainCleanupFailureIsTargetScopedAndSkipsTargetDataCleanup();
        testAncillaryCleanupFailuresProducePartialFailureAfterActivation();
        testConcurrentRunIsRejectedWithoutDuplicatingOperations();
        testIneligibleTargetsAreRejectedBeforeDestructiveOperations();
        testMalformedBundleIdentifierIsRejectedBeforeDestructiveOperations();
    }
    return 0;
}
