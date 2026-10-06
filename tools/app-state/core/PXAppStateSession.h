#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Product orchestration. The backend is a scoped, short-lived mobile worker.
@protocol PXAppStateSessionBackend <NSObject>
- (nullable NSArray<NSDictionary *> *)catalog:(NSError **)error;
- (nullable NSDictionary *)target:(NSError **)error;
- (nullable NSDictionary *)association:(NSError **)error;
- (BOOL)writeAssociation:(nullable NSDictionary *)association error:(NSError **)error;
- (nullable NSDictionary *)captureName:(NSString *)name replace:(BOOL)replace metadata:(nullable NSDictionary *)metadata error:(NSError **)error;
- (BOOL)createBaseline:(NSError **)error;
- (BOOL)restore:(NSString *)reference error:(NSError **)error;
- (BOOL)edit:(NSString *)reference metadata:(NSDictionary *)metadata error:(NSError **)error;
- (BOOL)remove:(NSString *)reference error:(NSError **)error;
@end
@interface PXAppStateSession : NSObject
- (instancetype)initWithBackend:(id<PXAppStateSessionBackend>)backend;
- (nullable NSDictionary *)perform:(NSDictionary *)request error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
