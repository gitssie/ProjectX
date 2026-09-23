#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UptimeManager : NSObject

// Singleton accessor
+ (instancetype)sharedManager;

// System Uptime Generation
- (NSString *)generateUptime;
- (NSTimeInterval)currentUptime;
- (void)setCurrentUptime:(NSTimeInterval)uptime;

// Boot Time Generation
- (NSString *)generateBootTime;
- (nullable NSDate *)currentBootTime;
- (void)setCurrentBootTime:(NSDate *)bootTime;

// Error handling
@property (nonatomic, readonly) NSError *lastError;

@end

NS_ASSUME_NONNULL_END 