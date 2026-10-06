"""Render production home layout methods with isolated app/environment fixtures.

No privileged operations are compiled or invoked. The mode selector uses the
real policy store against a simulator-only file. Production layouts are extracted
at build time so this fixture cannot silently drift into a separate UI design.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
source = (root / "ProjectXViewController.m").read_text()


def method(selector):
    match = next(m for m in re.finditer(r"^- \([^\n]+", source, re.M)
                 if selector in m.group())
    start = match.start()
    pos = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == "{") - (source[pos] == "}")
        pos += 1
    return source[start:pos].replace("ProjectXViewController", "HomePreview")


selectors = [
    "configureNavigation", "configureTableView", "homeSectionForTableSection",
    "usesBackupMode", "visibleHomeSections", "numberOfSectionsInTableView",
    *["tableView:(UITableView *)tableView " + suffix for suffix in [
        "numberOfRowsInSection", "titleForHeaderInSection", "titleForFooterInSection",
        "viewForHeaderInSection", "heightForHeaderInSection", "heightForFooterInSection",
        "cellForRowAtIndexPath"]],
    "pendingChangesCellForTableView", "generationCellForTableView",
    "configureEnvironmentContent", "configureCleanupContent", "backupGridCell",
]
head = source[source.index("typedef NS_ENUM"):source.index("@interface ProjectXViewController")]
properties = "\n".join(line for line in source.splitlines() if line.startswith("@property")
                       and any(key in line for key in [
                           "tableView", "selectedTarget", "backupApplications;",
                           "environmentState", "environmentModel", "environmentNetwork",
                           "environmentCarrier", "environmentRegion", "environmentLocation",
                           "hasPendingChanges", "cleanupInProgress", "cleanupStatusMessage",
                           "environmentPolicyStore;"]))
settings = (root / "PXSettingsHubViewController.m").read_text()
mode_selector = settings[settings.index("@implementation PXAppEnvironmentModeViewController"):]
mode_selector = mode_selector[:mode_selector.index("@end") + 4]
mode_selector = mode_selector.replace("[PXEnvironmentPolicyStore sharedStore]", "[HomePolicy store]")
text = r'''
#import <UIKit/UIKit.h>
#import "PXLocalizedStrings.h"
#import "PXAppBackupGridView.h"
#import "PXEnvironmentPolicy.h"
#import "AppDataBackupRestoreViewController.h"
void RunOperationsModeTests(void);
NSString *PXLocalizedString(NSString *key){return [[NSBundle mainBundle] localizedStringForKey:key value:key table:nil];}
NSString *PXLocalizedFormat(NSString *key,...){va_list args;va_start(args,key);NSString *s=[[NSString alloc] initWithFormat:PXLocalizedString(key) arguments:args];va_end(args);return s;}
@implementation AppDataBackupRestoreViewController
@end
@interface HomePolicy : NSObject
+ (PXEnvironmentPolicyStore *)store;
@end
@implementation HomePolicy
+ (PXEnvironmentPolicyStore *)store {
    static PXEnvironmentPolicyStore *store;static dispatch_once_t once;
    dispatch_once(&once,^{store=[[PXEnvironmentPolicyStore alloc] initWithFilePath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"home-fixture-policy.plist"]];});return store;
}
@end
@interface PXAppEnvironmentModeViewController : UITableViewController
@end
''' + mode_selector + "\n" + head + "\n@interface HomePreview:UIViewController<UITableViewDataSource,UITableViewDelegate>\n" + properties + "\n@end\n@implementation HomePreview\n" + "\n".join(method(s) for s in selectors) + r'''
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    if([NSProcessInfo.processInfo.environment[@"PX_HOME_MODE"] isEqual:@"operation-tests"])RunOperationsModeTests();
    self.environmentPolicyStore=[HomePolicy store];
    BOOL cleanup=[NSProcessInfo.processInfo.environment[@"PX_HOME_MODE"] isEqual:@"cleanup"];
    [self.environmentPolicyStore saveApplicationEnvironmentMode:cleanup?PXApplicationEnvironmentModeCleanup:PXApplicationEnvironmentModeBackup error:nil];
    NSArray *names=[NSProcessInfo.processInfo.environment[@"PX_HOME_MODE"] isEqual:@"grid-many"]?@[@"Vinted",@"eBay",@"Etsy",@"Depop",@"Marketplace",@"Vestiaire",@"Poshmark"]:@[@"Vinted",@"eBay",@"Etsy"];
    [self configureNavigation];[self configureTableView];self.selectedTargetCount=names.count;
    self.selectedTargetBundleIdentifiers=[NSSet setWithArray:names];
    self.environmentModel=@"iPhone 14 Pro";self.environmentNetwork=@"Wi-Fi";self.environmentCarrier=@"Orange";self.environmentRegion=@"法国";self.environmentLocation=@"巴黎";
    NSMutableArray *apps=[NSMutableArray array];NSUInteger i=0;
    for(NSString *name in names) {
        UIColor *color=@[[UIColor colorWithRed:0 green:.51 blue:.56 alpha:1],i==1?UIColor.whiteColor:UIColor.systemBlueColor,UIColor.systemOrangeColor][i%3];
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64,64)];
        UIImage *icon=[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx){(void)ctx;[color setFill];UIRectFill(CGRectMake(0,0,64,64));
            NSString *title=i==1?@"eBay":[name substringToIndex:1];
            [title drawAtPoint:i==1?CGPointMake(3,20):CGPointMake(16,6) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:i==1?22:43 weight:UIFontWeightHeavy],NSForegroundColorAttributeName:i==1?UIColor.systemBlueColor:UIColor.whiteColor}];}];
        [apps addObject:@{@"bundleIdentifier":name,@"displayName":name,@"icon":icon,@"available":@YES}];i++;
    }
    self.backupApplications=apps;
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self.tableView reloadData];}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];[self.tableView layoutIfNeeded];
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[self usesBackupMode]?1:0 inSection:1] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
    [self.tableView layoutIfNeeded];
    NSCAssert([self.tableView numberOfRowsInSection:1]==([self usesBackupMode]?2:1),@"Mode controls backup grid");
    NSArray *sections=[self visibleHomeSections];
    NSCAssert([sections containsObject:@(PXHomeSectionGenerate)]==![self usesBackupMode],@"Cleanup button is exclusive");
    NSInteger cleanupSection=[sections indexOfObject:@(PXHomeSectionPrivacyCleanup)];
    NSCAssert([self.tableView numberOfRowsInSection:cleanupSection]==([self usesBackupMode]?1:3),@"Only clipboard remains in backup mode");
    UITableViewCell *selection=[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    UIListContentConfiguration *config=(id)selection.contentConfiguration;
    NSDictionary *report=@{@"backupMode":@([self usesBackupMode]),@"selectionRowHeight":@([self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]].size.height),@"selectionFont":@(config.textProperties.font.pointSize),@"secondaryFont":@(config.secondaryTextProperties.font.pointSize),@"sections":sections};
    [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"home-layout.plist"] atomically:YES];
    if([NSProcessInfo.processInfo.environment[@"PX_HOME_MODE"] isEqual:@"settings"])[self handleSettingsTapped:nil];
}
- (void)configurePhysicalDeviceContent:(UIListContentConfiguration *)content {content.text=@"iPhone 14 Pro";content.secondaryText=@"模拟器显示数据";}
- (void)handleSettingsTapped:(id)sender {(void)sender;[self.navigationController pushViewController:[[PXAppEnvironmentModeViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:NO];}
- (void)handleGenerateTapped:(id)sender {(void)sender;}
@end
@interface Delegate:UIResponder<UIApplicationDelegate>
@property (nonatomic,strong) UIWindow *window;
@end
@implementation Delegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {(void)application;(void)options;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[HomePreview new]];[self.window makeKeyAndVisible];return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(Delegate.class));}}
'''
Path(sys.argv[1]).write_text(text)
