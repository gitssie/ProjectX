#import "PXSmartLocationViewController.h"

#import "NetworkIdentity.h"
#import "PXEnvironmentPolicy.h"
#import "PXGeoIPLocation.h"
#import "PXLocalizedStrings.h"
#import "PXRootHidePath.h"
#import "TrustedCarrierPolicy.h"

@interface PXSmartLocationViewController ()
@property (nonatomic, weak) id callbackTarget;
@property (nonatomic, assign) SEL callbackSelector;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *sectionLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *addressLabel;
@property (nonatomic, strong) UILabel *regionLabel;
@property (nonatomic, strong) UILabel *ipv4ValueLabel;
@property (nonatomic, strong) UILabel *ipv6ValueLabel;
@property (nonatomic, strong) UILabel *timeZoneValueLabel;
@property (nonatomic, strong) UILabel *coordinatesValueLabel;
@property (nonatomic, strong) UILabel *ipv4TitleLabel;
@property (nonatomic, strong) UILabel *ipv6TitleLabel;
@property (nonatomic, strong) UILabel *timeZoneTitleLabel;
@property (nonatomic, strong) UILabel *coordinatesTitleLabel;
@property (nonatomic, strong) UIStackView *informationStack;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UILabel *mismatchLabel;
@property (nonatomic, strong) UIView *mismatchRow;
@property (nonatomic, strong) UIView *clearSeparator;
@property (nonatomic, strong) UIStackView *actionStack;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UIButton *clearLocationButton;
@property (nonatomic, strong) UIButton *useLocationButton;
@property (nonatomic, strong) PXGeoIPLocationService *locationService;
@property (nonatomic, strong) NSURLSessionDataTask *activeRequest;
@property (nonatomic, copy) NSArray<NSURLSessionDataTask *> *activeAddressRequests;
@property (nonatomic, strong, nullable) PXGeoIPLocation *displayedLocation;
@property (nonatomic, strong, nullable) PXGeoIPLocation *savedGeoIPLocation;
@property (nonatomic, strong, nullable) PXGeoIPLocation *pendingLocation;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *selectedLocationPolicy;
@property (nonatomic, assign) BOOL pendingClear;
@property (nonatomic, copy, nullable) NSString *detectedIPv4Address;
@property (nonatomic, copy, nullable) NSString *detectedIPv6Address;
@property (nonatomic, copy, nullable) NSString *legacyLocationAddress;
@property (nonatomic, strong) PXEnvironmentPolicyStore *environmentPolicyStore;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL requestFailed;
@property (nonatomic, assign) BOOL hasStoredLocationConfiguration;
@property (nonatomic, assign) BOOL currentDetectionSucceeded;
@property (nonatomic, assign) BOOL hasAttemptedDetection;
@property (nonatomic, assign) BOOL geoRequestCompleted;
@property (nonatomic, assign) BOOL ipv4RequestCompleted;
@property (nonatomic, assign) BOOL ipv6RequestCompleted;
@property (nonatomic, assign) NSUInteger requestRevision;
@end

@implementation PXSmartLocationViewController

- (instancetype)initWithLocationCommittedHandler:(SEL)handler target:(id)target {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _callbackSelector = handler;
        _callbackTarget = target;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.environmentPolicyStore = [PXEnvironmentPolicyStore sharedStore];
    self.locationService = [[PXGeoIPLocationService alloc] init];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:PXLocalizedString(@"image.network.confirm.title")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(handleConfirmTapped:)];
    [self updateConfirmButtonState];
    [self buildLocationInterface];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLanguagePreferenceChanged:)
                                                 name:PXUILanguagePreferenceDidChangeNotification
                                               object:nil];
    [self restoreConfiguredLocation];
    [self refreshLocalizedContent];
}

- (void)dealloc {
    [self.activeRequest cancel];
    for (NSURLSessionDataTask *task in self.activeAddressRequests) [task cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:PXUILanguagePreferenceDidChangeNotification
                                                  object:nil];
}

- (UILabel *)labelWithTextStyle:(UIFontTextStyle)style color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIView *)dividerView {
    UIView *divider = [[UIView alloc] init];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = UIColor.separatorColor;
    [divider.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return divider;
}

- (UIStackView *)detailRowWithTitleLabel:(UILabel *)titleLabel valueLabel:(UILabel *)valueLabel {
    [titleLabel setContentHuggingPriority:UILayoutPriorityRequired
                                 forAxis:UILayoutConstraintAxisHorizontal];
    valueLabel.textAlignment = NSTextAlignmentRight;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, valueLabel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    return row;
}

- (void)buildLocationInterface {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    UIStackView *pageStack = [[UIStackView alloc] init];
    pageStack.translatesAutoresizingMaskIntoConstraints = NO;
    pageStack.axis = UILayoutConstraintAxisVertical;
    pageStack.spacing = 10.0;
    [scrollView addSubview:pageStack];

    self.sectionLabel = [self labelWithTextStyle:UIFontTextStyleFootnote
                                             color:UIColor.secondaryLabelColor];
    [pageStack addArrangedSubview:self.sectionLabel];

    UIView *resultCard = [[UIView alloc] init];
    resultCard.translatesAutoresizingMaskIntoConstraints = NO;
    resultCard.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    resultCard.layer.cornerRadius = 14.0;
    resultCard.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    resultCard.layer.borderColor = UIColor.separatorColor.CGColor;
    resultCard.layer.masksToBounds = YES;
    [pageStack addArrangedSubview:resultCard];

    UIStackView *cardStack = [[UIStackView alloc] init];
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 10.0;
    [resultCard addSubview:cardStack];

    self.statusDot = [[UIView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 6.0;
    self.statusDot.isAccessibilityElement = NO;
    [self.statusDot.widthAnchor constraintEqualToConstant:12.0].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:12.0].active = YES;

    self.statusLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline
                                          color:UIColor.secondaryLabelColor];
    self.statusLabel.accessibilityIdentifier = @"image-location-geo-status";
    UIStackView *statusRow = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.statusDot, self.statusLabel]];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.alignment = UIStackViewAlignmentCenter;
    statusRow.spacing = 8.0;
    [cardStack addArrangedSubview:statusRow];
    [cardStack setCustomSpacing:16.0 afterView:statusRow];

    self.addressLabel = [self labelWithTextStyle:UIFontTextStyleTitle1 color:UIColor.labelColor];
    self.addressLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1]
        scaledFontForFont:[UIFont systemFontOfSize:28.0 weight:UIFontWeightBold]];
    self.addressLabel.accessibilityIdentifier = @"image-location-geo-address";
    [cardStack addArrangedSubview:self.addressLabel];
    [cardStack setCustomSpacing:2.0 afterView:self.addressLabel];

    self.regionLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline
                                          color:UIColor.secondaryLabelColor];
    [cardStack addArrangedSubview:self.regionLabel];
    [cardStack setCustomSpacing:16.0 afterView:self.regionLabel];

    [cardStack addArrangedSubview:[self dividerView]];

    self.ipv4ValueLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline
                                               color:UIColor.secondaryLabelColor];
    self.ipv6ValueLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline
                                               color:UIColor.secondaryLabelColor];
    self.timeZoneValueLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline
                                                   color:UIColor.secondaryLabelColor];
    self.coordinatesValueLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline
                                                      color:UIColor.secondaryLabelColor];
    self.ipv4TitleLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline color:UIColor.labelColor];
    self.ipv6TitleLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline color:UIColor.labelColor];
    self.timeZoneTitleLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline color:UIColor.labelColor];
    self.coordinatesTitleLabel = [self labelWithTextStyle:UIFontTextStyleSubheadline color:UIColor.labelColor];
    self.informationStack = [[UIStackView alloc] init];
    self.informationStack.axis = UILayoutConstraintAxisVertical;
    self.informationStack.spacing = 0.0;
    [self.informationStack addArrangedSubview:[self detailRowWithTitleLabel:self.ipv4TitleLabel
                                                                valueLabel:self.ipv4ValueLabel]];
    [self.informationStack addArrangedSubview:[self dividerView]];
    [self.informationStack addArrangedSubview:[self detailRowWithTitleLabel:self.ipv6TitleLabel
                                                                valueLabel:self.ipv6ValueLabel]];
    [self.informationStack addArrangedSubview:[self dividerView]];
    [self.informationStack addArrangedSubview:[self detailRowWithTitleLabel:self.timeZoneTitleLabel
                                                               valueLabel:self.timeZoneValueLabel]];
    [self.informationStack addArrangedSubview:[self dividerView]];
    [self.informationStack addArrangedSubview:[self detailRowWithTitleLabel:self.coordinatesTitleLabel
                                                               valueLabel:self.coordinatesValueLabel]];
    [cardStack addArrangedSubview:self.informationStack];

    self.sourceLabel = [self labelWithTextStyle:UIFontTextStyleFootnote
                                          color:UIColor.tertiaryLabelColor];
    [cardStack addArrangedSubview:self.sourceLabel];
    [cardStack setCustomSpacing:16.0 afterView:self.sourceLabel];

    [cardStack addArrangedSubview:[self dividerView]];

    self.mismatchLabel = [self labelWithTextStyle:UIFontTextStyleFootnote
                                            color:UIColor.systemOrangeColor];
    self.mismatchLabel.accessibilityTraits = UIAccessibilityTraitStaticText;
    UIImageView *warningImage = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"exclamationmark.circle"]];
    warningImage.tintColor = UIColor.systemOrangeColor;
    warningImage.isAccessibilityElement = NO;
    [warningImage setContentHuggingPriority:UILayoutPriorityRequired
                                   forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *mismatchRow = [[UIStackView alloc]
        initWithArrangedSubviews:@[warningImage, self.mismatchLabel]];
    mismatchRow.axis = UILayoutConstraintAxisHorizontal;
    mismatchRow.alignment = UIStackViewAlignmentCenter;
    mismatchRow.spacing = 8.0;
    mismatchRow.hidden = YES;
    self.mismatchRow = mismatchRow;
    [cardStack addArrangedSubview:mismatchRow];
    [cardStack setCustomSpacing:12.0 afterView:mismatchRow];

    UIButton *refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    refreshButton.accessibilityIdentifier = @"image-location-geo-refresh";
    [refreshButton addTarget:self action:@selector(handleRefreshTapped:)
            forControlEvents:UIControlEventTouchUpInside];
    self.refreshButton = refreshButton;

    UIButton *useLocationButton = [UIButton buttonWithType:UIButtonTypeSystem];
    useLocationButton.translatesAutoresizingMaskIntoConstraints = NO;
    useLocationButton.accessibilityIdentifier = @"image-location-use";
    [useLocationButton addTarget:self action:@selector(handleUseLocationTapped:)
                forControlEvents:UIControlEventTouchUpInside];
    self.useLocationButton = useLocationButton;

    self.actionStack = [[UIStackView alloc]
        initWithArrangedSubviews:@[refreshButton, useLocationButton]];
    self.actionStack.axis = UILayoutConstraintAxisHorizontal;
    self.actionStack.alignment = UIStackViewAlignmentFill;
    self.actionStack.spacing = 8.0;
    [refreshButton setContentHuggingPriority:UILayoutPriorityRequired
                                    forAxis:UILayoutConstraintAxisHorizontal];
    [cardStack addArrangedSubview:self.actionStack];
    [cardStack setCustomSpacing:16.0 afterView:self.actionStack];

    self.clearSeparator = [self dividerView];
    [cardStack addArrangedSubview:self.clearSeparator];

    UIButton *clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    clearButton.accessibilityIdentifier = @"image-location-clear-saved";
    [clearButton addTarget:self action:@selector(handleClearLocationTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    self.clearLocationButton = clearButton;
    [cardStack addArrangedSubview:clearButton];
    [self updateActionLayout];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [pageStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:18.0],
        [pageStack.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:20.0],
        [pageStack.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-20.0],
        [pageStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-20.0],
        [cardStack.topAnchor constraintEqualToAnchor:resultCard.topAnchor constant:18.0],
        [cardStack.leadingAnchor constraintEqualToAnchor:resultCard.leadingAnchor constant:18.0],
        [cardStack.trailingAnchor constraintEqualToAnchor:resultCard.trailingAnchor constant:-18.0],
        [cardStack.bottomAnchor constraintEqualToAnchor:resultCard.bottomAnchor constant:-12.0],
        [refreshButton.heightAnchor constraintGreaterThanOrEqualToConstant:48.0],
        [useLocationButton.heightAnchor constraintGreaterThanOrEqualToConstant:48.0],
        [clearButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0]
    ]];
}

- (void)updateActionLayout {
    CGFloat bodyPointSize = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledValueForValue:17.0 compatibleWithTraitCollection:self.traitCollection];
    self.actionStack.axis = (self.view.bounds.size.width < 390.0 || bodyPointSize > 19.0)
        ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateActionLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (![previousTraitCollection.preferredContentSizeCategory
          isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self updateActionLayout];
    }
}

- (void)handleLanguagePreferenceChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshLocalizedContent];
    if (self.view.window) UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.view);
}

- (void)refreshLocalizedContent {
    self.title = PXLocalizedString(@"image.location.title");
    self.navigationItem.rightBarButtonItem.title = PXLocalizedString(@"image.network.confirm.title");
    self.sectionLabel.text = PXLocalizedString(@"image.location.geo_ip.section");
    self.ipv4TitleLabel.text = PXLocalizedString(@"image.location.geo_ip.ipv4.label");
    self.ipv6TitleLabel.text = PXLocalizedString(@"image.location.geo_ip.ipv6.label");
    self.timeZoneTitleLabel.text = PXLocalizedString(@"image.location.geo_ip.time_zone.label");
    self.coordinatesTitleLabel.text = PXLocalizedString(@"image.location.geo_ip.coordinates.label");
    self.mismatchLabel.text = PXLocalizedString(@"image.location.mismatch.warning");

    UIButtonConfiguration *refreshConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    refreshConfiguration.title = PXLocalizedString(self.loading
        ? @"image.location.geo_ip.detecting"
        : (self.hasAttemptedDetection
            ? @"image.location.geo_ip.refresh" : @"image.location.geo_ip.detect"));
    refreshConfiguration.image = self.loading ? nil : [UIImage systemImageNamed:@"arrow.clockwise"];
    refreshConfiguration.imagePadding = 8.0;
    refreshConfiguration.showsActivityIndicator = self.loading;
    refreshConfiguration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    refreshConfiguration.baseForegroundColor = UIColor.systemBlueColor;
    self.refreshButton.configuration = refreshConfiguration;
    self.refreshButton.enabled = !self.loading;
    self.refreshButton.accessibilityLabel = PXLocalizedString(self.hasAttemptedDetection
        ? @"image.location.geo_ip.refresh.accessibility_label"
        : @"image.location.geo_ip.detect.accessibility_label");
    self.refreshButton.accessibilityHint = PXLocalizedString(@"image.location.geo_ip.refresh.accessibility_hint");

    UIButtonConfiguration *clearConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    clearConfiguration.title = PXLocalizedString(@"image.location.clear.title");
    clearConfiguration.image = [UIImage systemImageNamed:@"trash"];
    clearConfiguration.imagePadding = 8.0;
    clearConfiguration.baseForegroundColor = UIColor.systemRedColor;
    clearConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(8.0, 4.0, 8.0, 4.0);
    self.clearLocationButton.configuration = clearConfiguration;
    self.clearLocationButton.hidden = !self.hasStoredLocationConfiguration;
    self.clearSeparator.hidden = !self.hasStoredLocationConfiguration;
    self.clearLocationButton.accessibilityLabel = PXLocalizedString(@"image.location.clear.accessibility_label");
    self.clearLocationButton.accessibilityHint = PXLocalizedString(@"image.location.clear.accessibility_hint");

    UIButtonConfiguration *useConfiguration = [UIButtonConfiguration filledButtonConfiguration];
    useConfiguration.title = PXLocalizedString(self.selectedLocationPolicy
        ? @"image.location.selected.title" : @"image.location.use.title");
    useConfiguration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    useConfiguration.baseBackgroundColor = UIColor.systemBlueColor;
    useConfiguration.baseForegroundColor = UIColor.whiteColor;
    self.useLocationButton.configuration = useConfiguration;
    self.useLocationButton.enabled = self.displayedLocation != nil &&
        self.currentDetectionSucceeded && !self.loading;
    self.useLocationButton.accessibilityLabel = PXLocalizedString(@"image.location.use.accessibility_label");
    self.useLocationButton.accessibilityHint = PXLocalizedString(@"image.location.use.accessibility_hint");
    [self updateConfirmButtonState];
    [self renderLocationState];
}

- (void)updateConfirmButtonState {
    self.navigationItem.rightBarButtonItem.enabled = self.pendingClear || self.selectedLocationPolicy != nil;
}

- (void)renderLocationState {
    if (self.loading) {
        self.statusLabel.text = PXLocalizedString(@"image.location.geo_ip.status.detecting");
        self.statusDot.backgroundColor = UIColor.systemBlueColor;
    } else if (self.requestFailed) {
        self.statusLabel.text = PXLocalizedString(@"image.location.geo_ip.status.failed");
        self.statusDot.backgroundColor = UIColor.systemOrangeColor;
    } else if (self.displayedLocation) {
        self.statusLabel.text = PXLocalizedString(@"image.location.geo_ip.status.ready");
        self.statusDot.backgroundColor = UIColor.systemGreenColor;
    } else if (self.savedGeoIPLocation || self.legacyLocationAddress.length > 0) {
        self.statusLabel.text = PXLocalizedString(@"image.location.geo_ip.status.saved");
        self.statusDot.backgroundColor = UIColor.systemBlueColor;
    } else {
        self.statusLabel.text = PXLocalizedString(@"image.location.geo_ip.status.waiting");
        self.statusDot.backgroundColor = UIColor.systemGrayColor;
    }

    self.ipv4ValueLabel.text = self.displayedLocation
        ? (self.detectedIPv4Address ?: @"")
        : (self.savedGeoIPLocation.ipv4Address ?: @"");
    self.ipv6ValueLabel.text = self.displayedLocation
        ? (self.detectedIPv6Address ?: @"")
        : (self.savedGeoIPLocation.ipv6Address ?: @"");
    PXGeoIPLocation *location = self.displayedLocation ?: self.savedGeoIPLocation;
    if (!location) {
        self.addressLabel.text = self.legacyLocationAddress.length > 0
            ? self.legacyLocationAddress
            : PXLocalizedString(@"image.location.geo_ip.address.placeholder");
        self.regionLabel.text = self.legacyLocationAddress.length > 0
            ? PXLocalizedString(@"image.location.geo_ip.legacy_preserved")
            : PXLocalizedString(@"image.location.geo_ip.details.placeholder");
        self.timeZoneValueLabel.text = @"";
        self.coordinatesValueLabel.text = @"";
        self.informationStack.hidden = !self.hasAttemptedDetection;
        self.sourceLabel.hidden = YES;
        self.mismatchRow.hidden = YES;
        return;
    }
    self.addressLabel.text = location.city.length > 0 ? location.city : location.address;
    NSMutableArray<NSString *> *regionParts = [NSMutableArray array];
    if (location.region.length > 0) [regionParts addObject:location.region];
    if (location.country.length > 0) [regionParts addObject:location.country];
    self.regionLabel.text = regionParts.count > 0
        ? [regionParts componentsJoinedByString:@", "] : location.address;
    self.informationStack.hidden = NO;
    self.timeZoneValueLabel.text = location.timeZoneIdentifier.length > 0
        ? location.timeZoneIdentifier : @"—";
    self.coordinatesValueLabel.text = [NSString stringWithFormat:@"%.4f, %.4f",
        location.latitude, location.longitude];
    self.sourceLabel.text = self.displayedLocation
        ? PXLocalizedString(@"image.location.geo_ip.source")
        : PXLocalizedString(@"image.location.geo_ip.saved_preserved");
    self.sourceLabel.hidden = NO;
    [self updateCarrierMismatchWarningForLocation:location];
}

- (void)fetchCurrentGeoIPLocation {
    self.requestRevision += 1;
    self.selectedLocationPolicy = nil;
    [self updateConfirmButtonState];
    NSUInteger revision = self.requestRevision;
    [self.activeRequest cancel];
    for (NSURLSessionDataTask *task in self.activeAddressRequests) [task cancel];
    self.activeAddressRequests = nil;
    self.displayedLocation = nil;
    self.pendingLocation = nil;
    self.detectedIPv4Address = nil;
    self.detectedIPv6Address = nil;
    self.loading = YES;
    self.hasAttemptedDetection = YES;
    self.geoRequestCompleted = NO;
    self.ipv4RequestCompleted = NO;
    self.ipv6RequestCompleted = NO;
    self.requestFailed = NO;
    self.currentDetectionSucceeded = NO;
    [self refreshLocalizedContent];
    __weak typeof(self) weakSelf = self;
    self.activeRequest = [self.locationService fetchCurrentLocationWithCompletion:
        ^(PXGeoIPLocation *location, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.requestRevision != revision) return;
        self.activeRequest = nil;
        self.geoRequestCompleted = YES;
        self.pendingLocation = error ? nil : location;
        if (!location || error) {
            NSLog(@"[ProjectX] GEO IP location error: %@", error.localizedDescription);
        }
        [self finishDetectionIfReadyForRevision:revision];
    }];

    NSURLSessionDataTask *ipv4Request = [self.locationService
        fetchPublicIPAddressForFamily:PXGeoIPNetworkFamilyIPv4
                          completion:^(NSString *address, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.requestRevision != revision) return;
        self.ipv4RequestCompleted = YES;
        self.detectedIPv4Address = error ? nil : address;
        if (error) NSLog(@"[ProjectX] Public IPv4 lookup error: %@", error.localizedDescription);
        [self finishDetectionIfReadyForRevision:revision];
    }];
    NSURLSessionDataTask *ipv6Request = [self.locationService
        fetchPublicIPAddressForFamily:PXGeoIPNetworkFamilyIPv6
                          completion:^(NSString *address, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.requestRevision != revision) return;
        self.ipv6RequestCompleted = YES;
        self.detectedIPv6Address = error ? nil : address;
        if (error) NSLog(@"[ProjectX] Public IPv6 lookup error: %@", error.localizedDescription);
        [self finishDetectionIfReadyForRevision:revision];
    }];
    self.activeAddressRequests = @[ipv4Request, ipv6Request];
}

- (void)finishDetectionIfReadyForRevision:(NSUInteger)revision {
    if (self.requestRevision != revision) return;
    if (!self.geoRequestCompleted || !self.ipv4RequestCompleted || !self.ipv6RequestCompleted) {
        [self refreshLocalizedContent];
        return;
    }
    self.activeAddressRequests = nil;
    if (self.detectedIPv4Address.length == 0) {
        self.detectedIPv4Address = [self.pendingLocation
            publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv4];
    }
    if (self.detectedIPv6Address.length == 0) {
        self.detectedIPv6Address = [self.pendingLocation
            publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv6];
    }
    self.displayedLocation = self.pendingLocation;
    self.pendingLocation = nil;
    self.loading = NO;
    self.requestFailed = self.displayedLocation == nil;
    self.currentDetectionSucceeded = self.displayedLocation != nil;
    [self refreshLocalizedContent];
    NSString *announcement = self.displayedLocation
        ? PXLocalizedFormat(@"image.location.geo_ip.ready.announcement", self.displayedLocation.address)
        : PXLocalizedString(@"image.location.geo_ip.failed.announcement");
    if (self.view.window) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, announcement);
    }
}

- (void)handleRefreshTapped:(UIButton *)sender {
    (void)sender;
    [self fetchCurrentGeoIPLocation];
}

- (void)handleClearLocationTapped:(UIButton *)sender {
    (void)sender;
    self.pendingClear = YES;
    self.selectedLocationPolicy = nil;
    self.hasStoredLocationConfiguration = NO;
    self.savedGeoIPLocation = nil;
    self.legacyLocationAddress = nil;
    [self refreshLocalizedContent];
}

- (void)handleUseLocationTapped:(UIButton *)sender {
    (void)sender;
    if (!self.displayedLocation || !self.currentDetectionSucceeded || self.loading) return;
    self.selectedLocationPolicy = [self.displayedLocation
        policyRepresentationWithIPv4Address:self.detectedIPv4Address
                              ipv6Address:self.detectedIPv6Address];
    self.pendingClear = NO;
    [self refreshLocalizedContent];
}

- (void)handleConfirmTapped:(UIBarButtonItem *)sender {
    if (!sender.enabled) return;
    NSError *error = nil;
    if (self.pendingClear) {
        if (![self.environmentPolicyStore clearConfiguredLocationWithError:&error]) {
            [self presentLocationError:error];
            return;
        }
        [self notifyCommittedSummary:PXLocalizedString(@"image.location.address.cleared")];
    } else if (self.selectedLocationPolicy) {
        if (![self.environmentPolicyStore saveConfiguredLocation:self.selectedLocationPolicy error:&error]) {
            [self presentLocationError:error];
            return;
        }
        [self notifyCommittedSummary:self.displayedLocation.address];
    } else {
        return;
    }
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)restoreConfiguredLocation {
    NSError *policyError = nil;
    NSDictionary<NSString *, id> *saved = [self.environmentPolicyStore configuredLocationWithError:&policyError];
    if (policyError) NSLog(@"[ProjectX] Smart Location restore error: %@", policyError.localizedDescription);
    if (!saved) return;
    self.hasStoredLocationConfiguration = YES;
    NSError *restoreError = nil;
    PXGeoIPLocation *location = [PXGeoIPLocation
        locationWithPolicyRepresentation:saved
        error:&restoreError];
    if (!location) {
        NSString *legacyAddress = [saved[@"address"] isKindOfClass:[NSString class]]
            ? [saved[@"address"] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
            : nil;
        self.legacyLocationAddress = legacyAddress.length > 0 ? legacyAddress : nil;
        NSLog(@"[ProjectX] Preserving legacy Smart Location until GEO IP replaces it: %@",
              restoreError.localizedDescription);
        return;
    }
    self.savedGeoIPLocation = location;
}

- (void)updateCarrierMismatchWarningForLocation:(PXGeoIPLocation *)location {
    NSDictionary *profileInfo = PXProfileReadDictionary(PXCurrentProfileInfoPath());
    if (!profileInfo || location.countryCode.length == 0) {
        self.mismatchRow.hidden = YES;
        return;
    }
    PXTrustedCarrierPolicyStore *store = [[PXTrustedCarrierPolicyStore alloc] init];
    NSString *carrierID = [store selectedCarrierIDWithError:nil];
    NSString *carrierCountryCode = nil;
    for (NSDictionary<NSString *, id> *carrier in PXCarrierCatalog()) {
        if ([carrier[@"carrierID"] isEqualToString:carrierID]) {
            carrierCountryCode = [carrier[@"isoCountryCode"] uppercaseString];
            break;
        }
    }
    self.mismatchRow.hidden = carrierCountryCode.length == 0 ||
        [carrierCountryCode isEqualToString:location.countryCode];
}

- (void)notifyCommittedSummary:(NSString *)summary {
    if (self.callbackTarget && self.callbackSelector &&
        [self.callbackTarget respondsToSelector:self.callbackSelector]) {
        void (*callback)(id, SEL, NSString *) =
            (void (*)(id, SEL, NSString *))[self.callbackTarget methodForSelector:self.callbackSelector];
        callback(self.callbackTarget, self.callbackSelector, summary);
    }
}

- (void)presentLocationError:(NSError *)error {
    if (self.presentedViewController) return;
    if (error) NSLog(@"[ProjectX] Smart Location save error: %@", error.localizedDescription);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:PXLocalizedString(@"image.location.error.title")
        message:PXLocalizedString(@"image.location.error.message")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:PXLocalizedString(@"navigation.close")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
