#import <Foundation/Foundation.h>

#import "PXTargetSelectionReconciler.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PXAutomaticEnvironmentOutcome) {
    PXAutomaticEnvironmentOutcomeSuccess,
    PXAutomaticEnvironmentOutcomePartialFailure,
    PXAutomaticEnvironmentOutcomeFailure,
    PXAutomaticEnvironmentOutcomeNoTargets,
    PXAutomaticEnvironmentOutcomeBusy
};

@interface PXAutomaticEnvironmentFailure : NSObject

@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@property (nonatomic, copy, readonly) NSString *action;
@property (nonatomic, copy, readonly) NSString *message;
@property (nonatomic, copy, readonly) NSString *errorDomain;
@property (nonatomic, assign, readonly) NSInteger errorCode;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                   action:(NSString *)action
                                  message:(NSString *)message;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                   action:(NSString *)action
                                  message:(NSString *)message
                              errorDomain:(NSString *)errorDomain
                                errorCode:(NSInteger)errorCode NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PXAutomaticEnvironmentResult : NSObject

@property (nonatomic, assign, readonly) PXAutomaticEnvironmentOutcome outcome;
@property (nonatomic, copy, readonly) NSArray<PXAutomaticEnvironmentFailure *> *failures;

- (instancetype)initWithOutcome:(PXAutomaticEnvironmentOutcome)outcome
                        failures:(NSArray<PXAutomaticEnvironmentFailure *> *)failures;
- (NSString *)displayMessage;

@end


@protocol PXAutomaticEnvironmentOperations <NSObject>

@property (nonatomic, copy) NSSet<NSString *> *targetBundleIdentifiers;

- (BOOL)terminateTargetBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
- (void)clearKeychainForTargetBundleIdentifier:(NSString *)bundleIdentifier
                                     completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)clearTargetBundleIdentifier:(NSString *)bundleIdentifier
                         completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (BOOL)clearPasteboardWithError:(NSError **)error;
- (BOOL)clearSafariWithError:(NSError **)error;
- (BOOL)generateAndActivateEnvironmentWithError:(NSError **)error;

@end

typedef void (^PXAutomaticEnvironmentCompletion)(PXAutomaticEnvironmentResult *result);

@interface PXAutomaticEnvironmentCoordinator : NSObject

@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

- (instancetype)initWithOperations:(id<PXAutomaticEnvironmentOperations>)operations
                          workQueue:(dispatch_queue_t)workQueue
                    completionQueue:(dispatch_queue_t)completionQueue;
- (instancetype)initWithOperations:(id<PXAutomaticEnvironmentOperations>)operations
          targetSelectionReconciler:(nullable id<PXTargetSelectionReconciling>)targetSelectionReconciler
                          workQueue:(dispatch_queue_t)workQueue
                    completionQueue:(dispatch_queue_t)completionQueue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)runWithTargetBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                             completion:(PXAutomaticEnvironmentCompletion)completion;

@end

NS_ASSUME_NONNULL_END
