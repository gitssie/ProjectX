// Simulator-only adapters: counters replace every destructive operation.
#import <UIKit/UIKit.h>
#import "AppDataCleaner.h"
#import "IdentifierManager.h"
#import "PXProjectXEnvironmentOperations.h"
#import "PXEnvironmentPolicy.h"
#import "PXRootHidePath.h"
#import "KeychainCommand.h"

static NSUInteger Mutations;
static NSString *FixtureRoot;
static NSString *FixturePath(NSString *path) {return [FixtureRoot stringByAppendingPathComponent:path];}
NSString *const PXKeychainCommandErrorDomain=@"PreviewKeychain";
void PXLog(NSString *format,...) {(void)format;}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
@implementation IdentifierManager
+ (instancetype)sharedManager {static IdentifierManager *manager;static dispatch_once_t once;dispatch_once(&once,^{manager=[self new];});return manager;}
- (BOOL)regenerateAllEnabledIdentifiersWithError:(NSError **)error {(void)error;Mutations++;return YES;}
@end
@implementation AppDataCleaner
+ (instancetype)sharedManager {static AppDataCleaner *manager;static dispatch_once_t once;dispatch_once(&once,^{manager=[self new];});return manager;}
- (BOOL)terminateTargetBundleIdentifier:(NSString *)bundle error:(NSError **)error {(void)bundle;(void)error;Mutations++;return YES;}
- (void)clearDataForBundleID:(NSString *)bundle completion:(void (^)(BOOL,NSError *))completion {(void)bundle;Mutations++;completion(YES,nil);}
- (void)clearKeychainForBundleID:(NSString *)bundle includeAppFamily:(BOOL)family completion:(void (^)(BOOL,NSArray<PXKeychainCommandResponse *> *,NSError *))completion {(void)bundle;(void)family;Mutations++;completion(YES,@[],nil);}
- (BOOL)clearWebDataForBundleID:(NSString *)bundle error:(NSError **)error {(void)bundle;(void)error;Mutations++;return YES;}
- (void)clearClipboard {Mutations++;}
@end
#pragma clang diagnostic pop

void RunOperationsModeTests(void) {
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    FixtureRoot=root;PXSetRootHidePathConvertersForTesting(FixturePath,FixturePath);
    PXEnvironmentPolicyStore *store=[PXEnvironmentPolicyStore sharedStore];
    PXProjectXEnvironmentOperations *ops=[PXProjectXEnvironmentOperations sharedOperations];ops.targetBundleIdentifiers=[NSSet setWithObject:@"com.apple.mobilesafari"];
    NSCAssert([store applicationEnvironmentModeWithError:nil]==PXApplicationEnvironmentModeBackup,@"Default backup mode");
    NSError *error=nil;
    NSCAssert(![ops generateAndActivateEnvironmentWithError:&error] && error,@"Backup mode blocks activation");
    NSCAssert(![ops terminateTargetBundleIdentifier:@"test" error:nil],@"Backup mode blocks termination");
    [ops clearKeychainForTargetBundleIdentifier:@"test" completion:^(BOOL ok,NSError *failure){NSCAssert(!ok && failure,@"Backup mode blocks account clearing");}];
    [ops clearTargetBundleIdentifier:@"test" completion:^(BOOL ok,NSError *failure){NSCAssert(!ok && failure,@"Backup mode blocks data clearing");}];
    NSCAssert(![ops clearSafariWithError:nil] && Mutations==0,@"No destructive calls in backup mode");
    NSCAssert([ops clearPasteboardWithError:nil] && Mutations==1,@"Clipboard remains available");
    NSCAssert([store saveApplicationEnvironmentMode:PXApplicationEnvironmentModeCleanup error:nil] && Mutations==1,@"Mode selection does not perform cleanup");
    NSCAssert([ops generateAndActivateEnvironmentWithError:nil],@"Cleanup mode allows activation");
    NSCAssert([ops terminateTargetBundleIdentifier:@"test" error:nil],@"Cleanup mode allows termination");
    [ops clearKeychainForTargetBundleIdentifier:@"test" completion:^(BOOL ok,NSError *failure){NSCAssert(ok && !failure,@"Cleanup mode allows account clearing");}];
    [ops clearTargetBundleIdentifier:@"test" completion:^(BOOL ok,NSError *failure){NSCAssert(ok && !failure,@"Cleanup mode allows data clearing");}];
    NSCAssert([ops clearSafariWithError:nil] && Mutations==6,@"Cleanup mode preserves existing operation sequence");
    NSCAssert([store saveApplicationEnvironmentMode:PXApplicationEnvironmentModeBackup error:nil],@"Switch back to backup mode");
    NSCAssert(![ops generateAndActivateEnvironmentWithError:nil] && Mutations==6,@"Later requests are blocked after changing back");
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    [@{@"passed":@YES,@"destructiveCalls":@(Mutations)} writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"operations-mode-checks.plist"] atomically:YES];
}
