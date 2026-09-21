#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PXKeychainCommandResponse;

FOUNDATION_EXPORT NSString *const PXKeychainCommandErrorDomain;
FOUNDATION_EXPORT const NSInteger PXKeychainCommandSchemaVersion;
FOUNDATION_EXPORT const int32_t PXKeychainStatusSuccess;
FOUNDATION_EXPORT const int32_t PXKeychainStatusItemNotFound;
FOUNDATION_EXPORT NSString *const PXKeychainCommandRequestNotification;
FOUNDATION_EXPORT NSString *const PXKeychainCommandResponseNotification;
FOUNDATION_EXPORT NSString *const PXKeychainCommandReadyNotification;
FOUNDATION_EXPORT NSString *const PXKeychainCommandProbeNotification;
FOUNDATION_EXPORT NSString *PXKeychainCommandDefaultRootDirectory(void);
FOUNDATION_EXPORT BOOL PXKeychainCommandReceiverShouldRegisterForBundleIdentifier(
    NSString *bundleIdentifier
);
FOUNDATION_EXPORT BOOL PXKeychainCommandProfileIdentifierIsValid(
    NSString * _Nullable profileIdentifier
);

@interface PXKeychainCommandRequest : NSObject

@property (nonatomic, copy, readonly) NSString *requestID;
@property (nonatomic, copy, readonly) NSString *targetBundleID;
@property (nonatomic, copy, readonly) NSString *profileID;
@property (nonatomic, copy, readonly) NSString *generationID;
@property (nonatomic, copy, readonly) NSString *operation;
@property (nonatomic, strong, readonly) NSDate *createdAt;
@property (nonatomic, strong, readonly) NSDate *expiresAt;
@property (nonatomic, assign, readonly) BOOL includesSharedAccessGroups;
@property (nonatomic, assign, readonly) BOOL includesSynchronizableItems;

+ (nullable instancetype)requestWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                           error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)freshRequestForBundleIdentifier:(NSString *)bundleIdentifier
                                                profileID:(NSString *)profileID
                                             generationID:(NSString *)generationID
                               includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
                               includeSynchronizableItems:(BOOL)includeSynchronizableItems
                                                      now:(NSDate *)now
                                                     ttl:(NSTimeInterval)ttl
                                                   error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, id> *)propertyListRepresentation;

@end

FOUNDATION_EXPORT NSString *const PXKeychainClassGenericPassword;
FOUNDATION_EXPORT NSString *const PXKeychainClassInternetPassword;
FOUNDATION_EXPORT NSString *const PXKeychainClassCertificate;
FOUNDATION_EXPORT NSString *const PXKeychainClassKey;
FOUNDATION_EXPORT NSString *const PXKeychainClassIdentity;

@interface PXKeychainDeletionScope : NSObject

@property (nonatomic, copy, readonly) NSString *keychainClass;
@property (nonatomic, copy, readonly) NSString *accessGroup;
@property (nonatomic, assign, readonly, getter=isSynchronizable) BOOL synchronizable;
@property (nonatomic, assign, readonly, getter=isSharedAccessGroup) BOOL sharedAccessGroup;

@end

@interface PXKeychainDeletionPlan : NSObject

@property (nonatomic, copy, readonly) NSArray<PXKeychainDeletionScope *> *scopes;
@property (nonatomic, copy, readonly) NSString *applicationIdentifier;
@property (nonatomic, copy, readonly) NSSet<NSString *> *sharedAccessGroups;

+ (nullable instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                                    entitlements:(NSDictionary<NSString *, id> *)entitlements
                      includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
                                           error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                                    entitlements:(NSDictionary<NSString *, id> *)entitlements
                      includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
                      includeSynchronizableItems:(BOOL)includeSynchronizableItems
                                           error:(NSError * _Nullable * _Nullable)error;

@end

@interface PXKeychainCommandContext : NSObject

@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@property (nonatomic, copy, readonly) NSString *profileID;
@property (nonatomic, copy, readonly) NSString *generationID;
@property (nonatomic, assign, readonly, getter=isApplicationEnabled) BOOL applicationEnabled;
@property (nonatomic, assign, readonly, getter=isExtensionEnabled) BOOL extensionEnabled;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                profileID:(NSString *)profileID
                             generationID:(NSString *)generationID
                       applicationEnabled:(BOOL)applicationEnabled
                         extensionEnabled:(BOOL)extensionEnabled;

@end

@interface PXKeychainCommandValidator : NSObject

- (BOOL)claimRequest:(PXKeychainCommandRequest *)request
             context:(PXKeychainCommandContext *)context
                 now:(NSDate *)now
               error:(NSError * _Nullable * _Nullable)error;

@end

@interface PXKeychainCommandFileStore : NSObject

- (instancetype)initWithRootDirectory:(NSString *)rootDirectory;
- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)writeRequest:(PXKeychainCommandRequest *)request
               error:(NSError * _Nullable * _Nullable)error;
- (NSArray<PXKeychainCommandRequest *> *)pendingRequestsWithError:(NSError * _Nullable * _Nullable)error;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)rejectedRequestHeadersWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)claimRequestID:(NSString *)requestID
                 error:(NSError * _Nullable * _Nullable)error;
- (BOOL)isRequestIDClaimed:(NSString *)requestID;
- (BOOL)markRequestIDCompleted:(NSString *)requestID
                         error:(NSError * _Nullable * _Nullable)error;
- (BOOL)isRequestIDCompleted:(NSString *)requestID;
- (BOOL)writeResponse:(PXKeychainCommandResponse *)response
                 error:(NSError * _Nullable * _Nullable)error;
- (nullable PXKeychainCommandResponse *)responseForRequestID:(NSString *)requestID
                                                        error:(NSError * _Nullable * _Nullable)error;
- (BOOL)writeReadinessForBundleIdentifier:(NSString *)bundleIdentifier
                                 profileID:(NSString *)profileID
                              generationID:(NSString *)generationID
                                       now:(NSDate *)now
                                     error:(NSError * _Nullable * _Nullable)error;
- (BOOL)isReadyBundleIdentifier:(NSString *)bundleIdentifier
                      profileID:(NSString *)profileID
                   generationID:(NSString *)generationID
                            now:(NSDate *)now
                    maximumAge:(NSTimeInterval)maximumAge;
- (void)removeTransactionForRequestID:(NSString *)requestID;

@end

@protocol PXKeychainSecurityAdapter <NSObject>

- (nullable NSDictionary<NSString *, id> *)entitlementsForBundleIdentifier:(NSString *)bundleIdentifier
                                                                       error:(NSError * _Nullable * _Nullable)error;
- (NSUInteger)countItemsForClass:(NSString *)keychainClass
                     accessGroup:(NSString *)accessGroup
                  synchronizable:(BOOL)synchronizable
                          status:(int32_t *)status;
- (int32_t)deleteItemsForClass:(NSString *)keychainClass
                   accessGroup:(NSString *)accessGroup
                synchronizable:(BOOL)synchronizable;

@end

@interface PXKeychainScopeResult : NSObject

@property (nonatomic, copy, readonly) NSString *keychainClass;
@property (nonatomic, copy, readonly) NSString *accessGroup;
@property (nonatomic, assign, readonly) NSUInteger beforeCount;
@property (nonatomic, assign, readonly) NSUInteger deletedCount;
@property (nonatomic, assign, readonly) NSUInteger remainingCount;
@property (nonatomic, assign, readonly) int32_t queryStatus;
@property (nonatomic, assign, readonly) int32_t deleteStatus;
@property (nonatomic, assign, readonly) int32_t verificationStatus;
@property (nonatomic, assign, readonly) BOOL skippedSynchronizable;
@property (nonatomic, assign, readonly, getter=isSharedAccessGroup) BOOL sharedAccessGroup;
@property (nonatomic, assign, readonly, getter=isSuccessful) BOOL successful;

- (NSDictionary<NSString *, id> *)propertyListRepresentation;

@end

@interface PXKeychainCommandResponse : NSObject

@property (nonatomic, copy, readonly) NSString *requestID;
@property (nonatomic, copy, readonly) NSString *targetBundleID;
@property (nonatomic, copy, readonly) NSArray<PXKeychainScopeResult *> *results;
@property (nonatomic, assign, readonly, getter=isSuccessful) BOOL successful;
@property (nonatomic, copy, readonly, nullable) NSString *failureCode;
@property (nonatomic, assign, readonly) NSUInteger protectedSharedAccessGroupCount;

- (NSDictionary<NSString *, id> *)propertyListRepresentation;
- (instancetype)responseByRecordingProtectedSharedAccessGroupCount:(NSUInteger)count;
+ (nullable instancetype)responseWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                             error:(NSError * _Nullable * _Nullable)error;
+ (instancetype)failureResponseForRequest:(PXKeychainCommandRequest *)request
                                      code:(NSString *)code;
+ (instancetype)failureResponseForRequestID:(NSString *)requestID
                             targetBundleID:(NSString *)targetBundleID
                                       code:(NSString *)code;

@end

@interface PXKeychainCommandExecutor : NSObject

- (instancetype)initWithValidator:(PXKeychainCommandValidator *)validator
                   securityAdapter:(id<PXKeychainSecurityAdapter>)securityAdapter;
- (nullable PXKeychainCommandResponse *)executeRequest:(PXKeychainCommandRequest *)request
                                                context:(PXKeychainCommandContext *)context
                                                    now:(NSDate *)now
                                                  error:(NSError * _Nullable * _Nullable)error;

@end

@protocol PXKeychainCommandTransport <NSObject>

- (void)waitForReadyBundleIdentifier:(NSString *)bundleIdentifier
                            profileID:(NSString *)profileID
                         generationID:(NSString *)generationID
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(BOOL ready, NSError * _Nullable error))completion;
- (void)sendRequest:(PXKeychainCommandRequest *)request
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(PXKeychainCommandResponse * _Nullable response,
                               NSError * _Nullable error))completion;

@end

@protocol PXKeychainAppLifecycle <NSObject>

- (void)ensureRunningBundleIdentifier:(NSString *)bundleIdentifier
                            completion:(void (^)(BOOL running, NSError * _Nullable error))completion;
- (void)terminateBundleIdentifier:(NSString *)bundleIdentifier
                        completion:(void (^)(BOOL terminated, NSError * _Nullable error))completion;

@end

@interface PXKeychainCommandController : NSObject

- (instancetype)initWithTransport:(id<PXKeychainCommandTransport>)transport
                         lifecycle:(id<PXKeychainAppLifecycle>)lifecycle
                      readyTimeout:(NSTimeInterval)readyTimeout
                   responseTimeout:(NSTimeInterval)responseTimeout
                   completionQueue:(dispatch_queue_t)completionQueue;
- (void)executeRequest:(PXKeychainCommandRequest *)request
             completion:(void (^)(PXKeychainCommandResponse * _Nullable response,
                                  NSError * _Nullable error))completion;

@end

@interface PXKeychainFileTransport : NSObject <PXKeychainCommandTransport>

- (instancetype)initWithFileStore:(PXKeychainCommandFileStore *)fileStore
                       pollingQueue:(dispatch_queue_t)pollingQueue;

@end


NS_ASSUME_NONNULL_END
