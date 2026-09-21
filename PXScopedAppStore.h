#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PXScopedAppStore : NSObject

@property (nonatomic, copy, readonly) NSString *filePath;

- (instancetype)initWithFilePath:(NSString *)filePath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApplicationsWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceScopedApplications:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApplications
                            error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
