#import "PXAppStateProgressViewController.h"
#import "PXLocalizedStrings.h"
#import <QuartzCore/QuartzCore.h>

static NSString *P(NSString *key) { return PXLocalizedString([@"app_state.progress." stringByAppendingString:key]); }
static UIColor *Accent(void) { return UIColor.systemBlueColor; }
static UILabel *Text(CGFloat size,UIFontWeight weight,UIColor *color) {
    UILabel *label=[UILabel new]; label.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory=YES; label.textColor=color; label.numberOfLines=0; return label;
}
@interface PXAppStateProgressViewController ()
@property (nonatomic, copy) NSString *operation;
@property (nonatomic, copy) NSString *backupName;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, strong) UILabel *heading;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *stage;
@property (nonatomic, strong) UILabel *detail;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *segment;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *stepIcons;
@property (nonatomic, strong) NSMutableArray<UILabel *> *stepLabels;
@property (nonatomic, copy) NSDictionary *lastEvent;
@property (nonatomic, copy) NSString *phase;
@property (nonatomic, strong) NSNumber *bytes;
@property (nonatomic, strong) NSNumber *files;
@property (nonatomic, assign) BOOL sawBackup;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) UIView *status;
@property (nonatomic, strong) UIView *timeline;
@property (nonatomic, strong) UIStackView *confirmation;
@property (nonatomic, strong) UIView *confirmationContainer;
@property (nonatomic, copy) NSArray<NSDictionary *> *fields;
@property (nonatomic, strong) NSMutableDictionary<NSString *,UITextField *> *inputs;
@property (nonatomic, strong) UILabel *confirmationError;
@property (nonatomic, copy) NSString *confirmationTitle;
@property (nonatomic, copy) NSString *confirmationActionTitle;
@property (nonatomic, copy) NSString *confirmationMessage;
@property (nonatomic, copy) NSString *discardTitle;
@property (nonatomic, copy) void (^confirmationHandler)(NSDictionary *,BOOL);
@property (nonatomic, assign) BOOL awaitingConfirmation;
@property (nonatomic, copy) NSArray<NSString *> *choices;
@property (nonatomic, copy) void (^choiceHandler)(NSUInteger);
@property (nonatomic, assign) BOOL offersAutomaticBackup;
@property (nonatomic, assign) BOOL automaticBackup;
@property (nonatomic, strong) UIButton *automaticBackupButton;
@property (nonatomic, strong) UILabel *discardWarning;
@end
@implementation PXAppStateProgressViewController
- (instancetype)initWithOperation:(NSString *)operation name:(NSString *)name icon:(UIImage *)icon {
    if((self=[super init])) { _operation=[operation copy];_backupName=[name copy];_icon=icon;self.modalPresentationStyle=UIModalPresentationOverFullScreen;self.modalTransitionStyle=UIModalTransitionStyleCrossDissolve; }
    return self;
}
- (void)configureConfirmationWithTitle:(NSString *)title message:(NSString *)message confirmTitle:(NSString *)confirmTitle fields:(NSArray<NSDictionary *> *)fields discardTitle:(NSString *)discardTitle handler:(void (^)(NSDictionary *,BOOL))handler {
    NSAssert(!self.isViewLoaded,@"Configure confirmation before presentation");
    self.confirmationTitle=title;self.confirmationActionTitle=confirmTitle;self.confirmationMessage=message;self.fields=fields;
    self.discardTitle=discardTitle;self.confirmationHandler=handler;self.awaitingConfirmation=YES;
}
- (UIButton *)confirmationButton:(NSString *)title primary:(BOOL)primary action:(SEL)action {
    UIButtonConfiguration *configuration=primary?[UIButtonConfiguration filledButtonConfiguration]:[UIButtonConfiguration plainButtonConfiguration];
    configuration.title=title;configuration.baseBackgroundColor=Accent();
    configuration.baseForegroundColor=primary?UIColor.whiteColor:Accent();configuration.cornerStyle=UIButtonConfigurationCornerStyleMedium;
    configuration.contentInsets=NSDirectionalEdgeInsetsMake(6,4,6,4);configuration.titleLineBreakMode=NSLineBreakByWordWrapping;
    configuration.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result=[attributes mutableCopy];
        result[NSFontAttributeName]=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]];
        return result;
    };
    UIButton *button=[UIButton buttonWithConfiguration:configuration primaryAction:nil];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)configureAutomaticBackupOption {
    NSAssert(!self.isViewLoaded,@"Configure automatic backup before presentation");
    self.offersAutomaticBackup=YES;self.automaticBackup=YES;
}
- (void)toggleAutomaticBackup {
    if(!self.awaitingConfirmation)return;
    self.automaticBackup=!self.automaticBackup;
    [self updateAutomaticBackupOption];
}
- (void)updateAutomaticBackupOption {
    UIButtonConfiguration *config=self.automaticBackupButton.configuration;
    config.image=[UIImage systemImageNamed:self.automaticBackup?@"checkmark.square.fill":@"square"];
    self.automaticBackupButton.configuration=config;
    self.automaticBackupButton.accessibilityTraits=UIAccessibilityTraitButton | (self.automaticBackup?UIAccessibilityTraitSelected:0);
    self.discardWarning.hidden=self.automaticBackup;
}
- (void)configureChoicesWithTitle:(NSString *)title message:(NSString *)message choices:(NSArray<NSString *> *)choices handler:(void (^)(NSUInteger))handler {
    [self configureConfirmationWithTitle:title message:message confirmTitle:nil fields:@[] discardTitle:nil handler:nil];
    self.choices=choices;self.choiceHandler=handler;
}
- (void)selectChoice:(UIButton *)sender {
    if(!self.awaitingConfirmation)return;self.awaitingConfirmation=NO;
    void (^handler)(NSUInteger)=self.choiceHandler;self.choiceHandler=nil;
    if(handler)handler((NSUInteger)sender.tag);
}
- (void)confirm {
    if(!self.awaitingConfirmation)return;
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for(NSDictionary *field in self.fields) {
        NSString *value=self.inputs[field[@"key"]].text?:@"";
        if([field[@"trim"] boolValue])value=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(([field[@"required"] boolValue] && !value.length) || value.length>[field[@"max"] unsignedIntegerValue]) {
            self.confirmationError.text=PXLocalizedString(@"app_state.invalid_name");self.confirmationError.hidden=NO;return;
        }
        values[field[@"key"]]=value;
    }
    void (^handler)(NSDictionary *,BOOL)=self.confirmationHandler;
    self.awaitingConfirmation=NO;self.confirmationHandler=nil;[self.view endEditing:YES];if(handler)handler(values,self.offersAutomaticBackup && !self.automaticBackup);
}
- (void)discard {
    if(!self.awaitingConfirmation)return;
    void (^handler)(NSDictionary *,BOOL)=self.confirmationHandler;
    self.awaitingConfirmation=NO;self.confirmationHandler=nil;[self.view endEditing:YES];if(handler)handler(nil,YES);
}
- (void)cancelConfirmation {
    if(!self.awaitingConfirmation)return;self.awaitingConfirmation=NO;self.confirmationHandler=nil;self.choiceHandler=nil;
    if(self.closeHandler)self.closeHandler();
}
- (UIView *)wrapper:(UIView *)child {
    UIView *wrapper=[UIView new];wrapper.clipsToBounds=YES;child.translatesAutoresizingMaskIntoConstraints=NO;[wrapper addSubview:child];
    NSLayoutConstraint *bottom=[child.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor];bottom.priority=999;
    [NSLayoutConstraint activateConstraints:@[[child.topAnchor constraintEqualToAnchor:wrapper.topAnchor],bottom,
        [child.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],[child.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor]]];
    return wrapper;
}
- (void)beginProgressWithName:(NSString *)name {
    self.backupName=name;self.awaitingConfirmation=NO;self.confirmationHandler=nil;
    [self loadViewIfNeeded];[self.view endEditing:YES];self.nameLabel.text=name;self.heading.text=P(self.operation);
    self.confirmationContainer.hidden=YES;self.track.hidden=NO;self.status.hidden=NO;
    self.timeline.hidden=![@[@"save",@"switch",@"baseline"] containsObject:self.operation];
    [self.spinner startAnimating];[self.view setNeedsLayout];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.30];
    self.view.accessibilityViewIsModal=YES;
    UIView *panel=[UIView new]; panel.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor; panel.layer.cornerRadius=20; panel.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:panel];
    UIScrollView *scroll=[UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints=NO; [panel addSubview:scroll];
    UIStackView *content=[UIStackView new];content.axis=UILayoutConstraintAxisVertical;content.spacing=16;content.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:content];
    UIImageView *icon=[[UIImageView alloc] initWithImage:self.icon?:[UIImage systemImageNamed:@"app"]];icon.contentMode=UIViewContentModeScaleAspectFit;icon.layer.cornerRadius=8;icon.clipsToBounds=YES;
    [icon.widthAnchor constraintEqualToConstant:32].active=YES;[icon.heightAnchor constraintEqualToConstant:32].active=YES;
    self.heading=Text(17,UIFontWeightSemibold,UIColor.labelColor);self.heading.text=self.awaitingConfirmation?self.confirmationTitle:P(self.operation);
    UILabel *name=Text(12,UIFontWeightRegular,UIColor.secondaryLabelColor);name.text=self.backupName;self.nameLabel=name;
    UIStackView *titles=[[UIStackView alloc] initWithArrangedSubviews:@[self.heading,name]];titles.axis=UILayoutConstraintAxisVertical;titles.spacing=3;
    UIStackView *header=[[UIStackView alloc] initWithArrangedSubviews:@[icon,titles]];header.spacing=10;header.alignment=UIStackViewAlignmentCenter;[content addArrangedSubview:header];
    self.track=[UIView new];self.track.backgroundColor=UIColor.systemGray5Color;self.track.clipsToBounds=YES;self.track.layer.cornerRadius=2;
    NSLayoutConstraint *trackHeight=[self.track.heightAnchor constraintEqualToConstant:4];trackHeight.priority=999;trackHeight.active=YES;
    self.segment=[UIView new];self.segment.backgroundColor=Accent();[self.track addSubview:self.segment];[content addArrangedSubview:self.track];
    self.stage=Text(15,UIFontWeightMedium,UIColor.labelColor);self.stage.text=P(@"stage.prepare");
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.color=Accent();[self.spinner startAnimating];
    UIStackView *stageLine=[[UIStackView alloc] initWithArrangedSubviews:@[self.stage,self.spinner]];stageLine.spacing=8;stageLine.alignment=UIStackViewAlignmentCenter;
    self.detail=Text(12,UIFontWeightRegular,UIColor.secondaryLabelColor);self.detail.hidden=YES;
    UIStackView *status=[[UIStackView alloc] initWithArrangedSubviews:@[stageLine,self.detail]];status.axis=UILayoutConstraintAxisVertical;status.spacing=4;
    self.status=[self wrapper:status];[content addArrangedSubview:self.status];
    BOOL switching=[self.operation isEqual:@"switch"];
    NSArray *steps=switching?@[@"prepare",@"save_current",@"restore_target",@"verify_restore",@"complete"]:@[@"prepare",[self.operation isEqual:@"baseline"]?@"create_baseline":@"save_data",@"verify_backup",@"complete"];
    self.stepIcons=[NSMutableArray array];self.stepLabels=[NSMutableArray array];
    UIStackView *timeline=[UIStackView new];timeline.axis=UILayoutConstraintAxisVertical;timeline.spacing=10;
    for(NSString *step in steps) {
        UIImageView *mark=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle"]];mark.contentMode=UIViewContentModeScaleAspectFit;
        [mark.widthAnchor constraintEqualToConstant:18].active=YES;[mark.heightAnchor constraintEqualToConstant:18].active=YES;
        UILabel *label=Text(13,UIFontWeightRegular,UIColor.secondaryLabelColor);label.text=P(step);
        UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[mark,label]];row.spacing=10;row.alignment=UIStackViewAlignmentCenter;[timeline addArrangedSubview:row];
        [self.stepIcons addObject:mark];[self.stepLabels addObject:label];
    }
    self.timeline=[self wrapper:timeline];[content addArrangedSubview:self.timeline];
    self.confirmation=[UIStackView new];self.confirmation.axis=UILayoutConstraintAxisVertical;self.confirmation.spacing=12;
    UILabel *message=Text(14,UIFontWeightRegular,UIColor.secondaryLabelColor);message.text=self.confirmationMessage;
    message.hidden=!message.text.length;[self.confirmation addArrangedSubview:message];
    if(self.offersAutomaticBackup) {
        UIButton *option=[self confirmationButton:PXLocalizedString(@"app_state.auto_backup") primary:NO action:@selector(toggleAutomaticBackup)];
        UIButtonConfiguration *config=option.configuration;config.imagePadding=8;config.contentInsets=NSDirectionalEdgeInsetsMake(6,0,6,0);
        option.configuration=config;option.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
        self.automaticBackupButton=option;[self.confirmation addArrangedSubview:option];
        self.discardWarning=Text(12,UIFontWeightRegular,UIColor.systemRedColor);
        self.discardWarning.text=PXLocalizedString(@"app_state.auto_backup_disabled");
        [self.confirmation addArrangedSubview:self.discardWarning];[self updateAutomaticBackupOption];
    }
    self.inputs=[NSMutableDictionary dictionary];
    for(NSDictionary *spec in self.fields) {
            UITextField *field=[UITextField new];field.placeholder=spec[@"title"];field.text=spec[@"value"];field.accessibilityLabel=field.placeholder;
            field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];field.adjustsFontForContentSizeCategory=YES;
            field.borderStyle=UITextBorderStyleRoundedRect;field.autocapitalizationType=UITextAutocapitalizationTypeNone;
            [field.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;[self.confirmation addArrangedSubview:field];
            self.inputs[spec[@"key"]]=field;
    }
    self.confirmationError=Text(12,UIFontWeightRegular,UIColor.systemRedColor);self.confirmationError.hidden=YES;[self.confirmation addArrangedSubview:self.confirmationError];
    if(self.choices) {
        for(NSUInteger i=0;i<self.choices.count;i++) {
            UIButton *choice=[self confirmationButton:self.choices[i] primary:NO action:@selector(selectChoice:)];choice.tag=(NSInteger)i;
            choice.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;[self.confirmation addArrangedSubview:choice];
        }
        [self.confirmation addArrangedSubview:[self confirmationButton:PXLocalizedString(@"app_state.cancel") primary:NO action:@selector(cancelConfirmation)]];
    } else {
        UIButton *submit=[self confirmationButton:self.confirmationActionTitle primary:YES action:@selector(confirm)];
        if([self.operation isEqual:@"delete"]) {
            UIButtonConfiguration *config=submit.configuration;config.baseBackgroundColor=UIColor.systemRedColor;submit.configuration=config;
        }
        NSMutableArray<UIView *> *buttons=[NSMutableArray array];
        if(![self.operation isEqual:@"notice"])[buttons addObject:[self confirmationButton:PXLocalizedString(@"app_state.cancel") primary:NO action:@selector(cancelConfirmation)]];
        if(self.discardTitle.length) {
            UIButton *discard=[self confirmationButton:self.discardTitle primary:NO action:@selector(discard)];
            UIButtonConfiguration *config=discard.configuration;config.baseForegroundColor=UIColor.systemRedColor;discard.configuration=config;[buttons addObject:discard];
        }
        [buttons addObject:submit];
        UIStackView *actions=[[UIStackView alloc] initWithArrangedSubviews:buttons];actions.spacing=8;actions.distribution=UIStackViewDistributionFillEqually;
        if(UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory))actions.axis=UILayoutConstraintAxisVertical;
        [self.confirmation addArrangedSubview:actions];
    }
    self.confirmationContainer=[self wrapper:self.confirmation];[content addArrangedSubview:self.confirmationContainer];self.confirmationContainer.hidden=!self.awaitingConfirmation;
    self.track.hidden=self.awaitingConfirmation;self.status.hidden=self.awaitingConfirmation;
    self.timeline.hidden=self.awaitingConfirmation || ![@[@"save",@"switch",@"baseline"] containsObject:self.operation];
    if(self.awaitingConfirmation)[self.spinner stopAnimating];
    self.closeButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.closeButton setTitle:PXLocalizedString(@"app_state.ok") forState:UIControlStateNormal];
    NSLayoutConstraint *closeHeight=[self.closeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44];closeHeight.priority=999;closeHeight.active=YES;
    [self.closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];self.closeButton.hidden=YES;[content addArrangedSubview:self.closeButton];
    NSLayoutConstraint *width=[panel.widthAnchor constraintEqualToConstant:320];width.priority=UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *fit=[scroll.heightAnchor constraintEqualToAnchor:content.heightAnchor constant:40];fit.priority=UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *center=[panel.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor];center.priority=UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[width,fit,
        [panel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],center,
        [panel.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48],
        [panel.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [panel.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [panel.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-16],
        [scroll.topAnchor constraintEqualToAnchor:panel.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],[content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    [self updateProgress:self.lastEvent?:@{@"phase":@"prepare",@"stage":@"prepare"}];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGFloat width=CGRectGetWidth(self.track.bounds);
    self.segment.frame=CGRectMake(0,0,self.finished?width:width*0.28,4);
    if(!self.finished && !self.awaitingConfirmation && ![self.segment.layer animationForKey:@"indeterminate"] && width>0) {
        CABasicAnimation *move=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];move.fromValue=@(-width*0.28);move.toValue=@(width);move.duration=1.3;move.repeatCount=HUGE_VALF;[self.segment.layer addAnimation:move forKey:@"indeterminate"];
    }
}
- (void)updateProgress:(NSDictionary *)event {
    if(self.finished)return;self.lastEvent=event;if(!self.isViewLoaded)return;
    NSString *phase=event[@"phase"],*stage=event[@"stage"];
    if(![phase isEqual:self.phase]){self.phase=phase;self.bytes=nil;self.files=nil;}
    if([event[@"bytes"] isKindOfClass:NSNumber.class])self.bytes=event[@"bytes"];
    if([event[@"files"] isKindOfClass:NSNumber.class])self.files=event[@"files"];
    NSArray *visibleStages=@[@"prepare",@"preflight",@"copy",@"clear",@"keychain",@"identity",@"verify_files",@"verify_keychain",@"verify_identity",@"verify_preferences",@"publish"];
    NSString *displayStage=[visibleStages containsObject:stage?:@""]?stage:@"prepare";
    if([displayStage isEqual:@"copy"] && [phase isEqual:@"restore"])displayStage=@"restore_data";
    self.stage.text=P([@"stage." stringByAppendingString:displayStage]);
    if([self.operation isEqual:@"baseline"] && [displayStage isEqual:@"copy"])self.stage.text=P(@"create_baseline");
    if(![@[@"save",@"switch",@"baseline"] containsObject:self.operation])self.stage.text=P(self.operation);
    if([event[@"records"] isKindOfClass:NSNumber.class])self.detail.text=[NSString stringWithFormat:P(@"records"),(unsigned long)[event[@"records"] unsignedIntegerValue]];
    else if(self.bytes)self.detail.text=[NSString stringWithFormat:P(@"counts"),[NSByteCountFormatter stringFromByteCount:self.bytes.longLongValue countStyle:NSByteCountFormatterCountStyleFile],(unsigned long)self.files.unsignedIntegerValue];
    else self.detail.text=@"";
    self.detail.hidden=self.detail.text.length==0;
    BOOL switching=[self.operation isEqual:@"switch"],backup=[phase isEqual:@"backup"] || [phase isEqual:@"baseline"],restore=[phase isEqual:@"restore"];
    if([event[@"savedCurrent"] isKindOfClass:NSNumber.class])self.sawBackup=[event[@"savedCurrent"] boolValue];
    else if(backup)self.sawBackup=YES;
    NSUInteger current=0;
    if(switching) {
        if(backup)current=1;
        if(restore)current=[@[@"verify_files",@"identity",@"verify_identity",@"verify_keychain",@"verify_preferences"] containsObject:stage]?3:2;
        if(restore)self.stepLabels[1].text=P(self.sawBackup?@"save_current":@"skip_save");
    } else if(backup)current=[@[@"verify_files",@"verify_keychain",@"publish"] containsObject:stage]?2:1;
    for(NSUInteger i=0;i<self.stepIcons.count;i++) {
        BOOL skipped=switching && restore && i==1 && !self.sawBackup;
        self.stepIcons[i].image=[UIImage systemImageNamed:skipped?@"minus.circle":(i<current?@"checkmark.circle.fill":(i==current?@"circle.inset.filled":@"circle"))];
        self.stepIcons[i].tintColor=skipped?UIColor.tertiaryLabelColor:(i<current?UIColor.systemGreenColor:(i==current?Accent():UIColor.tertiaryLabelColor));
        self.stepLabels[i].textColor=i==current?UIColor.labelColor:UIColor.secondaryLabelColor;
    }
}
- (void)finishWithError:(NSString *)message {
    [self loadViewIfNeeded];self.finished=YES;[self.spinner stopAnimating];[self.segment.layer removeAllAnimations];
    if(message.length) {
        self.heading.text=P(@"failed");self.detail.text=message;self.detail.hidden=NO;self.detail.textColor=UIColor.systemRedColor;
        self.closeButton.hidden=NO;self.segment.hidden=YES;
    } else {
        self.heading.text=P(@"complete");self.stage.text=[@[@"save",@"switch",@"baseline"] containsObject:self.operation]?P(@"verified"):PXLocalizedString(@"app_state.complete");
        for(NSUInteger i=0;i<self.stepIcons.count;i++) {
            if([self.stepLabels[i].text isEqual:P(@"skip_save")])continue;
            self.stepIcons[i].image=[UIImage systemImageNamed:@"checkmark.circle.fill"];self.stepIcons[i].tintColor=UIColor.systemGreenColor;
        }
    }
    [self.view setNeedsLayout];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,self.heading.text);
}
- (void)close { if(self.finished && self.closeHandler)self.closeHandler(); }
@end
