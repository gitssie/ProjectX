#import <UIKit/UIKit.h>

@interface AppDataBackupRestoreViewController : UIViewController

@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, strong) NSString *appName;
@property (nonatomic, strong) UIImage *appIcon;

// Convenience methods to set the properties
- (void)setBundleID:(NSString *)bundleID;
- (void)setAppName:(NSString *)appName;

@end
