#import "PXAutomaticEnvironmentCoordinator.h"

#import "AppIdentity.h"
#import "PXTargetAppEligibility.h"

@interface PXAutomaticEnvironmentFailure ()
@property (nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property (nonatomic, copy, readwrite) NSString *action;
@property (nonatomic, copy, readwrite) NSString *message;
@property (nonatomic, copy, readwrite) NSString *errorDomain;
@property (nonatomic, assign, readwrite) NSInteger errorCode;
@end


@implementation PXAutomaticEnvironmentFailure

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                   action:(NSString *)action
                                  message:(NSString *)message {
    return [self initWithBundleIdentifier:bundleIdentifier
                                   action:action
                                  message:message
                              errorDomain:@"com.hydra.projectx.environment"
                                errorCode:0];
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                   action:(NSString *)action
                                  message:(NSString *)message
                              errorDomain:(NSString *)errorDomain
                                errorCode:(NSInteger)errorCode {
    self = [super init];
    if (self) {
        _bundleIdentifier = [bundleIdentifier copy];
        _action = [action copy];
        _message = [message copy];
        _errorDomain = [errorDomain copy];
        _errorCode = errorCode;
    }
    return self;
}

@end

@interface PXAutomaticEnvironmentResult ()
@property (nonatomic, assign, readwrite) PXAutomaticEnvironmentOutcome outcome;
@property (nonatomic, copy, readwrite) NSArray<PXAutomaticEnvironmentFailure *> *failures;
@end

@implementation PXAutomaticEnvironmentResult

- (instancetype)initWithOutcome:(PXAutomaticEnvironmentOutcome)outcome
                        failures:(NSArray<PXAutomaticEnvironmentFailure *> *)failures {
    self = [super init];
    if (self) {
        _outcome = outcome;
        _failures = [failures copy];
    }
    return self;
}

- (NSString *)displayMessage {
    switch (self.outcome) {
        case PXAutomaticEnvironmentOutcomeSuccess:
            return @"Environment ready for selected apps.";
        case PXAutomaticEnvironmentOutcomePartialFailure:
            return @"Environment completed with one or more target failures.";
        case PXAutomaticEnvironmentOutcomeFailure:
            return @"Environment could not be completed.";
        case PXAutomaticEnvironmentOutcomeNoTargets:
            return @"No selected installed apps are currently available.";
        case PXAutomaticEnvironmentOutcomeBusy:
            return @"Environment generation is already running.";
    }
    return @"Environment status is unavailable.";
}

@end

@interface PXAutomaticEnvironmentCoordinator ()
@property (nonatomic, strong) id<PXAutomaticEnvironmentOperations> operations;
@property (nonatomic, strong, nullable) id<PXTargetSelectionReconciling> targetSelectionReconciler;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation PXAutomaticEnvironmentCoordinator

- (instancetype)initWithOperations:(id<PXAutomaticEnvironmentOperations>)operations
                          workQueue:(dispatch_queue_t)workQueue
                    completionQueue:(dispatch_queue_t)completionQueue {
    return [self initWithOperations:operations
          targetSelectionReconciler:nil
                          workQueue:workQueue
                    completionQueue:completionQueue];
}

- (instancetype)initWithOperations:(id<PXAutomaticEnvironmentOperations>)operations
          targetSelectionReconciler:(id<PXTargetSelectionReconciling>)targetSelectionReconciler
                          workQueue:(dispatch_queue_t)workQueue
                    completionQueue:(dispatch_queue_t)completionQueue {
    self = [super init];
    if (self) {
        _operations = operations;
        _targetSelectionReconciler = targetSelectionReconciler;
        _workQueue = workQueue;
        _completionQueue = completionQueue;
    }
    return self;
}

- (void)runWithTargetBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                             completion:(PXAutomaticEnvironmentCompletion)completion {
    NSArray<NSString *> *requestedTargets = [bundleIdentifiers.allObjects
        sortedArrayUsingSelector:@selector(compare:)];
    dispatch_async(self.workQueue, ^{
        if (self.isRunning) {
            PXAutomaticEnvironmentResult *result = [[PXAutomaticEnvironmentResult alloc]
                initWithOutcome:PXAutomaticEnvironmentOutcomeBusy
                failures:@[]];
            dispatch_async(self.completionQueue, ^{
                completion(result);
            });
            return;
        }
        NSArray<NSString *> *effectiveTargets = requestedTargets;
        if (self.targetSelectionReconciler) {
            NSError *reconciliationError = nil;
            PXTargetSelectionReconciliationResult *reconciliation =
                [self.targetSelectionReconciler reconcileWithError:&reconciliationError];
            if (!reconciliation) {
                PXAutomaticEnvironmentFailure *failure = [[PXAutomaticEnvironmentFailure alloc]
                    initWithBundleIdentifier:@""
                    action:@"Installed Target enumeration"
                    message:reconciliationError.localizedDescription ?:
                        @"Installed Target Apps could not be enumerated safely."
                    errorDomain:reconciliationError.domain ?:
                        PXTargetSelectionReconciliationErrorDomain
                    errorCode:reconciliationError.code];
                PXAutomaticEnvironmentResult *result = [[PXAutomaticEnvironmentResult alloc]
                    initWithOutcome:PXAutomaticEnvironmentOutcomeFailure
                    failures:@[failure]];
                dispatch_async(self.completionQueue, ^{
                    completion(result);
                });
                return;
            }
            effectiveTargets = [reconciliation.selectedBundleIdentifiers.allObjects
                sortedArrayUsingSelector:@selector(compare:)];
        }
        self.operations.targetBundleIdentifiers = [NSSet setWithArray:effectiveTargets];
        if (effectiveTargets.count == 0) {
            PXAutomaticEnvironmentResult *result = [[PXAutomaticEnvironmentResult alloc]
                initWithOutcome:PXAutomaticEnvironmentOutcomeNoTargets
                failures:@[]];
            dispatch_async(self.completionQueue, ^{
                completion(result);
            });
            return;
        }
        NSMutableArray<NSString *> *eligibleTargets = [NSMutableArray array];
        NSMutableArray<PXAutomaticEnvironmentFailure *> *failures = [NSMutableArray array];
        for (NSString *bundleIdentifier in effectiveTargets) {
            if (PXTargetBundleIdentifierIsValid(bundleIdentifier) &&
                PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO)) {
                [eligibleTargets addObject:bundleIdentifier];
                continue;
            }
            PXAutomaticEnvironmentFailure *failure = [[PXAutomaticEnvironmentFailure alloc]
                initWithBundleIdentifier:bundleIdentifier ?: @""
                action:@"Target validation"
                message:@"The selected target is not eligible for local environment changes."
                errorDomain:@"com.hydra.projectx.target-validation"
                errorCode:1];
            [failures addObject:failure];
        }
        if (eligibleTargets.count == 0) {
            PXAutomaticEnvironmentResult *result = [[PXAutomaticEnvironmentResult alloc]
                initWithOutcome:PXAutomaticEnvironmentOutcomeFailure
                failures:failures];
            dispatch_async(self.completionQueue, ^{
                completion(result);
            });
            return;
        }
        self.running = YES;
        NSError *activationError = nil;
        if (![self.operations generateAndActivateEnvironmentWithError:&activationError]) {
            PXAutomaticEnvironmentFailure *failure = [[PXAutomaticEnvironmentFailure alloc]
                initWithBundleIdentifier:@""
                action:@"Environment activation"
                message:activationError.localizedDescription ?: @"The new environment could not be activated."
                errorDomain:activationError.domain ?: @"com.hydra.projectx.environment-operations"
                errorCode:activationError.code];
            [failures addObject:failure];
            self.running = NO;
            PXAutomaticEnvironmentResult *result = [[PXAutomaticEnvironmentResult alloc]
                initWithOutcome:PXAutomaticEnvironmentOutcomeFailure
                failures:[failures copy]];
            dispatch_async(self.completionQueue, ^{
                completion(result);
            });
            return;
        }
        [self processTargets:eligibleTargets
                       index:0
                    failures:failures
                  completion:completion];
    });
}

- (void)processTargets:(NSArray<NSString *> *)targets
                  index:(NSUInteger)index
               failures:(NSMutableArray<PXAutomaticEnvironmentFailure *> *)failures
             completion:(PXAutomaticEnvironmentCompletion)completion {
    if (index >= targets.count) {
        [self finishRunWithFailures:failures
                        completion:completion];
        return;
    }

    NSString *bundleIdentifier = targets[index];
    NSError *terminationError = nil;
    if (![self.operations terminateTargetBundleIdentifier:bundleIdentifier error:&terminationError]) {
        PXAutomaticEnvironmentFailure *failure = [[PXAutomaticEnvironmentFailure alloc]
            initWithBundleIdentifier:bundleIdentifier
            action:@"Target termination"
            message:terminationError.localizedDescription ?: @"The target app could not be terminated."
            errorDomain:terminationError.domain ?: @"com.hydra.projectx.environment-operations"
            errorCode:terminationError.code];
        [failures addObject:failure];
        [self processTargets:targets
                       index:index + 1
                    failures:failures
                  completion:completion];
        return;
    }
    [self.operations clearKeychainForTargetBundleIdentifier:bundleIdentifier completion:^(BOOL success,
                                                                                           NSError *error) {
        dispatch_async(self.workQueue, ^{
            if (!success) {
                PXAutomaticEnvironmentFailure *failure = [[PXAutomaticEnvironmentFailure alloc]
                    initWithBundleIdentifier:bundleIdentifier
                    action:@"Target Keychain cleanup"
                    message:error.localizedDescription ?: @"Target Keychain data could not be completely cleared."
                    errorDomain:error.domain ?: @"com.hydra.projectx.environment-operations"
                    errorCode:error.code];
                [failures addObject:failure];
                [self processTargets:targets
                               index:index + 1
                            failures:failures
                          completion:completion];
                return;
            }
            [self.operations clearTargetBundleIdentifier:bundleIdentifier completion:^(BOOL dataSuccess,
                                                                                        NSError *dataError) {
                dispatch_async(self.workQueue, ^{
                    if (!dataSuccess) {
                        PXAutomaticEnvironmentFailure *failure = [[PXAutomaticEnvironmentFailure alloc]
                            initWithBundleIdentifier:bundleIdentifier
                            action:@"Target data cleanup"
                            message:dataError.localizedDescription ?: @"Target data could not be completely cleared."
                            errorDomain:dataError.domain ?: @"com.hydra.projectx.environment-operations"
                            errorCode:dataError.code];
                        [failures addObject:failure];
                    }
                    [self processTargets:targets
                                   index:index + 1
                                failures:failures
                              completion:completion];
                });
            }];
        });
    }];
}

- (void)finishRunWithFailures:(NSMutableArray<PXAutomaticEnvironmentFailure *> *)failures
                    completion:(PXAutomaticEnvironmentCompletion)completion {
    NSError *pasteboardError = nil;
    if (![self.operations clearPasteboardWithError:&pasteboardError]) {
        [failures addObject:[[PXAutomaticEnvironmentFailure alloc]
            initWithBundleIdentifier:@""
            action:@"Pasteboard cleanup"
            message:pasteboardError.localizedDescription ?: @"The pasteboard could not be cleared."
            errorDomain:pasteboardError.domain ?: @"com.hydra.projectx.environment-operations"
            errorCode:pasteboardError.code]];
    }
    NSError *webDataError = nil;
    if (![self.operations clearSafariWithError:&webDataError]) {
        [failures addObject:[[PXAutomaticEnvironmentFailure alloc]
            initWithBundleIdentifier:@"com.apple.mobilesafari"
            action:@"Web data cleanup"
            message:webDataError.localizedDescription ?: @"Browser data could not be cleared."
            errorDomain:webDataError.domain ?: @"com.hydra.projectx.environment-operations"
            errorCode:webDataError.code]];
    }
    self.running = NO;
    PXAutomaticEnvironmentResult *result = [[PXAutomaticEnvironmentResult alloc]
        initWithOutcome:failures.count == 0
            ? PXAutomaticEnvironmentOutcomeSuccess
            : PXAutomaticEnvironmentOutcomePartialFailure
        failures:failures];
    dispatch_async(self.completionQueue, ^{
        completion(result);
    });
}

@end
