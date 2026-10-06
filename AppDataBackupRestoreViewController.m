#import "AppDataBackupRestoreViewController.h"
#import "PXAppStateService.h"
#import "PXLocalizedStrings.h"
#import "PXAppStateProgressViewController.h"
#import <QuartzCore/QuartzCore.h>

static NSString *L(NSString *key) { return PXLocalizedString([@"app_state." stringByAppendingString:key]); }
static UIColor *Ink(void) { return UIColor.labelColor; }
static UIColor *PanelColor(void) { return UIColor.secondarySystemGroupedBackgroundColor; }
static UIColor *Accent(void) { return UIColor.systemBlueColor; }
static UILabel *Label(UIFontTextStyle style, UIColor *color) {
    UILabel *label=[UILabel new]; label.font=[UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory=YES; label.textColor=color; label.numberOfLines=0; return label;
}
static UIStackView *Stack(NSArray<UIView *> *views, UILayoutConstraintAxis axis, CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views]; stack.axis=axis; stack.spacing=spacing; return stack;
}
@interface PXAppStatePanelSurface : UIView
@property (nonatomic, strong) CALayer *border;
@property (nonatomic, strong) CAShapeLayer *borderMask;
@end
@implementation PXAppStatePanelSurface
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.border=[CALayer layer];self.border.cornerRadius=26;self.border.cornerCurve=kCACornerCurveContinuous;
        self.border.borderWidth=3;self.border.borderColor=Accent().CGColor;
        self.borderMask=[CAShapeLayer layer];self.border.mask=self.borderMask;[self.layer addSublayer:self.border];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];self.backgroundColor=PanelColor();
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.border.borderColor=[Accent() resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    self.border.frame=self.bounds;self.borderMask.frame=self.bounds;
    self.borderMask.path=[UIBezierPath bezierPathWithRect:CGRectMake(0,0,40,CGRectGetHeight(self.bounds))].CGPath;
    [CATransaction commit];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous { [super traitCollectionDidChange:previous];self.backgroundColor=PanelColor();[self setNeedsLayout]; }
@end
@interface AppDataBackupRestoreViewController () <UITableViewDataSource,UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) PXAppStateService *service;
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy) NSString *currentReference;
@property (nonatomic, copy) NSArray<NSString *> *duplicateIdentityReferences;
@property (nonatomic, assign) BOOL restorePending;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) NSString *activity;
@property (nonatomic, assign) BOOL catalogReady;
@property (nonatomic, strong) UIActivityIndicatorView *initialSpinner;
@property (nonatomic, assign) BOOL initialReadFinished;
@property (nonatomic, strong) PXAppStateProgressViewController *progressModal;
@end
@implementation AppDataBackupRestoreViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.service=[PXAppStateService new]; self.entries=@[]; self.currentReference=@"";
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.table=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.backgroundColor=UIColor.clearColor; self.table.translatesAutoresizingMaskIntoConstraints=NO;
    self.table.dataSource=self; self.table.delegate=self; self.table.rowHeight=UITableViewAutomaticDimension;
    self.table.estimatedRowHeight=52; self.table.sectionHeaderHeight=UITableViewAutomaticDimension; self.table.sectionFooterHeight=12;
    self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.table.separatorInset=UIEdgeInsetsMake(0,16,0,16); [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[[self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor], [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    UIImageView *icon=[[UIImageView alloc] initWithImage:self.appIcon?:[UIImage systemImageNamed:@"square.stack.3d.up.fill"]];
    icon.contentMode=UIViewContentModeScaleAspectFit; icon.layer.cornerRadius=9; icon.clipsToBounds=YES;
    [icon.widthAnchor constraintEqualToConstant:32].active=YES; [icon.heightAnchor constraintEqualToConstant:32].active=YES;
    UILabel *title=Label(UIFontTextStyleHeadline,Ink()); title.text=self.appName?:self.bundleID; title.numberOfLines=1;
    UIStackView *nav=Stack(@[icon,title],UILayoutConstraintAxisHorizontal,9); nav.alignment=UIStackViewAlignmentCenter; self.navigationItem.titleView=nav;
    self.table.refreshControl=[UIRefreshControl new]; [self.table.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.table.hidden=YES;
    self.initialSpinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.initialSpinner.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:self.initialSpinner];
    [NSLayoutConstraint activateConstraints:@[[self.initialSpinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.initialSpinner.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor]]];
    [self updateMenu]; [self reload];
}
- (NSDictionary *)current { for (NSDictionary *entry in self.entries) if ([entry[@"reference"] isEqual:self.currentReference]) return entry; return nil; }
- (NSArray *)otherAccounts {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry,NSDictionary *bindings) {
        (void)bindings; return [entry[@"kind"] isEqual:@"snapshot"] && ![entry[@"reference"] isEqual:self.currentReference];
    }]; return [self.entries filteredArrayUsingPredicate:predicate];
}
- (NSString *)name:(NSDictionary *)entry { return entry[@"account"][@"displayName"]?:entry[@"name"]?:L(@"unbacked"); }
- (NSString *)saved:(NSDictionary *)entry {
    NSDate *date=entry[@"savedAt"]; if (![date isKindOfClass:NSDate.class]) return @"";
    NSDateFormatter *formatter=[NSDateFormatter new]; formatter.doesRelativeDateFormatting=YES;
    formatter.dateStyle=NSDateFormatterShortStyle; formatter.timeStyle=NSDateFormatterShortStyle; return [formatter stringFromDate:date];
}
- (UIView *)runningIcon {
    UIView *holder=[UIView new];
    [holder.widthAnchor constraintEqualToConstant:48].active=YES;
    [holder.heightAnchor constraintEqualToConstant:48].active=YES;
    UIImageView *icon=[[UIImageView alloc] initWithImage:self.appIcon?:[UIImage systemImageNamed:@"app"]];
    icon.frame=CGRectMake(0,0,48,48); icon.contentMode=UIViewContentModeScaleAspectFit;
    icon.layer.cornerRadius=11; icon.clipsToBounds=YES; [holder addSubview:icon];
    UIView *dot=[[UIView alloc] initWithFrame:CGRectMake(40,-3,11,11)];
    dot.backgroundColor=UIColor.systemGreenColor; dot.layer.cornerRadius=5.5;
    dot.layer.borderWidth=2; dot.layer.borderColor=PanelColor().CGColor;
    dot.hidden=!self.catalogReady || self.restorePending; [holder addSubview:dot];
    return holder;
}
- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol action:(void (^)(void))action {
    UIButtonConfiguration *config=[UIButtonConfiguration plainButtonConfiguration]; config.title=title;
    config.image=[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular]];
    config.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
    config.imagePadding=5; config.titleLineBreakMode=NSLineBreakByTruncatingTail;
    config.baseForegroundColor=Ink(); config.contentInsets=NSDirectionalEdgeInsetsMake(6,2,6,2);
    config.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result=[attributes mutableCopy];
        result[NSFontAttributeName]=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14]];
        return result;
    };
    UIButton *button=[UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *a){(void)a;action();}]];
    button.enabled=!self.busy && self.catalogReady; button.titleLabel.adjustsFontForContentSizeCategory=YES; [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES; return button;
}
- (void)pin:(UIView *)content in:(UIView *)parent inset:(CGFloat)inset {
    content.translatesAutoresizingMaskIntoConstraints=NO; [parent addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [content.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset], [content.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [content.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset]]];
}
- (UITableViewCell *)currentCell {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]; cell.selectionStyle=UITableViewCellSelectionStyleNone;
    PXAppStatePanelSurface *surface=[PXAppStatePanelSurface new]; surface.backgroundColor=UIColor.clearColor;
    surface.contentMode=UIViewContentModeRedraw;
    UIBackgroundConfiguration *background=[UIBackgroundConfiguration clearConfiguration];
    background.cornerRadius=26; background.customView=surface; cell.backgroundConfiguration=background;
    NSDictionary *current=[self current];
    UILabel *name=Label(UIFontTextStyleTitle3,Ink()); name.text=[self name:current];
    if (!current && self.duplicateIdentityReferences.count) name.text=self.appName?:self.bundleID;
    name.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle3] scaledFontForFont:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]];
    UILabel *note=Label(UIFontTextStyleSubheadline,UIColor.secondaryLabelColor); note.text=self.restorePending ? L(@"restore_pending") : (self.duplicateIdentityReferences.count ? L(@"duplicate_short") : (current ? (current[@"account"][@"note"]?:@"") : L(@"unassigned_note")));
    note.hidden=note.text.length==0;
    UILabel *date=Label(UIFontTextStyleCaption1,UIColor.secondaryLabelColor); date.text=[self saved:current]; date.hidden=date.text.length==0;
    UIStackView *identity=Stack(@[name,note,date],UILayoutConstraintAxisVertical,4);
    UIStackView *header=Stack(@[[self runningIcon],identity],UILayoutConstraintAxisHorizontal,14); header.alignment=UIStackViewAlignmentCenter;
    if (UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)) { header.axis=UILayoutConstraintAxisVertical; header.alignment=UIStackViewAlignmentLeading; }
    UIView *line=[UIView new]; line.backgroundColor=[UIColor.separatorColor colorWithAlphaComponent:0.3]; [line.heightAnchor constraintEqualToConstant:0.5].active=YES;
    __weak typeof(self) weakSelf=self;
    UIButton *backup=[self button:L(@"backup") symbol:@"tray.and.arrow.down" action:^{[weakSelf backup];}];
    backup.enabled=backup.enabled && !self.restorePending && !self.duplicateIdentityReferences.count;
    UIButtonConfiguration *backupConfig=backup.configuration; backupConfig.baseForegroundColor=Accent(); backup.configuration=backupConfig;
    BOOL hasBaseline=NO;for(NSDictionary *entry in self.entries)if([entry[@"kind"] isEqual:@"baseline"])hasBaseline=YES;
    UIButton *baseline=[self button:L(hasBaseline?@"baseline":@"create_baseline") symbol:hasBaseline?@"arrow.triangle.2.circlepath":@"plus.circle" action:^{[weakSelf baseline];}];
    UIButton *edit=[self button:L(@"edit") symbol:@"square.and.pencil" action:^{[weakSelf edit:[weakSelf current]];}]; edit.enabled=!self.busy && self.catalogReady && current!=nil;
    UIStackView *actions=Stack(@[backup,baseline,edit],UILayoutConstraintAxisHorizontal,5); actions.distribution=UIStackViewDistributionFillEqually;
    if (UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)) actions.axis=UILayoutConstraintAxisVertical;
    UIStackView *panel=Stack(@[header,line,actions],UILayoutConstraintAxisVertical,6);
    panel.translatesAutoresizingMaskIntoConstraints=NO; [cell.contentView addSubview:panel];
    [panel setCustomSpacing:10 afterView:header];
    [NSLayoutConstraint activateConstraints:@[[panel.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:16],
        [panel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
        [panel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [panel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16]]];
    return cell;
}
- (UITableViewCell *)duplicateCell {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle=UITableViewCellSelectionStyleNone;
    UIBackgroundConfiguration *background=[UIBackgroundConfiguration listGroupedCellConfiguration];
    background.backgroundColor=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle==UIUserInterfaceStyleDark ? [UIColor colorWithRed:0.25 green:0.20 blue:0.12 alpha:1] : [UIColor colorWithRed:1 green:0.96 blue:0.86 alpha:1];
    }]; background.cornerRadius=12; cell.backgroundConfiguration=background;
    UIImageView *warning=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.triangle.fill"]]; warning.tintColor=UIColor.systemOrangeColor; warning.contentMode=UIViewContentModeScaleAspectFit;
    [warning.widthAnchor constraintEqualToConstant:20].active=YES;
    UILabel *title=Label(UIFontTextStyleSubheadline,Ink()); title.text=[NSString stringWithFormat:L(@"duplicate_count"),(unsigned long)self.duplicateIdentityReferences.count];
    UILabel *detail=Label(UIFontTextStyleCaption1,UIColor.secondaryLabelColor); detail.text=L(@"duplicate_help");
    UIStackView *text=Stack(@[title,detail],UILayoutConstraintAxisVertical,3);
    __weak typeof(self) weakSelf=self;
    UIButton *organize=[self button:L(@"organize") symbol:@"chevron.right" action:^{[weakSelf organizeDuplicates];}];
    UIButtonConfiguration *config=organize.configuration; config.baseForegroundColor=Accent(); config.imagePlacement=NSDirectionalRectEdgeTrailing; organize.configuration=config;
    [organize setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row=Stack(@[warning,text,organize],UILayoutConstraintAxisHorizontal,10); row.alignment=UIStackViewAlignmentCenter;
    if (UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)) row.axis=UILayoutConstraintAxisVertical;
    [self pin:row in:cell.contentView inset:12]; return cell;
}
- (void)organizeDuplicates {
    if (self.busy || !self.catalogReady) return;
    NSArray *accounts=[self otherAccounts];
    NSMutableArray *entries=[NSMutableArray array],*names=[NSMutableArray array];
    for(NSDictionary *entry in accounts)if([self.duplicateIdentityReferences containsObject:entry[@"reference"]]) {
        [entries addObject:entry];[names addObject:[NSString stringWithFormat:@"%@ · %@",[self name:entry],[self saved:entry]]];
    }
    __weak typeof(self) weakSelf=self;
    [self presentChoices:names title:L(@"organize") message:L(@"organize_help") selection:^(NSUInteger index){[weakSelf remove:entries[index]];}];
}
- (NSInteger)accountsSection { return self.duplicateIdentityReferences.count?2:1; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return [self accountsSection]+1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section==[self accountsSection]?MAX(1,[self otherAccounts].count):1; }
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;return section==[self accountsSection]?UITableViewAutomaticDimension:8;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;if(section!=[self accountsSection])return [UIView new];
    UIView *header=[UIView new];
    UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.stack.3d.up" ]];
    icon.tintColor=UIColor.secondaryLabelColor;icon.contentMode=UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:16].active=YES;[icon.heightAnchor constraintEqualToConstant:16].active=YES;
    UILabel *title=Label(UIFontTextStyleSubheadline,UIColor.secondaryLabelColor);
    title.text=L(self.currentReference.length?@"other_backups":@"all_backups");
    UIStackView *stack=Stack(@[icon,title],UILayoutConstraintAxisHorizontal,7);stack.alignment=UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints=NO;[header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16]]];return header;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; if (indexPath.section==0) return [self currentCell];
    if (indexPath.section!=[self accountsSection]) return [self duplicateCell];
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]; NSArray *others=[self otherAccounts];
    if (others.count==0) { UILabel *label=Label(UIFontTextStyleSubheadline,UIColor.secondaryLabelColor); label.text=L(@"empty"); [self pin:label in:cell.contentView inset:20]; cell.selectionStyle=UITableViewCellSelectionStyleNone; return cell; }
    NSDictionary *entry=others[indexPath.row]; NSString *name=[self name:entry];
    UILabel *title=Label(UIFontTextStyleHeadline,Ink()); title.text=name;
    title.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]];
    UILabel *detail=Label(UIFontTextStyleSubheadline,UIColor.secondaryLabelColor); NSString *note=entry[@"account"][@"note"]?:@"";
    detail.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11]];
    detail.text=note.length?[NSString stringWithFormat:@"%@ · %@",note,[self saved:entry]]:[self saved:entry];
    BOOL accessibility=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    title.numberOfLines=accessibility?0:1; detail.numberOfLines=accessibility?0:1;
    UIStackView *text=Stack(@[title,detail],UILayoutConstraintAxisVertical,2); __weak typeof(self) weakSelf=self;
    UIButton *switchButton=[self button:nil symbol:@"arrow.left.arrow.right" action:^{[weakSelf switchTo:entry];}];
    switchButton.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",L(@"switch"),name];
    UIButtonConfiguration *config=switchButton.configuration; config.baseForegroundColor=Accent(); switchButton.configuration=config;
    [switchButton.widthAnchor constraintEqualToConstant:44].active=YES;
    [switchButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [switchButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row=Stack(@[text,switchButton],UILayoutConstraintAxisHorizontal,8); row.alignment=UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints=NO; [cell.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[[row.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
        [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]]];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; NSArray *accounts=[self otherAccounts];
    if (!self.busy && self.catalogReady && indexPath.section==[self accountsSection] && (NSUInteger)indexPath.row<accounts.count) [self switchTo:accounts[indexPath.row]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; NSArray *accounts=[self otherAccounts]; if (self.busy || !self.catalogReady || indexPath.section!=[self accountsSection] || (NSUInteger)indexPath.row>=accounts.count) return nil;
    NSDictionary *entry=accounts[indexPath.row]; __weak typeof(self) weakSelf=self;
    UIContextualAction *remove=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:L(@"delete_short") handler:^(UIContextualAction *action,UIView *view,void (^completion)(BOOL)) {
        (void)action;(void)view; completion(NO); [weakSelf remove:entry];
    }]; remove.image=[UIImage systemImageNamed:@"trash"]; remove.backgroundColor=UIColor.systemRedColor;
    UIContextualAction *edit=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:L(@"edit") handler:^(UIContextualAction *action,UIView *view,void (^completion)(BOOL)) {
        (void)action;(void)view; completion(NO); [weakSelf edit:entry];
    }]; edit.image=[UIImage systemImageNamed:@"square.and.pencil"]; edit.backgroundColor=Accent();
    UISwipeActionsConfiguration *config=[UISwipeActionsConfiguration configurationWithActions:@[remove,edit]];
    config.performsFirstActionWithFullSwipe=NO; return config;
}
- (void)updateMenu {
    __weak typeof(self) weakSelf=self;
    UIAction *refresh=[UIAction actionWithTitle:L(@"refresh") image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){(void)a;[weakSelf reload];}];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithPrimaryAction:refresh]; self.navigationItem.rightBarButtonItem.enabled=!self.busy;
}
- (void)message:(NSString *)message title:(NSString *)title {
    if(self.progressModal)return;
    PXAppStateProgressViewController *modal=[[PXAppStateProgressViewController alloc] initWithOperation:@"notice" name:self.appName icon:self.appIcon];
    self.progressModal=modal;__weak typeof(self) weakSelf=self;__weak PXAppStateProgressViewController *weakModal=modal;
    modal.closeHandler=^{[weakSelf dismissViewControllerAnimated:YES completion:^{if(weakSelf.progressModal==weakModal)weakSelf.progressModal=nil;}];};
    [modal configureConfirmationWithTitle:title message:message confirmTitle:L(@"ok") fields:@[] discardTitle:nil handler:^(NSDictionary *values,BOOL discard){(void)values;(void)discard;if(weakModal.closeHandler)weakModal.closeHandler();}];
    [self showProgressModal:modal];
}
- (void)presentChoices:(NSArray *)choices title:(NSString *)title message:(NSString *)message selection:(void (^)(NSUInteger))selection {
    if(self.progressModal)return;
    PXAppStateProgressViewController *modal=[[PXAppStateProgressViewController alloc] initWithOperation:@"choice" name:self.appName icon:self.appIcon];
    self.progressModal=modal;__weak typeof(self) weakSelf=self;__weak PXAppStateProgressViewController *weakModal=modal;
    modal.closeHandler=^{[weakSelf dismissViewControllerAnimated:YES completion:^{if(weakSelf.progressModal==weakModal)weakSelf.progressModal=nil;}];};
    [modal configureChoicesWithTitle:title message:message choices:choices handler:^(NSUInteger index){
        [weakSelf dismissViewControllerAnimated:YES completion:^{if(weakSelf.progressModal==weakModal)weakSelf.progressModal=nil;selection(index);}];
    }];
    [self showProgressModal:modal];
}
- (void)showProgressModal:(PXAppStateProgressViewController *)modal {
    if(self.progressModal!=modal || self.presentedViewController==modal)return;
    if([self.presentedViewController isKindOfClass:UIAlertController.class]) {
        [self dismissViewControllerAnimated:YES completion:^{if(self.progressModal==modal)[self presentViewController:modal animated:YES completion:nil];}];
    } else if(!self.presentedViewController)[self presentViewController:modal animated:YES completion:nil];
}
- (NSString *)progressName:(NSDictionary *)request {
    if([request[@"operation"] isEqual:@"baseline"])return self.appName?:self.bundleID;
    NSString *name=request[@"account"][@"displayName"]?:[self name:[self current]];
    if([request[@"operation"] isEqual:@"switch"])for(NSDictionary *entry in self.entries)if([entry[@"reference"] isEqual:request[@"reference"]])
        name=[NSString stringWithFormat:@"%@ → %@",name,[entry[@"kind"] isEqual:@"baseline"]?L(@"baseline"):[self name:entry]];
    if([@[@"edit",@"delete"] containsObject:request[@"operation"]])for(NSDictionary *entry in self.entries)if([entry[@"reference"] isEqual:request[@"reference"]])name=[self name:entry];
    return name;
}
- (NSArray *)accountFields:(NSDictionary *)entry {
    return @[@{@"key":@"displayName",@"title":L(@"name"),@"value":entry?[self name:entry]:@"",@"required":@YES,@"trim":@YES,@"max":@100},
             @{@"key":@"note",@"title":L(@"note"),@"value":entry[@"account"][@"note"]?:@"",@"max":@1000}];
}
- (void)presentRequest:(NSDictionary *)request title:(NSString *)title message:(NSString *)message confirmTitle:(NSString *)confirmTitle fields:(NSArray *)fields allowDiscard:(BOOL)allowDiscard {
    if(self.busy || !self.catalogReady || self.progressModal)return;
    PXAppStateProgressViewController *modal=[[PXAppStateProgressViewController alloc] initWithOperation:request[@"operation"] name:[self progressName:request] icon:self.appIcon];
    self.progressModal=modal;__weak typeof(self) weakSelf=self;__weak PXAppStateProgressViewController *weakModal=modal;
    modal.closeHandler=^{
        [weakSelf dismissViewControllerAnimated:YES completion:^{if(weakSelf.progressModal==weakModal)weakSelf.progressModal=nil;}];
    };
    [modal configureConfirmationWithTitle:title message:message confirmTitle:confirmTitle fields:fields discardTitle:nil handler:^(NSDictionary *values,BOOL discard) {
        NSMutableDictionary *prepared=[request mutableCopy];
        if(discard){[prepared removeObjectForKey:@"account"];prepared[@"discardCurrent"]=@YES;}
        else if(values.count) {
            NSMutableDictionary *account=[request[@"account"] mutableCopy]?:[NSMutableDictionary dictionary];
            [account addEntriesFromDictionary:values];prepared[@"account"]=account;
        }
        NSString *operation=prepared[@"operation"];
        [weakSelf run:prepared activity:L([operation isEqual:@"switch"]?@"switching":([operation isEqual:@"delete"]?@"deleting":@"saving"))];
    }];
    if(allowDiscard)[modal configureAutomaticBackupOption];
    [self showProgressModal:modal];
}
- (void)run:(NSDictionary *)request activity:(NSString *)activity {
    NSString *operation=request[@"operation"];
    BOOL progressOperation=[@[@"save",@"switch",@"edit",@"delete",@"baseline"] containsObject:operation];
    if (self.busy) return; self.busy=YES; self.activity=activity; self.navigationItem.hidesBackButton=YES; [self updateMenu]; self.table.userInteractionEnabled=NO; [self.table reloadData];
    PXAppStateProgressViewController *modal=nil;
    if(progressOperation) {
        NSString *name=[self progressName:request];
        modal=self.progressModal;
        if(!modal)modal=[[PXAppStateProgressViewController alloc] initWithOperation:operation name:name icon:self.appIcon];
        self.progressModal=modal;[modal beginProgressWithName:name];
        __weak typeof(self) weakSelf=self;
        modal.closeHandler=^{[weakSelf dismissViewControllerAnimated:YES completion:^{weakSelf.progressModal=nil;}];};
        // Let the initiating confirmation alert dismiss, and avoid flashing for fast operations.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            [self showProgressModal:modal];
        });
    }
    if (!self.initialReadFinished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            if (!self.initialReadFinished && self.busy) [self.initialSpinner startAnimating];
        });
    }
    [self.service executeBundle:self.bundleID request:request progress:^(NSDictionary *event){[modal updateProgress:event];} completion:^(NSDictionary *result,NSError *error) {
        self.busy=NO; self.navigationItem.hidesBackButton=NO; self.table.userInteractionEnabled=YES; [self.table.refreshControl endRefreshing];
        self.catalogReady=result!=nil;
        if (result) { self.entries=result[@"entries"]?:@[]; self.currentReference=result[@"currentReference"]?:@""; self.duplicateIdentityReferences=result[@"duplicateIdentityReferences"]?:@[]; self.restorePending=[result[@"restorePending"] boolValue]; }
        else { self.currentReference=@"";NSLog(@"[app-state] operation=%@ error=%@",operation,error.localizedDescription);NSString *message=L(@"operation_failed");
            if ([error.userInfo[@"stateMayBePartial"] boolValue] || [error.userInfo[@"archiveMayBePartial"] boolValue]) message=[message stringByAppendingFormat:@"\n\n%@",L(@"partial")];
            if(modal)[modal finishWithError:message];else [self message:message title:L(@"failed")]; }
        [self updateMenu]; [self.table reloadData];
        self.initialReadFinished=YES; [self.initialSpinner stopAnimating]; self.table.hidden=NO;
        if(result && modal) {
            if(self.presentedViewController==modal) {
                [modal finishWithError:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,400*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                    [self dismissViewControllerAnimated:YES completion:^{self.progressModal=nil;}];
                });
            } else self.progressModal=nil;
        }
        if (result && ![request[@"operation"] isEqual:@"catalog"]) UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,L(@"complete"));
    }];
}
- (void)reload { [self run:@{@"operation":@"catalog"} activity:L(@"loading")]; }
- (void)backup {
    if (self.busy || !self.catalogReady) return;
    [self presentRequest:@{@"operation":@"save"} title:L(@"backup") message:[self current]?L(@"backup_saved"):nil confirmTitle:L(@"backup") fields:[self current]?@[]:[self accountFields:nil] allowDiscard:NO];
}
- (void)edit:(NSDictionary *)entry {
    if(!entry)return;
    [self presentRequest:@{@"operation":@"edit",@"reference":entry[@"reference"]} title:L(@"edit") message:nil confirmTitle:L(@"save") fields:[self accountFields:entry] allowDiscard:NO];
}
- (void)editField:(NSString *)field entry:(NSDictionary *)entry {
    if (self.busy || !self.catalogReady || !entry) return;
    BOOL rename=[field isEqual:@"displayName"];
    NSDictionary *account=@{@"displayName":[self name:entry],@"note":entry[@"account"][@"note"]?:@""};
    NSArray *fields=@[[self accountFields:entry][rename?0:1]];
    [self presentRequest:@{@"operation":@"edit",@"reference":entry[@"reference"],@"account":account} title:L(rename?@"rename":@"note_short") message:nil confirmTitle:L(@"save") fields:fields allowDiscard:NO];
}
- (void)baseline {
    if (self.busy || !self.catalogReady) return;
    NSMutableArray *baselines=[NSMutableArray array]; for (NSDictionary *entry in self.entries) if ([entry[@"kind"] isEqual:@"baseline"]) [baselines addObject:entry];
    if (baselines.count==0) {
        [self presentRequest:@{@"operation":@"baseline"} title:L(@"create_baseline") message:L(@"create_baseline_confirm") confirmTitle:L(@"create_baseline") fields:@[] allowDiscard:NO];return;
    }
    if (baselines.count==1) { [self switchTo:baselines.firstObject]; return; }
    __weak typeof(self) weakSelf=self;
    [self presentChoices:[baselines valueForKey:@"version"] title:L(@"baseline") message:nil selection:^(NSUInteger index){[weakSelf switchTo:baselines[index]];}];
}
- (void)switchTo:(NSDictionary *)entry {
    if (self.busy || !self.catalogReady) return; BOOL baseline=[entry[@"kind"] isEqual:@"baseline"];
    BOOL unassigned=![self current] && !self.restorePending;
    NSMutableDictionary *request=[@{@"operation":@"switch",@"reference":entry[@"reference"]} mutableCopy];
    if(unassigned) {
        NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=@"yyyy-MM-dd HH:mm";
        NSString *app=self.appName.length?self.appName:self.bundleID;
        if(app.length>70)app=[app substringToIndex:70];
        request[@"account"]=@{@"displayName":[NSString stringWithFormat:@"%@ · %@",app,[formatter stringFromDate:NSDate.date]],@"note":@""};
    }
    [self presentRequest:request title:L(baseline?@"baseline":@"switch")
        message:self.restorePending?L(@"restore_pending"):([self current]?L(@"switch_saved"):L(@"switch_unassigned"))
        confirmTitle:L(baseline?@"baseline":@"switch") fields:@[] allowDiscard:!self.restorePending];
}
- (void)remove:(NSDictionary *)entry {
    [self presentRequest:@{@"operation":@"delete",@"reference":entry[@"reference"]} title:L(@"delete") message:L(@"delete_confirm") confirmTitle:L(@"delete_short") fields:@[] allowDiscard:NO];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory]) [self.table reloadData];
}
@end
