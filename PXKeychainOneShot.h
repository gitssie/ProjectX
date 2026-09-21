#import <Foundation/Foundation.h>

#import "KeychainCommand.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXKeychainOneShotErrorDomain;

typedef PXKeychainCommandResponse PXKeychainOneShotResponse;

@interface PXKeychainOneShotEntitlementPlan : NSObject

@property (nonatomic, copy, readonly) NSString *applicationIdentifier;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *workerEntitlements;
@property (nonatomic, strong, readonly) PXKeychainDeletionPlan *deletionPlan;
@property (nonatomic, assign, readonly) NSUInteger skippedSharedAccessGroupCount;

+ (nullable instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                              signedEntitlements:(NSDictionary<NSString *, id> *)signedEntitlements
                                           error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                              signedEntitlements:(NSDictionary<NSString *, id> *)signedEntitlements
                       includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
                                           error:(NSError * _Nullable * _Nullable)error;

@end

@protocol PXKeychainOneShotExecuting <NSObject>

- (nullable NSDictionary<NSString *, id> *)signedEntitlementsForTargetBundleIdentifier:
    (NSString *)bundleIdentifier
                                                                                     error:
    (NSError * _Nullable * _Nullable)error;
- (nullable PXKeychainOneShotResponse *)executeRequest:(PXKeychainCommandRequest *)request
                                    workerEntitlements:(NSDictionary<NSString *, id> *)workerEntitlements
                                                 error:(NSError * _Nullable * _Nullable)error;

@end


@interface PXKeychainOneShotController : NSObject

- (instancetype)initWithExecution:(id<PXKeychainOneShotExecuting>)execution;
- (nullable PXKeychainOneShotResponse *)executeRequest:(PXKeychainCommandRequest *)request
                                               context:(PXKeychainCommandContext *)context
                                                   now:(NSDate *)now
                                                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
