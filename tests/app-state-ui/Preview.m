// Simulator-only visual fixture. It compiles the production view controller;
// no device paths, Keychain, or privileged workers are used in this preview.
#import <UIKit/UIKit.h>
#import "../../AppDataBackupRestoreViewController.h"
#import "../../PXAppStateService.h"
#import "../../PXLocalizedStrings.h"
#import "../../PXAppBackupGridView.h"
#import "../../PXAppStateProgressViewController.h"
@interface AppDataBackupRestoreViewController (PreviewActions)
- (void)backup;
- (void)baseline;
- (void)switchTo:(NSDictionary *)entry;
- (void)edit:(NSDictionary *)entry;
- (void)editField:(NSString *)field entry:(NSDictionary *)entry;
- (void)remove:(NSDictionary *)entry;
@end
@interface PXAppStateProgressViewController (PreviewActions)
- (void)confirm;
- (void)discard;
- (void)toggleAutomaticBackup;
- (void)cancelConfirmation;
@end
static NSMutableArray<NSDictionary *> *RecordedRequests;
static NSMutableArray<NSString *> *ModalChecks;
static void ReportCheck(BOOL valid,NSString *name) {
    if(!valid){[ModalChecks addObject:[@"FAIL: " stringByAppendingString:name]];}
    else [ModalChecks addObject:name];
    NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [ModalChecks writeToFile:[directory stringByAppendingPathComponent:@"modal-checks.plist"] atomically:YES];
    NSCAssert(valid,@"%@",name);
}
static void ModalStep(NSArray *steps,NSUInteger index) {
    if(index>=steps.count){ReportCheck(YES,@"complete");return;}
    void (^step)(void)=steps[index];step();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1600*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ModalStep(steps,index+1);});
}
NSString *PXLocalizedString(NSString *key) { return [[NSBundle mainBundle] localizedStringForKey:key value:key table:nil]; }
@implementation PXAppStateService
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request progress:(void (^)(NSDictionary *))progress completion:(void (^)(NSDictionary *,NSError *))completion {
    (void)progress;[self executeBundle:bundleID request:request completion:completion];
}
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request completion:(void (^)(NSDictionary *,NSError *))completion {
    (void)bundleID;
    if(!RecordedRequests)RecordedRequests=[NSMutableArray array];[RecordedRequests addObject:request];
    NSMutableArray *entries=[NSMutableArray array];
    NSArray *names=@[@"账号 A",@"账号 B",@"账号 C",@"账号 D"];
    NSArray *notes=@[@"法国账号",@"测试账号",@"备用账号",@"个人账号"];
    for (NSUInteger i=0;i<names.count;i++) [entries addObject:@{@"reference":[NSString stringWithFormat:@"test/snapshots/20261006-%02lu",(unsigned long)(i+1)],
        @"name":names[i],@"kind":@"snapshot",@"version":@"26.38.0",@"savedAt":[NSDate dateWithTimeIntervalSinceNow:-(double)i*3600],@"account":@{@"displayName":names[i],@"note":notes[i]}}];
    [entries addObject:@{@"reference":@"test/baselines/26.38.0",@"kind":@"baseline",@"version":@"26.38.0"}];
    NSString *mode=NSProcessInfo.processInfo.environment[@"PX_PREVIEW_MODE"];
    BOOL unassigned=[@[@"unassigned",@"empty",@"duplicate"] containsObject:mode?:@""];
    NSDictionary *result=@{@"entries":[mode isEqual:@"empty"]?@[]:entries,@"currentReference":unassigned?@"":@"test/snapshots/20261006-01",
        @"duplicateIdentityReferences":[mode isEqual:@"duplicate"]?@[@"test/snapshots/20261006-01",@"test/snapshots/20261006-02"]:@[]};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_MSEC),dispatch_get_main_queue(),^{completion(result,nil);});
}
- (void)scheduleModalFixtures:(AppDataBackupRestoreViewController *)controller mode:(NSString *)mode {
    if([mode isEqual:@"progress-tests"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        ModalChecks=[NSMutableArray array];
        PXAppStateProgressViewController *modal=[[PXAppStateProgressViewController alloc] initWithOperation:@"switch" name:@"账号 A → 账号 B" icon:controller.appIcon];[modal loadViewIfNeeded];
        for(NSString *stage in @[@"identity",@"keychain",@"verify_identity",@"verify_preferences",@"publish",@"internal_unknown_stage"]) {
            [modal updateProgress:@{@"phase":@"restore",@"stage":stage,@"records":@7}];
            NSString *text=[NSString stringWithFormat:@"%@ %@",((UILabel *)[modal valueForKey:@"stage"]).text,((UILabel *)[modal valueForKey:@"detail"]).text];
            BOOL safe=YES;for(NSString *term in @[@"IDFV",@"钥匙串",@"缓存",@"容器",@"keychain",@"manifest",@"internal_unknown_stage",@"app_state.progress"])if([text localizedCaseInsensitiveContainsString:term])safe=NO;
            ReportCheck(safe,[NSString stringWithFormat:@"business progress text hides internal details for %@",stage]);
        }
        ReportCheck(YES,@"complete");
    });
    if([mode hasPrefix:@"confirm-"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        NSArray *entries=[controller valueForKey:@"entries"];
        if([@[@"confirm-new",@"confirm-unassigned",@"confirm-unassigned-unchecked"] containsObject:mode])[controller setValue:@"" forKey:@"currentReference"];
        if([mode isEqual:@"confirm-backup"] || [mode isEqual:@"confirm-new"])[controller backup];
        else if([mode hasPrefix:@"confirm-edit"])[controller edit:entries.firstObject];
        else if([mode isEqual:@"confirm-rename"])[controller editField:@"displayName" entry:entries[1]];
        else if([mode isEqual:@"confirm-note"])[controller editField:@"note" entry:entries[1]];
        else if([mode isEqual:@"confirm-delete"])[controller remove:entries[1]];
        else [controller switchTo:[mode isEqual:@"confirm-baseline"]?entries.lastObject:entries[1]];
        if([mode hasSuffix:@"unchecked"])[[controller valueForKey:@"progressModal"] toggleAutomaticBackup];
        if([mode hasSuffix:@"keyboard"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];
            NSDictionary *inputs=[modal valueForKey:@"inputs"];[inputs[@"displayName"] becomeFirstResponder];
        });
    });
    if([mode isEqual:@"modal-tests"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        ModalChecks=[NSMutableArray array];
        ModalStep(@[^{
            NSUInteger count=RecordedRequests.count;[controller backup];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];
            ReportCheck(modal!=nil && RecordedRequests.count==count,@"backup waits for confirmation");
            [modal cancelConfirmation];[modal confirm];
            ReportCheck(RecordedRequests.count==count,@"cancel prevents execution even if confirm is triggered afterwards");
        },^{
            NSArray *entries=[controller valueForKey:@"entries"];[controller switchTo:entries[1]];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];[modal confirm];
            ReportCheck(controller.presentedViewController==modal && [[modal valueForKey:@"confirmationContainer"] isHidden],@"switch progresses in same presented modal");
            ReportCheck([RecordedRequests.lastObject[@"operation"] isEqual:@"switch"],@"switch confirm submits once");
        },^{
            NSArray *entries=[controller valueForKey:@"entries"];[controller setValue:entries[0][@"reference"] forKey:@"currentReference"];[controller switchTo:entries[1]];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];
            ReportCheck([[modal valueForKey:@"offersAutomaticBackup"] boolValue] && [[modal valueForKey:@"automaticBackup"] boolValue],@"assigned switch shows checked automatic backup option");
            [modal toggleAutomaticBackup];[modal confirm];
            ReportCheck([RecordedRequests.lastObject[@"discardCurrent"] boolValue] && !RecordedRequests.lastObject[@"account"],@"assigned unchecked switch explicitly skips overwriting saved backup");
        },^{
            [controller setValue:@"" forKey:@"currentReference"];NSUInteger count=RecordedRequests.count;[controller backup];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];[modal confirm];
            ReportCheck(RecordedRequests.count==count && ![[modal valueForKey:@"confirmationError"] isHidden],@"empty name stays in modal without mutation");
            NSDictionary *inputs=[modal valueForKey:@"inputs"];((UITextField *)inputs[@"displayName"]).text=@"  新账号  ";((UITextField *)inputs[@"note"]).text=@"保留备注";
            [modal confirm];[modal confirm];
            ReportCheck(RecordedRequests.count==count+1 && [RecordedRequests.lastObject[@"account"] isEqual:@{@"displayName":@"新账号",@"note":@"保留备注"}],@"first backup validates trims and submits once");
        },^{
            [controller setValue:@"" forKey:@"currentReference"];NSArray *entries=[controller valueForKey:@"entries"];[controller switchTo:entries[1]];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];
            ReportCheck([[modal valueForKey:@"automaticBackup"] boolValue] && [[modal valueForKey:@"inputs"] count]==0,@"unassigned switch defaults to automatic backup without name entry");
            NSUInteger count=RecordedRequests.count;[modal confirm];[modal confirm];
            ReportCheck(RecordedRequests.count==count+1 && [RecordedRequests.lastObject[@"account"][@"displayName"] length]>0 && ![RecordedRequests.lastObject[@"discardCurrent"] boolValue],@"default switch submits named backup once before restore");
        },^{
            [controller setValue:@"" forKey:@"currentReference"];NSArray *entries=[controller valueForKey:@"entries"];[controller switchTo:entries[1]];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];[modal toggleAutomaticBackup];
            ReportCheck(![[modal valueForKey:@"discardWarning"] isHidden],@"unchecking backup displays data replacement warning");[modal confirm];
            ReportCheck([RecordedRequests.lastObject[@"discardCurrent"] boolValue] && RecordedRequests.lastObject[@"account"]==nil,@"explicit unchecked option discards without submitting backup metadata");
        },^{
            NSArray *entries=[controller valueForKey:@"entries"];[controller editField:@"displayName" entry:entries[1]];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];NSDictionary *inputs=[modal valueForKey:@"inputs"];
            ((UITextField *)inputs[@"displayName"]).text=@"新名称";[modal confirm];
            ReportCheck([RecordedRequests.lastObject[@"account"] isEqual:@{@"displayName":@"新名称",@"note":@"测试账号"}],@"rename preserves existing note");
            ReportCheck(controller.presentedViewController==modal && [[modal valueForKey:@"timeline"] isHidden],@"metadata edit uses same modal without backup timeline");
        },^{
            NSArray *entries=[controller valueForKey:@"entries"];[controller editField:@"note" entry:entries[1]];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];NSDictionary *inputs=[modal valueForKey:@"inputs"];
            ((UITextField *)inputs[@"note"]).text=@"";[modal confirm];
            ReportCheck([RecordedRequests.lastObject[@"account"] isEqual:@{@"displayName":@"账号 B",@"note":@""}],@"empty note saves while retaining name");
        },^{
            NSArray *entries=[controller valueForKey:@"entries"];NSUInteger count=RecordedRequests.count;[controller remove:entries[1]];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];
            ReportCheck(RecordedRequests.count==count,@"delete does not run before confirmation");[modal confirm];
            ReportCheck([RecordedRequests.lastObject[@"operation"] isEqual:@"delete"] && [RecordedRequests.lastObject[@"reference"] isEqual:entries[1][@"reference"]],@"delete targets only selected backup");
        },^{
            NSArray *entries=[controller valueForKey:@"entries"];[controller switchTo:entries.lastObject];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];[modal confirm];
            ReportCheck([RecordedRequests.lastObject[@"reference"] isEqual:entries.lastObject[@"reference"]] && controller.presentedViewController==modal,@"baseline confirm shares switch progress modal");
        },^{
            [controller setValue:@[] forKey:@"entries"];NSUInteger count=RecordedRequests.count;[controller baseline];
            PXAppStateProgressViewController *modal=[controller valueForKey:@"progressModal"];
            ReportCheck(modal!=nil && RecordedRequests.count==count && ![[modal valueForKey:@"offersAutomaticBackup"] boolValue],@"missing baseline opens creation confirmation without switch or automatic save");
            [modal confirm];
            ReportCheck([RecordedRequests.lastObject[@"operation"] isEqual:@"baseline"] && controller.presentedViewController==modal,@"baseline creation continues inside same progress modal");
        }],0);
    });
}
@end
@interface Delegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation Delegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    AppDataBackupRestoreViewController *controller=[AppDataBackupRestoreViewController new]; controller.bundleID=@"test"; controller.appName=@"Vinted";
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64,64)];
    controller.appIcon=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context; [[UIColor colorWithRed:0 green:0.51 blue:0.56 alpha:1] setFill]; UIRectFill(CGRectMake(0,0,64,64));
        [@"V" drawAtPoint:CGPointMake(16,6) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:43 weight:UIFontWeightHeavy],NSForegroundColorAttributeName:UIColor.whiteColor}];
    }];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:controller];
    if ([NSProcessInfo.processInfo.environment[@"PX_PREVIEW_MODE"] isEqual:@"grid"]) {
        UIViewController *home=[UIViewController new]; home.title=@"应用";
        home.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
        NSMutableArray *apps=[NSMutableArray array];
        for (NSString *name in @[@"Vinted",@"测试应用 B",@"测试应用 C",@"测试应用 D"]) {
            [apps addObject:@{@"bundleIdentifier":name,@"displayName":name,@"available":@YES,@"icon":controller.appIcon}];
        }
        PXAppBackupGridView *grid=[[PXAppBackupGridView alloc] initWithApplications:apps openHandler:^(NSDictionary *app) {
            controller.appName=app[@"displayName"]; [nav pushViewController:controller animated:YES];
        }];
        grid.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
        grid.layer.cornerRadius=16;
        grid.translatesAutoresizingMaskIntoConstraints=NO;
        [home.view addSubview:grid];
        [NSLayoutConstraint activateConstraints:@[
            [grid.topAnchor constraintEqualToAnchor:home.view.safeAreaLayoutGuide.topAnchor constant:20],
            [grid.leadingAnchor constraintEqualToAnchor:home.view.leadingAnchor constant:20],
            [grid.trailingAnchor constraintEqualToAnchor:home.view.trailingAnchor constant:-20]
        ]];
        nav.viewControllers=@[home];
    }
    self.window.rootViewController=nav; [self.window makeKeyAndVisible];
    NSString *mode=NSProcessInfo.processInfo.environment[@"PX_PREVIEW_MODE"];
    [[PXAppStateService new] scheduleModalFixtures:controller mode:mode];
    if([mode hasPrefix:@"progress-"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        BOOL switching=[mode hasPrefix:@"progress-switch"];
        PXAppStateProgressViewController *modal=[[PXAppStateProgressViewController alloc] initWithOperation:switching?@"switch":@"save" name:switching?@"20261006-04 → 20261006-05":@"20261006-04" icon:controller.appIcon];
        [modal updateProgress:@{@"phase":@"backup",@"stage":@"copy",@"bytes":@134217728,@"files":@218}];
        if(switching)[modal updateProgress:@{@"phase":@"restore",@"stage":@"verify_preferences",@"savedCurrent":@YES,@"bytes":@100663296,@"files":@196}];
        else [modal updateProgress:@{@"phase":@"backup",@"stage":@"verify_files",@"bytes":@134217728,@"files":@218}];
        [controller presentViewController:modal animated:NO completion:nil];
        if([mode hasSuffix:@"failed"])[modal finishWithError:PXLocalizedString(@"app_state.operation_failed")];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        UITableView *table=[controller valueForKey:@"table"]; [table layoutIfNeeded];
        NSMutableArray *rows=[NSMutableArray array];
        NSInteger accountsSection=[table.dataSource numberOfSectionsInTableView:table]-1;
        for (NSIndexPath *path in table.indexPathsForVisibleRows) if (path.section==accountsSection) {
            UITableViewCell *cell=[table cellForRowAtIndexPath:path];
            NSMutableDictionary *row=[@{@"row":@(path.row),@"height":@(CGRectGetHeight([table rectForRowAtIndexPath:path])),@"width":@(CGRectGetWidth(cell.bounds))} mutableCopy];
            for (UIView *child in cell.contentView.subviews) if ([child isKindOfClass:UIStackView.class]) {
                for (UIView *item in ((UIStackView *)child).arrangedSubviews) if ([item isKindOfClass:UIButton.class]) row[@"switchTarget"]=@[@(CGRectGetWidth(item.bounds)),@(CGRectGetHeight(item.bounds))];
            }
            [rows addObject:row];
            UISwipeActionsConfiguration *swipe=[table.delegate tableView:table trailingSwipeActionsConfigurationForRowAtIndexPath:path];
            row[@"swipeActions"]=[swipe.actions valueForKey:@"title"]?:@[];
            row[@"fullSwipeEnabled"]=@(swipe.performsFirstActionWithFullSwipe);
        }
        UITableViewCell *active=[table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        NSMutableArray *layers=[NSMutableArray array];
        NSMutableArray<UIView *> *pending=[NSMutableArray arrayWithObject:active];
        while(pending.count) {
            UIView *view=pending.lastObject;[pending removeLastObject];[pending addObjectsFromArray:view.subviews];
            [layers addObject:@{@"class":NSStringFromClass(view.class),@"radius":@(view.layer.cornerRadius),@"masked":@(view.layer.masksToBounds),@"bounds":NSStringFromCGRect(view.bounds),@"maskRadius":@(view.layer.mask.cornerRadius)}];
        }
        NSDictionary *report=@{@"screenWidth":@(CGRectGetWidth(self.window.bounds)),@"rows":rows,@"activeLayers":layers,
            @"activeTopGap":@(CGRectGetMinY([table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]])-table.contentOffset.y)};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [json writeToFile:[directory stringByAppendingPathComponent:@"layout.json"] atomically:YES];
    });
    return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(Delegate.class)); } }
