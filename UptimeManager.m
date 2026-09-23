#import "UptimeManager.h"
#import "ProfileManifest.h"
#import "PXRootHidePath.h"

@interface UptimeManager ()
@property (nonatomic, strong) NSError *error;
@end

@implementation UptimeManager

+ (instancetype)sharedManager {
    static UptimeManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (PXProfileManifest *)currentManifest {
    PXProfileStore *store = [[PXProfileStore alloc]
        initWithIdentityDirectory:PXCurrentProfileIdentityValuesPath()];
    NSError *loadError = nil;
    PXProfileManifest *manifest = [store activeManifestWithError:&loadError];
    self.error = loadError;
    return manifest;
}

- (NSDate *)currentBootTime {
    return [self currentManifest].virtualSession.bootTime;
}

- (NSTimeInterval)currentUptime {
    NSDate *bootTime = [self currentBootTime];
    return bootTime ? MAX(0, [[NSDate date] timeIntervalSinceDate:bootTime]) : 0;
}

- (NSString *)generateUptime {
    return [NSString stringWithFormat:@"%.0f", [self currentUptime]];
}

- (NSString *)generateBootTime {
    NSDate *bootTime = [self currentBootTime];
    return bootTime ? [NSString stringWithFormat:@"%.0f", bootTime.timeIntervalSince1970] : @"0";
}

- (void)setCurrentUptime:(NSTimeInterval)uptime {
    self.error = [NSError errorWithDomain:@"com.weaponx.UptimeManager" code:1005
        userInfo:@{NSLocalizedDescriptionKey: @"Boot time is managed by current_profile.plist"}];
}

- (void)setCurrentBootTime:(NSDate *)bootTime {
    self.error = [NSError errorWithDomain:@"com.weaponx.UptimeManager" code:1005
        userInfo:@{NSLocalizedDescriptionKey: @"Boot time is managed by current_profile.plist"}];
}

- (NSString *)debugSpoofedUptimeInfo {
    NSDate *bootTime = [self currentBootTime];
    return [NSString stringWithFormat:@"Boot Time: %@\nUptime: %.0f seconds",
        bootTime, [self currentUptime]];
}

- (NSError *)lastError {
    return self.error;
}

@end
