#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXTargetSelectionReconciliationErrorDomain;

typedef NS_ENUM(NSInteger, PXTargetSelectionReconciliationError) {
    PXTargetSelectionReconciliationErrorSnapshotUnavailable = 1,
    PXTargetSelectionReconciliationErrorSnapshotUntrusted,
    PXTargetSelectionReconciliationErrorStateInvalid,
    PXTargetSelectionReconciliationErrorStateCommitFailed,
    PXTargetSelectionReconciliationErrorStateRollbackFailed
};

FOUNDATION_EXPORT NSString *const PXTargetSelectionAppIdentityChangedNotification;
FOUNDATION_EXPORT NSString *const PXTargetSelectionScopeChangedNotification;

@interface PXInstalledAppSnapshot : NSObject

@property (nonatomic, assign, readonly, getter=isTrusted) BOOL trusted;
@property (nonatomic, copy, readonly) NSSet<NSString *> *installedUserBundleIdentifiers;
@property (nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, id> *> *applicationCandidates;
@property (nonatomic, copy, readonly, nullable) NSString *failureReason;

+ (instancetype)trustedSnapshotWithInstalledUserBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                                             applicationCandidates:(NSArray<NSDictionary<NSString *, id> *> *)candidates;
+ (instancetype)untrustedSnapshotWithApplicationCandidates:(NSArray<NSDictionary<NSString *, id> *> *)candidates
                                                     reason:(NSString *)reason;

@end


@protocol PXInstalledAppSnapshotProviding <NSObject>

- (nullable PXInstalledAppSnapshot *)installedAppSnapshotForSelectedBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                                                                                  error:(NSError * _Nullable * _Nullable)error;

@end


@interface PXLaunchServicesInstalledAppSnapshotProvider : NSObject <PXInstalledAppSnapshotProviding>
@end


@protocol PXTargetSelectionStateStoring <NSObject>

- (nullable NSSet<NSString *> *)selectedTargetBundleIdentifiersWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)pruneTargetBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                               error:(NSError * _Nullable * _Nullable)error;

@end


@protocol PXTargetSelectionPolicyStoring <NSObject>

- (BOOL)hasPendingChangesWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSSet<NSString *> *)prunedTargetBundleIdentifiersWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)setPendingChanges:(BOOL)pendingChanges
    prunedTargetBundleIdentifiers:(NSSet<NSString *> *)prunedTargetBundleIdentifiers
                    error:(NSError * _Nullable * _Nullable)error;

@end


@protocol PXTargetSelectionIdentityStoring <NSObject>

- (nullable NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)activeApplicationIdentityPropertyListsWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceActiveApplicationIdentityPropertyLists:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)appIdentities
                                                 error:(NSError * _Nullable * _Nullable)error;

@end


typedef void (^PXTargetSelectionCacheInvalidator)(void);
typedef void (^PXTargetSelectionNotificationPublisher)(NSString *notificationName);

@interface PXAtomicTargetSelectionStateStore : NSObject <PXTargetSelectionStateStoring>

@property (nonatomic, assign) BOOL failBeforeScopeCommitForTesting;

- (instancetype)initWithScopeFilePath:(NSString *)scopeFilePath
                           policyStore:(id<PXTargetSelectionPolicyStoring>)policyStore
                         identityStore:(id<PXTargetSelectionIdentityStoring>)identityStore
                      cacheInvalidator:(nullable PXTargetSelectionCacheInvalidator)cacheInvalidator
                 notificationPublisher:(nullable PXTargetSelectionNotificationPublisher)notificationPublisher;

@end


@interface PXTargetSelectionReconciliationResult : NSObject

// Selected targets that are currently installed and safe to execute against.
@property (nonatomic, copy, readonly) NSSet<NSString *> *selectedBundleIdentifiers;
// Durable selections that are temporarily unavailable and must remain persisted.
@property (nonatomic, copy, readonly) NSSet<NSString *> *unavailableBundleIdentifiers;
// Legacy destructive-pruning signal. Reconciliation no longer prunes absent apps.
@property (nonatomic, copy, readonly) NSSet<NSString *> *prunedBundleIdentifiers;
@property (nonatomic, strong, readonly, nullable) PXInstalledAppSnapshot *snapshot;

+ (instancetype)resultWithSelectedBundleIdentifiers:(NSSet<NSString *> *)selectedBundleIdentifiers
                             prunedBundleIdentifiers:(NSSet<NSString *> *)prunedBundleIdentifiers;
+ (instancetype)resultWithSelectedBundleIdentifiers:(NSSet<NSString *> *)selectedBundleIdentifiers
                         unavailableBundleIdentifiers:(NSSet<NSString *> *)unavailableBundleIdentifiers;

@end


@protocol PXTargetSelectionReconciling <NSObject>

- (nullable PXTargetSelectionReconciliationResult *)reconcileWithError:(NSError * _Nullable * _Nullable)error;

@end


@interface PXTargetSelectionReconciler : NSObject <PXTargetSelectionReconciling>

- (instancetype)initWithSnapshotProvider:(id<PXInstalledAppSnapshotProviding>)snapshotProvider
                               stateStore:(id<PXTargetSelectionStateStoring>)stateStore;
- (nullable PXTargetSelectionReconciliationResult *)reconcileWithError:(NSError * _Nullable * _Nullable)error;
- (nullable PXTargetSelectionReconciliationResult *)reconcileWithSnapshot:(PXInstalledAppSnapshot *)snapshot
                                                                      error:(NSError * _Nullable * _Nullable)error;

@end


NS_ASSUME_NONNULL_END
