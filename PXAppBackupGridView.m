#import "PXAppBackupGridView.h"
#import "PXLocalizedStrings.h"

static UIImage *ApplicationIcon(NSURL *bundleURL) {
    if (!bundleURL) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[bundleURL URLByAppendingPathComponent:@"Info.plist"]];
    NSDictionary *primary = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
    NSArray *names = primary[@"CFBundleIconFiles"] ?: info[@"CFBundleIconFiles"];
    NSString *name = [names isKindOfClass:NSArray.class] ? names.lastObject : nil;
    if ([name isKindOfClass:NSString.class]) {
        for (NSString *suffix in @[@"", @".png", @"@3x.png", @"@2x.png"]) {
            UIImage *image = [UIImage imageWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:[name stringByAppendingString:suffix]]];
            if (image) return image;
        }
    }
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundleURL.path error:nil]) {
        if ([file.pathExtension.lowercaseString isEqual:@"png"] && [file.lowercaseString containsString:@"icon"]) {
            UIImage *image = [UIImage imageWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:file]];
            if (image) return image;
        }
    }
    return nil;
}

@implementation PXAppBackupGridView
- (instancetype)initWithApplications:(NSArray<NSDictionary *> *)applications
                          openHandler:(void (^)(NSDictionary *))openHandler {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.axis = UILayoutConstraintAxisVertical;
    self.spacing = 8;
    if (!applications.count) {
        UILabel *empty = [UILabel new];
        empty.text = PXLocalizedString(@"app_state.home.empty");
        empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        empty.adjustsFontForContentSizeCategory = YES;
        empty.textColor = UIColor.secondaryLabelColor;
        empty.numberOfLines = 0;
        [self addArrangedSubview:empty];
    }
    const NSUInteger columns = 4;
    for (NSUInteger start = 0; start < applications.count; start += columns) {
        UIStackView *row = [UIStackView new];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
        for (NSUInteger column = 0; column < columns; column++) {
            NSUInteger index = start + column;
            if (index >= applications.count) { [row addArrangedSubview:[UIView new]]; continue; }
            NSDictionary *application = applications[index];
            NSString *bundleID = application[@"bundleIdentifier"];
            NSString *name = application[@"displayName"];
            BOOL available = [application[@"available"] boolValue];
            UIImage *icon = application[@"icon"] ?: ApplicationIcon(application[@"bundleURL"]);
            UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
            card.backgroundColor = UIColor.clearColor;
            card.enabled = available;
            card.alpha = available ? 1 : .45;
            card.accessibilityIdentifier = [@"app-backup-grid-" stringByAppendingString:bundleID];
            card.accessibilityLabel = name;
            card.accessibilityHint = PXLocalizedString(available ? @"app_state.home.open" : @"app_state.home.unavailable");
            UIImageView *imageView = [[UIImageView alloc] initWithImage:icon ?: [UIImage systemImageNamed:@"app.fill"]];
            imageView.translatesAutoresizingMaskIntoConstraints = NO;
            imageView.contentMode = UIViewContentModeScaleAspectFit;
            imageView.layer.cornerRadius = 11;
            imageView.clipsToBounds = YES;
            imageView.tintColor = UIColor.systemBlueColor;
            UILabel *label = [UILabel new];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.text = name;
            label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
            label.adjustsFontForContentSizeCategory = YES;
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 2;
            [card addSubview:imageView];
            [card addSubview:label];
            [NSLayoutConstraint activateConstraints:@[
                [imageView.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
                [imageView.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [imageView.widthAnchor constraintEqualToConstant:48],
                [imageView.heightAnchor constraintEqualToConstant:48],
                [label.topAnchor constraintEqualToAnchor:imageView.bottomAnchor constant:7],
                [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:2],
                [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-2],
                [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
            ]];
            [card addAction:[UIAction actionWithHandler:^(UIAction *action) {
                (void)action;
                NSMutableDictionary *selected = [application mutableCopy];
                if (icon) selected[@"icon"] = icon;
                openHandler(selected);
            }] forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:card];
        }
        [self addArrangedSubview:row];
    }
    return self;
}
@end
