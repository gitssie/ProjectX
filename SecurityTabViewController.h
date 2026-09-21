#import "UIKit/UIKit.h"

@class PXTrustedCarrierOption;

@interface MatrixRainView : UIView
- (void)startAnimation;
- (void)stopAnimation;
- (void)updateWithColor:(UIColor *)color;
@end

@interface SecurityCardView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UISwitch *toggleSwitch;
@property (nonatomic, strong) UIButton *infoButton;
@property (nonatomic, copy) NSString *featureKey;
@property (nonatomic, copy) NSString *featureDescription;
@end

@interface SecurityTabViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>

// VPN/PROXY Detection Bypass control
@property (nonatomic, strong) UILabel *vpnDetectionLabel;
@property (nonatomic, strong) UISwitch *vpnDetectionToggleSwitch;
@property (nonatomic, strong) UIButton *vpnDetectionInfoButton;

- (void)presentIPStatusPage;

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) MatrixRainView *matrixRainView;
@property (nonatomic, strong) NSMutableArray *securityCards;
@property (nonatomic, strong) NSUserDefaults *securitySettings;
@property (nonatomic, assign) BOOL matrixRainEnabled;

// Matrix rain control
@property (nonatomic, strong) UILabel *matrixLabel;
@property (nonatomic, strong) UISwitch *matrixToggleSwitch;
@property (nonatomic, strong) UIButton *matrixInfoButton;

// Profile indicator control
@property (nonatomic, strong) UILabel *profileIndicatorLabel;
@property (nonatomic, strong) UISwitch *profileIndicatorToggleSwitch;
@property (nonatomic, strong) UIButton *profileIndicatorInfoButton;

// Jailbreak detection bypass control
@property (nonatomic, strong) UILabel *jailbreakDetectionLabel;
@property (nonatomic, strong) UISwitch *jailbreakDetectionToggleSwitch;
@property (nonatomic, strong) UIButton *jailbreakDetectionInfoButton;

// Network data spoof control
@property (nonatomic, strong) UILabel *networkDataSpoofLabel;
@property (nonatomic, strong) UISwitch *networkDataSpoofToggleSwitch;
@property (nonatomic, strong) UIButton *networkDataSpoofInfoButton;

// Network connection type control
@property (nonatomic, strong) UILabel *networkConnectionTypeLabel;
@property (nonatomic, strong) UISegmentedControl *networkConnectionTypeSegment;
@property (nonatomic, strong) UIButton *networkConnectionTypeInfoButton;

// Trusted carrier selection and generated carrier status
@property (nonatomic, strong) UIButton *trustedCarriersButton;
@property (nonatomic, strong) UILabel *trustedCarriersSummaryLabel;
@property (nonatomic, strong) UILabel *generatedCarrierStatusLabel;
@property (nonatomic, strong) UIView *carrierSelectionContainer;
@property (nonatomic, copy) NSArray<PXTrustedCarrierOption *> *trustedCarrierOptions;
@property (nonatomic, copy) NSSet<NSString *> *selectedTrustedCarrierIDs;

// Device specific spoofing control
@property (nonatomic, strong) UILabel *deviceSpoofingLabel;
@property (nonatomic, strong) UISwitch *deviceSpoofingToggleSwitch;
@property (nonatomic, strong) UIButton *deviceSpoofingAccessButton;

// App specific version spoofing control
@property (nonatomic, strong) UILabel *appVersionSpoofingLabel;
@property (nonatomic, strong) UISwitch *appVersionSpoofingToggleSwitch;
@property (nonatomic, strong) UIButton *appVersionSpoofingAccessButton;

// Canvas fingerprinting protection control
@property (nonatomic, strong) UILabel *canvasFingerprintingLabel;
@property (nonatomic, strong) UISwitch *canvasFingerprintingToggleSwitch;
@property (nonatomic, strong) UIButton *canvasFingerprintingInfoButton;
@property (nonatomic, strong) UIButton *canvasFingerprintingResetButton;

// IP display label
@property (nonatomic, strong) UILabel *ipLabel;
@property (nonatomic, strong) UILabel *locationLabel;

// WiFi local IP address
@property (nonatomic, strong) UIView *localIPContainer;
@property (nonatomic, strong) UITextField *localIPField;
@property (nonatomic, strong) UIButton *localIPGenerateButton;

// Private methods
- (void)setupMatrixControl:(UIView *)contentView;
- (void)setupProfileIndicatorControl:(UIView *)contentView;
- (void)setupJailbreakDetectionControl:(UIView *)contentView;
- (void)setupNetworkDataSpoofControl:(UIView *)contentView;
- (void)setupNetworkConnectionTypeControl:(UIView *)contentView;
- (void)setupDeviceSpecificSpoofingControl:(UIView *)contentView;
- (void)setupAppVersionSpoofingControl:(UIView *)contentView;
- (void)setupCanvasFingerprintingControl:(UIView *)contentView;
- (void)setupAlertChecksSection:(UIView *)contentView;
- (void)setupCopyrightLabel:(UIView *)contentView;

@end
