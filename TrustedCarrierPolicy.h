#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PXTrustedCarrierPolicyStore : NSObject

- (instancetype)initWithProfileDirectory:(NSString *)profileDirectory;
- (nullable NSSet<NSString *> *)trustedCarrierIDsWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveTrustedCarrierIDs:(NSSet<NSString *> *)trustedCarrierIDs
                         error:(NSError * _Nullable * _Nullable)error;
- (nullable NSString *)selectedCarrierIDWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveSelectedCarrierID:(NSString *)carrierID
                         error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
