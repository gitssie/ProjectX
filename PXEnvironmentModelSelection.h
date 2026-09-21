#import <Foundation/Foundation.h>

@class PXEnvironmentPolicyStore;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const PXEnvironmentModelSelectionErrorDomain;

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable PXResolveEnvironmentModelSelection(
    PXEnvironmentPolicyStore *policyStore,
    NSArray<NSDictionary<NSString *, id> *> *availableModelRecords,
    NSDictionary<NSString *, id> * _Nullable physicalModelRecord,
    NSDictionary<NSString *, id> *hostGraphicsCapabilities,
    BOOL * _Nullable didMigrate,
    NSError * _Nullable * _Nullable error
);

FOUNDATION_EXPORT BOOL PXEnvironmentModelSelectionCanRecoverFromError(NSError *error);

NS_ASSUME_NONNULL_END
