TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
LOGOS_DEFAULT_GENERATOR = internal
INSTALL_TARGET_PROCESSES = SpringBoard ProjectX

# ProjectX supports the randomized RootHide bootstrap exclusively.
override THEOS_PACKAGE_SCHEME := roothide
override THEOS_PACKAGE_ARCH := iphoneos-arm64e

# Note: This project now includes a Notification Service Extension for rich push notifications
# The extension needs to be manually added in Xcode after installing this package
# See /NotificationServiceExtension/README.md for integration instructions

include $(THEOS)/makefiles/common.mk

# The modern Apple linker rejects this obsolete Theos compatibility pair.
_PROJECTX_DARWIN_LD_VERSION := $(shell xcrun ld -v 2>&1)
ifeq ($(shell uname -s),Darwin)
ifneq ($(findstring PROJECT:ld-,$(_PROJECTX_DARWIN_LD_VERSION)),)
_THEOS_TARGET_LDFLAGS := $(subst -multiply_defined suppress,,$(_THEOS_TARGET_LDFLAGS))
endif
endif

TWEAK_NAME = ProjectXLoader ProjectXTweak
APPLICATION_NAME = ProjectX
TOOL_NAME = WeaponXDaemon ProjectXKeychainWorker

# Tweak files
ProjectXLoader_FILES = ProjectXLoader.m ProjectXLoaderPolicy.m PXRootHidePath.m
ProjectXLoader_CFLAGS = -fobjc-arc -Werror
ProjectXLoader_FRAMEWORKS = Foundation
ProjectXLoader_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
ProjectXLoader_LDFLAGS = -lroothide
ProjectXLoader_CODESIGN_FLAGS = -Sent.plist

ProjectXTweak_FILES = Tweak.x SensorHooks.x WiFiHook.x StorageHooks.x UUIDHooks.x PasteboardHooks.x AppInstallHooks.x AppContainerHooks.x AppGroupHooks.x RegionEnvironmentHooks.x DeviceModelHooks.x SpringBoardLaunchHook.x UberURLHooks.x IOSVersionHooks.x ThemeHooks.x DeviceSpecHooks.x NetworkConnectionTypeHooks.x CanvasFingerprintHooks.x OpenGLHooks.x BootTimeHooks.x DomainBlockingHooks.x IdentifierManager.m AppIdentity.m AppIdentityHookSupport.m GraphicsIdentity.m RegionIdentity.m RegionEnvironment.m IDFAManager.m IDFVManager.m DeviceNameManager.m DeviceModelManager.m WiFiManager.m ProjectXLogging.m WeaponXGuardian.m SerialNumberManager.m ProfileIndicatorView.m IPStatusViewController.m IPStatusCacheManager.m ScoreMeterView.m PassThroughWindow.m ProfileManager.m ProfileManifest.m TrustedCarrierPolicy.m InlineHook.m fishhook.c LocationSpoofingManager.m LocationSession.m JailbreakDetectionBypass.m IOSVersionInfo.m MethodSwizzler.m StorageManager.m BatteryManager.m SystemUUIDManager.m DyldCacheUUIDManager.m PasteboardUUIDManager.m KeychainUUIDManager.m UserDefaultsUUIDManager.m UptimeManager.m CoreDataUUIDManager.m IPMonitorService.m MapTabViewController.m PickupDropManager.m MapTabViewController+PickupDrop.m UberFareCalculator.m LocationHeaderView.m MapTabViewControllerExtension.m DomainBlockingSettings.m BatteryHooks.x NetworkManager.m NetworkIdentity.m NetworkInterfacePolicy.c NetworkRuntimeCoverage.m VPNDetectionBypass.x AppVersionHooks.x PXRootHidePath.m PXScopedAppStore.m PXEnvironmentModelSelection.m PXEnvironmentPolicy.m PXProcessHookPolicy.m PXSysctlHookRouter.m
ProjectXTweak_CFLAGS = -fobjc-arc -Werror -I$(THEOS_VENDOR_INCLUDE_PATH) -I./include -D USES_LIBUNDIRECT=1 -D SUPPORT_IPAD=1 -D ENABLE_STATE_RESTORATION=1
ProjectXTweak_FRAMEWORKS = UIKit Foundation AdSupport UserNotifications IOKit Security CoreLocation CoreFoundation CFNetwork Network NetworkExtension CoreTelephony SystemConfiguration WebKit SafariServices Metal OpenGLES
ProjectXTweak_PRIVATE_FRAMEWORKS = MobileCoreServices AppSupport SpringBoardServices
ProjectXTweak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
ProjectXTweak_LDFLAGS = -F$(THEOS)/vendor/lib -framework CydiaSubstrate -lroothide
ProjectXTweak_CODESIGN_FLAGS = -Sent.plist

# App files
ProjectX_FILES = $(filter-out $(wildcard *Tests.m) Tweak.x WiFiHook.x StorageHooks.x UUIDHooks.x PasteboardHooks.x WeaponXDaemon.m PXKeychainOneShotWorker.m JailbreakDetectionBypass.m AppIdentityHookSupport.m NetworkRuntimeCoverage.m RegionEnvironment.m ProjectXLoader.m ProjectXLoaderPolicy.m PXSysctlHookRouter.m, $(wildcard *.m)) JailbreakDetectionBypass_App.m fishhook.c IOSVersionInfo.m UptimeManager.m AppVersionSpoofingViewController.m IPStatusViewController.m IPStatusCacheManager.m IPMonitorService.m ProjectXSceneDelegate.m ProgressHUDView.m PickupDropManager.m MapTabViewController+PickupDrop.m UberFareCalculator.m LocationHeaderView.m MapTabViewControllerExtension.m DomainBlockingSettings.m DomainManagementViewController.m
ProjectX_RESOURCE_DIRS = Assets.xcassets
ProjectX_RESOURCE_FILES = Info.plist Icon.png LaunchMark.png LaunchMark@2x.png LaunchMark@3x.png en.lproj zh-Hans.lproj
ProjectX_PRIVATE_FRAMEWORKS = FrontBoardServices SpringBoardServices BackBoardServices StoreKitUI MobileCoreServices
ProjectX_LDFLAGS = -framework CoreData -F$(THEOS_SDKS_PATH)/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks -lroothide
ProjectX_FRAMEWORKS = UIKit Foundation MobileCoreServices CoreServices StoreKit IOKit Security CoreLocation CoreLocationUI MapKit Metal OpenGLES
ProjectX_CODESIGN_FLAGS = -SProjectX.entitlements
ProjectX_CFLAGS = -fobjc-arc -Werror -D SUPPORT_IPAD=1 -D ENABLE_STATE_RESTORATION=1

# Daemon files
WeaponXDaemon_FILES = WeaponXDaemon.m PXRootHidePath.m
WeaponXDaemon_CFLAGS = -fobjc-arc -Werror
WeaponXDaemon_FRAMEWORKS = Foundation IOKit
WeaponXDaemon_LDFLAGS = -lroothide
WeaponXDaemon_INSTALL_PATH = /Library/WeaponX
WeaponXDaemon_CODESIGN_FLAGS = -Sent.plist

# Per-operation Keychain worker template. It is copied and re-signed with one
# exact target application group immediately before each bounded execution.
ProjectXKeychainWorker_FILES = PXKeychainOneShotWorker.m KeychainCommand.m AppIdentity.m PXRootHidePath.m PXProcessKeychainSecurityAdapter.m
ProjectXKeychainWorker_CFLAGS = -fobjc-arc -Werror
ProjectXKeychainWorker_FRAMEWORKS = Foundation Security
ProjectXKeychainWorker_LDFLAGS = -lroothide
ProjectXKeychainWorker_INSTALL_PATH = /Library/WeaponX
ProjectXKeychainWorker_CODESIGN_FLAGS = -SKeychainWorkerTemplate.entitlements

# Ensure app is installed to the correct location with proper permissions
ProjectX_INSTALL_PATH = /Applications
ProjectX_APPLICATION_MODE = 0755

PROJECTX_STAGED_APP = $(THEOS_STAGING_DIR)$(ProjectX_INSTALL_PATH)/$(APPLICATION_NAME).app

# Make sure both tweak and application are built
all::
	@echo "Building tweak, application, daemon, and one-shot Keychain worker..."

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

# Custom rule to ensure the RootHide payload is complete.
internal-stage::
	@echo "Adding custom scripts to package..."
	@mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	@cp -a DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/
	@cp -a DEBIAN/preinst $(THEOS_STAGING_DIR)/DEBIAN/
	@cp -a DEBIAN/prerm $(THEOS_STAGING_DIR)/DEBIAN/
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/preinst
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/prerm
	@echo "Adding setup script to package..."
	@mkdir -p $(THEOS_STAGING_DIR)/usr/bin
	@cp -a setup_app.sh $(THEOS_STAGING_DIR)/usr/bin/projectx-setup
	@chmod 755 $(THEOS_STAGING_DIR)/usr/bin/projectx-setup
	@echo "Staging the RootHide tweak payload..."
	@mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/
	@cp -a $(THEOS_OBJ_DIR)/ProjectXLoader.* $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/
	@cp -a $(THEOS_OBJ_DIR)/ProjectXTweak.* $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/
	@echo "Ensuring LaunchScreen.storyboard is properly compiled..."
	@test -f "LaunchScreen.storyboard"
	@mkdir -p "$(PROJECTX_STAGED_APP)"
	@rm -rf "$(PROJECTX_STAGED_APP)/LaunchScreen.storyboardc" "$(PROJECTX_STAGED_APP)/LaunchScreen.storyboard"
	@xcrun --sdk iphoneos ibtool --errors --warnings --notices \
		--minimum-deployment-target "$(_THEOS_TARGET_OS_DEPLOYMENT_VERSION)" \
		--target-device iphone --target-device ipad \
		--compile "$(PROJECTX_STAGED_APP)/LaunchScreen.storyboardc" "LaunchScreen.storyboard"
	@/bin/sh "$(CURDIR)/scripts/check_build_warnings.sh" --check-launch-screen "$(PROJECTX_STAGED_APP)"
	@echo "Adding LaunchDaemon for persistent operation..."
	@mkdir -p $(THEOS_STAGING_DIR)/Library/LaunchDaemons
	@mkdir -p $(THEOS_STAGING_DIR)/Library/WeaponX/Guardian
	@mkdir -p $(THEOS_STAGING_DIR)/var/mobile/Library/Preferences
	@cp -a com.hydra.weaponx.guardian.plist $(THEOS_STAGING_DIR)/Library/LaunchDaemons/
	@chmod 644 $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.hydra.weaponx.guardian.plist
	@chmod 755 $(THEOS_STAGING_DIR)/Library/WeaponX
	@chmod 755 $(THEOS_STAGING_DIR)/Library/WeaponX/Guardian
	@touch $(THEOS_STAGING_DIR)/Library/WeaponX/Guardian/daemon.log
	@touch $(THEOS_STAGING_DIR)/Library/WeaponX/Guardian/guardian-stdout.log
	@touch $(THEOS_STAGING_DIR)/Library/WeaponX/Guardian/guardian-stderr.log
	@chmod 664 $(THEOS_STAGING_DIR)/Library/WeaponX/Guardian/*.log
	@echo "Installing WeaponXDaemon..."
	@cp -a $(THEOS_OBJ_DIR)/WeaponXDaemon $(THEOS_STAGING_DIR)/Library/WeaponX/
	@chmod 755 $(THEOS_STAGING_DIR)/Library/WeaponX/WeaponXDaemon
	@echo "Installing the one-shot Keychain worker template..."
	@cp -a $(THEOS_OBJ_DIR)/ProjectXKeychainWorker $(THEOS_STAGING_DIR)/Library/WeaponX/
	@chmod 755 $(THEOS_STAGING_DIR)/Library/WeaponX/ProjectXKeychainWorker
	@echo "Adding debug tools..."
	@mkdir -p $(THEOS_STAGING_DIR)/usr/bin
	@cp -a weaponx-debug.sh $(THEOS_STAGING_DIR)/usr/bin/weaponx-debug
	@chmod 755 $(THEOS_STAGING_DIR)/usr/bin/weaponx-debug
	@/bin/sh "$(CURDIR)/scripts/check_roothide.sh" --check-staging "$(THEOS_STAGING_DIR)"
	@/bin/sh "$(CURDIR)/scripts/check_roothide.sh" --check-worker-binary "$(THEOS_STAGING_DIR)"
	@/bin/sh "$(CURDIR)/tests/run_geo_ip_location_tests.sh"
	@python3 "$(CURDIR)/tests/SmartLocationGeoIPTests.py"
	@python3 "$(CURDIR)/tests/HomeDeviceInfoTests.py"
	@python3 "$(CURDIR)/tests/SettingsAboutIconLayoutTests.py"
	@python3 "$(CURDIR)/tests/SettingsPendingBannerTests.py"
	@python3 "$(CURDIR)/tests/LocalizationParityTests.py"
	@/bin/sh "$(CURDIR)/tests/run_keychain_one_shot_execution_tests.sh" \
		"$(THEOS_STAGING_DIR)/Library/WeaponX/ProjectXKeychainWorker"

ProjectXCLI_FILES = ProjectXCLIbinary.m DeviceNameManager.m InlineHook.m IdentifierManager.m IDFAManager.m IDFVManager.m WiFiManager.m SerialNumberManager.m ProjectXLogging.m fishhook.c ProfileManager.m IOSVersionInfo.m
ProjectXCLI_CFLAGS = -fobjc-arc -Werror -I$(THEOS_VENDOR_INCLUDE_PATH)
ProjectXCLI_FRAMEWORKS = UIKit Foundation AdSupport UserNotifications IOKit Security
ProjectXCLI_PRIVATE_FRAMEWORKS = MobileCoreServices AppSupport
ProjectXCLI_LDFLAGS = -L$(THEOS_VENDOR_LIBRARY_PATH)

after-package::
	@/bin/sh "$(CURDIR)/scripts/check_roothide.sh" --check-package "$(__THEOS_LAST_PACKAGE_FILENAME)"
