#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PXAppStateService : NSObject
// Work is serialized off the main thread; completion always runs on main.
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request
           completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request
            progress:(void (^ _Nullable)(NSDictionary *event))progress
           completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
