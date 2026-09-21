#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, PXProcessHookScope) {
    PXProcessHookScopeNone = 0,
    PXProcessHookScopeSpringBoard,
    PXProcessHookScopeApplication
};

FOUNDATION_EXPORT PXProcessHookScope PXProcessHookScopeForIdentity(
    NSString * _Nullable bundleIdentifier,
    NSString * _Nullable processName
);
FOUNDATION_EXPORT PXProcessHookScope PXCurrentProcessHookScope(void);
FOUNDATION_EXPORT BOOL PXProcessMayInstallApplicationHooksForSelection(
    NSString * _Nullable bundleIdentifier,
    NSString * _Nullable processName,
    BOOL applicationEnabled,
    BOOL extensionEnabled
);
FOUNDATION_EXPORT BOOL PXCurrentProcessMayInstallApplicationHooks(void);

NS_ASSUME_NONNULL_END
