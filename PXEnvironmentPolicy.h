#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const PXEnvironmentPolicyErrorDomain;

typedef NS_ENUM(NSInteger, PXEnvironmentNetworkType) {
    PXEnvironmentNetworkTypeUnspecified = 0,
    PXEnvironmentNetworkTypeWiFi,
    PXEnvironmentNetworkType5GNR,
    PXEnvironmentNetworkType4GLTE,
    PXEnvironmentNetworkType3G,
    PXEnvironmentNetworkType2G,
    PXEnvironmentNetworkTypeNone
};

typedef NS_ENUM(NSInteger, PXEnvironmentModelSelectionMode) {
    PXEnvironmentModelSelectionModeMissing = 0,
    PXEnvironmentModelSelectionModePhysicalDevice,
    PXEnvironmentModelSelectionModeCustom
};

FOUNDATION_EXPORT NSString *PXEnvironmentNetworkTypeIdentifier(PXEnvironmentNetworkType networkType);
FOUNDATION_EXPORT PXEnvironmentNetworkType PXEnvironmentNetworkTypeFromIdentifier(NSString * _Nullable identifier);
FOUNDATION_EXPORT BOOL PXEnvironmentNetworkTypeIsCompatibleWithModelRecord(
    PXEnvironmentNetworkType networkType,
    NSDictionary<NSString *, id> * _Nullable modelRecord
);
FOUNDATION_EXPORT BOOL PXEnvironmentAppliedStateIsReady(
    BOOL hasPendingChanges,
    NSString * _Nullable lastAppliedGenerationID,
    NSString * _Nullable activeGenerationID,
    NSSet<NSString *> *selectedTargetBundleIdentifiers,
    NSSet<NSString *> *activeTargetBundleIdentifiers
);
FOUNDATION_EXPORT BOOL PXEnvironmentAllowsApplicationIdentityEnsure(
    NSString *bundleIdentifier,
    BOOL activeIdentityExists,
    NSSet<NSString *> *prunedTargetBundleIdentifiers
);

@interface PXEnvironmentPolicyStore : NSObject

@property (nonatomic, copy, readonly) NSString *filePath;

+ (instancetype)sharedStore;
- (instancetype)initWithFilePath:(NSString *)filePath;
- (nullable NSString *)selectedModelIdentifierWithError:(NSError * _Nullable * _Nullable)error;
- (PXEnvironmentModelSelectionMode)selectedModelSelectionModeWithError:(NSError * _Nullable * _Nullable)error;
- (PXEnvironmentNetworkType)selectedNetworkTypeWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSDictionary<NSString *, id> *)configuredLocationWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)locationWasExplicitlyClearedWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)hasPendingChangesWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSDate *)lastAppliedDateWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSString *)lastAppliedGenerationIDWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSSet<NSString *> *)prunedTargetBundleIdentifiersWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveSelectedModelRecord:(NSDictionary<NSString *, id> *)modelRecord
            physicalModelRecord:(NSDictionary<NSString *, id> * _Nullable)physicalModelRecord
        hostGraphicsCapabilities:(NSDictionary<NSString *, id> *)hostGraphicsCapabilities
                            error:(NSError * _Nullable * _Nullable)error;
- (BOOL)savePhysicalDeviceModelRecord:(NSDictionary<NSString *, id> *)modelRecord
                                error:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveSelectedNetworkType:(PXEnvironmentNetworkType)networkType
                     modelRecord:(NSDictionary<NSString *, id> * _Nullable)modelRecord
                           error:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveConfiguredLocation:(NSDictionary<NSString *, id> *)location
                          error:(NSError * _Nullable * _Nullable)error;
- (BOOL)clearConfiguredLocationWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)markPendingChangeWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)setPendingChanges:(BOOL)pendingChanges
                    error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setPendingChanges:(BOOL)pendingChanges
    prunedTargetBundleIdentifiers:(NSSet<NSString *> *)prunedTargetBundleIdentifiers
                    error:(NSError * _Nullable * _Nullable)error;
- (BOOL)markAppliedGenerationID:(NSString *)generationID
                            date:(NSDate *)date
                           error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
