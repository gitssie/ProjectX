#import "../core/PXAppState.h"
NS_ASSUME_NONNULL_BEGIN
NSArray<NSString *> * _Nullable PXASKeychainGroupsFromEntitlements(NSDictionary *entitlements, NSString *bundleID, NSError **error);

// Standalone physical-path adapter. Product integration must use PXRootHidePath
// and the existing worker signer instead of giving the UIKit process groups.
@interface PXASLaunchServicesResolver : NSObject <PXASResolver>
@end
@interface PXASSecurityKeychain : NSObject <PXASKeychain>
- (instancetype)initWithApplicationIdentifier:(NSString *)applicationIdentifier;
@end
// Optional explicit identity adapter. No default root/system mutation is made.
// Blocks must synchronously return after scoped authority/cache verification.
@interface PXASBlockIdentity : NSObject <PXASIdentity>
- (instancetype)initWithCapture:(NSDictionary * _Nullable (^)(NSDictionary *, NSError **))capture
                       validate:(BOOL (^)(NSDictionary *, NSDictionary *, NSError **))validate
                        restore:(BOOL (^)(NSDictionary *, NSDictionary *, NSError **))restore;
@end
// privilegedCommand is an argv prefix, e.g. [resolved-sudo, "-n", signed-worker].
// Nil command makes this adapter capture-only; requested restores fail closed.
@interface PXASVendorIdentity : NSObject <PXASIdentity>
- (instancetype)initWithPrivilegedCommand:(nullable NSArray<NSString *> *)command
                             systemPlist:(nullable NSString *)systemPlist;
@end
NS_ASSUME_NONNULL_END
