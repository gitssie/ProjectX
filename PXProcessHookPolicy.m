#import "PXProcessHookPolicy.h"

@protocol PXProcessApplicationScopeChecking <NSObject>
+ (instancetype)sharedManager;
- (BOOL)isApplicationEnabled:(NSString *)bundleIdentifier;
- (BOOL)isExtensionEnabled:(NSString *)bundleIdentifier;
@end

PXProcessHookScope PXProcessHookScopeForIdentity(NSString *bundleIdentifier,
                                                 NSString *processName) {
    NSString *normalizedBundleIdentifier = bundleIdentifier.lowercaseString;
    NSString *normalizedProcessName = processName.lowercaseString;

    if ([normalizedProcessName isEqualToString:@"springboard"] ||
        [normalizedBundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        return PXProcessHookScopeSpringBoard;
    }
    if (normalizedBundleIdentifier.length == 0) {
        return PXProcessHookScopeNone;
    }
    if ([normalizedBundleIdentifier isEqualToString:@"com.hydra.projectx"] ||
        [normalizedBundleIdentifier hasPrefix:@"com.hydra.projectx."]) {
        return PXProcessHookScopeNone;
    }
    if ([normalizedBundleIdentifier hasPrefix:@"com.apple."]) {
        static NSSet<NSString *> *supportedAppleApplications;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            supportedAppleApplications = [NSSet setWithArray:@[
                @"com.apple.mobilesafari",
                @"com.apple.mobileslideshow"
            ]];
        });
        return [supportedAppleApplications containsObject:normalizedBundleIdentifier]
            ? PXProcessHookScopeApplication
            : PXProcessHookScopeNone;
    }
    return PXProcessHookScopeApplication;
}

PXProcessHookScope PXCurrentProcessHookScope(void) {
    return PXProcessHookScopeForIdentity(NSBundle.mainBundle.bundleIdentifier,
                                         NSProcessInfo.processInfo.processName);
}

BOOL PXProcessMayInstallApplicationHooksForSelection(NSString *bundleIdentifier,
                                                     NSString *processName,
                                                     BOOL applicationEnabled,
                                                     BOOL extensionEnabled) {
    if (PXProcessHookScopeForIdentity(bundleIdentifier, processName) !=
        PXProcessHookScopeApplication) {
        return NO;
    }
    if ([bundleIdentifier.lowercaseString hasPrefix:@"com.apple."]) {
        return applicationEnabled;
    }
    return applicationEnabled || extensionEnabled;
}

BOOL PXCurrentProcessMayInstallApplicationHooks(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *processName = NSProcessInfo.processInfo.processName;
    if (PXProcessHookScopeForIdentity(bundleIdentifier, processName) !=
        PXProcessHookScopeApplication) {
        return NO;
    }

    Class managerClass = NSClassFromString(@"IdentifierManager");
    if (![managerClass respondsToSelector:@selector(sharedManager)]) {
        return NO;
    }
    id<PXProcessApplicationScopeChecking> manager =
        [(id<PXProcessApplicationScopeChecking>)managerClass sharedManager];
    if (!manager ||
        ![manager respondsToSelector:@selector(isApplicationEnabled:)] ||
        ![manager respondsToSelector:@selector(isExtensionEnabled:)]) {
        return NO;
    }
    BOOL applicationEnabled = [manager isApplicationEnabled:bundleIdentifier];
    BOOL extensionEnabled = applicationEnabled
        ? NO
        : [manager isExtensionEnabled:bundleIdentifier];
    return PXProcessMayInstallApplicationHooksForSelection(bundleIdentifier,
                                                           processName,
                                                           applicationEnabled,
                                                           extensionEnabled);
}
