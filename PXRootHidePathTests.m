#import <Foundation/Foundation.h>
#import <assert.h>

#import "PXRootHidePath.h"

static NSString *TestJBRootConverter(NSString *logicalPath) {
    NSString *root = @"/private/randomized/.jbroot-TEST";
    return [root stringByAppendingPathComponent:[logicalPath substringFromIndex:1]];
}

static NSString *TestRootFSConverter(NSString *rootFSPath) {
    return [@"/rootfs" stringByAppendingPathComponent:[rootFSPath substringFromIndex:1]];
}

static void testSharedPathsResolveBelowSuppliedJBRoot(void) {
    PXSetRootHidePathConvertersForTesting(TestJBRootConverter, TestRootFSConverter);

    NSString *expectedRoot = @"/private/randomized/.jbroot-TEST";
    assert([PXWeaponXDataPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/WeaponX"]]);
    assert([PXProfilesDirectoryPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/WeaponX/Profiles"]]);
    assert([PXCurrentProfileInfoPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/WeaponX/Profiles/current_profile_info.plist"]]);
    assert([PXPreferencesFilePath(@"com.weaponx.gpsspoofing.plist") isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.weaponx.gpsspoofing.plist"]]);
    assert([PXGlobalScopePreferencesPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.hydra.projectx.global_scope.plist"]]);
    assert([PXSecuritySettingsPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.weaponx.securitySettings.plist"]]);
    assert([PXGuardianDirectoryPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"Library/WeaponX/Guardian"]]);
    assert([PXWeaponXDaemonPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"Library/WeaponX/WeaponXDaemon"]]);
    assert([PXWeaponXLaunchDaemonPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"Library/LaunchDaemons/com.hydra.weaponx.guardian.plist"]]);
    assert([PXProjectXApplicationPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"Applications/ProjectX.app"]]);
    assert([PXKeychainOneShotWorkerTemplatePath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"Library/WeaponX/ProjectXKeychainWorker"]]);
    assert([PXKeychainOneShotOperationsPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/WeaponX/KeychainOneShot"]]);
}

static void testProfileAndCommandPathsPreserveLogicalLocation(void) {
    NSString *expectedRoot = @"/private/randomized/.jbroot-TEST";
    assert([PXProfileIdentityDirectoryPath(@"profile-7") isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/WeaponX/Profiles/profile-7/identity"]]);
    assert([PXBootstrapCommandPath(@"killall") isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"usr/bin/killall"]]);
    assert([PXRootFSPath(@"/var/mobile/Containers") isEqualToString:
        @"/rootfs/var/mobile/Containers"]);
}

int main(void) {
    @autoreleasepool {
        testSharedPathsResolveBelowSuppliedJBRoot();
        testProfileAndCommandPathsPreserveLogicalLocation();
    }
    return 0;
}
