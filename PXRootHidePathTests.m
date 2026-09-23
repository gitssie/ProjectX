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

static NSString *TestWritableJBRootConverter(NSString *logicalPath) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-single-profile-test" stringByAppendingPathComponent:[logicalPath substringFromIndex:1]]];
}

static void testProfileValuesShareOnePlist(void) {
    PXSetRootHidePathConvertersForTesting(TestWritableJBRootConverter, TestRootFSConverter);
    NSString *weaponX = PXWeaponXDataPath();
    [[NSFileManager defaultManager] removeItemAtPath:weaponX error:nil];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:weaponX
        withIntermediateDirectories:YES attributes:nil error:nil]);
    assert(PXProfileUpdateContentsAtPath(PXCurrentProfileInfoPath(), ^(NSMutableDictionary *profile) {
        (void)profile;
    }));
    NSDictionary *initialProfile = PXProfileReadContentsAtPath(PXCurrentProfileInfoPath());
    assert([initialProfile[@"ProfileName"] isEqualToString:@"ProjectX"]);
    assert([initialProfile[@"values"] isEqualToDictionary:@{}]);
    NSString *modelPath = [PXCurrentProfileIdentityValuesPath() stringByAppendingPathComponent:@"device_model.plist"];
    NSString *networkPath = [PXCurrentProfileIdentityValuesPath() stringByAppendingPathComponent:@"network_settings.plist"];
    assert(PXProfileWriteDictionary(@{@"value": @"iPhone13,2"}, modelPath));
    assert(PXProfileWriteDictionary(@{@"ssid": @"Example"}, networkPath));
    assert(PXSetCurrentProfileValue(@"appVersions/com.example.app",
        @{@"version": @"1.0"}));
    assert([PXCurrentProfileValue(@"appVersions/com.example.app")[@"version"]
        isEqualToString:@"1.0"]);
    NSString *environmentPath = PXPreferencesFilePath(@"com.hydra.projectx.pending-environment.plist");
    assert(PXSetCurrentProfileValue(@"environment", @{@"networkType": @"wifi"}));
    assert([PXProfileReadDictionary(modelPath)[@"value"] isEqualToString:@"iPhone13,2"]);
    assert([PXProfileReadDictionary(networkPath)[@"ssid"] isEqualToString:@"Example"]);
    assert([PXCurrentProfileValue(@"environment")[@"networkType"] isEqualToString:@"wifi"]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:PXCurrentProfileInfoPath()]);
    assert(PXProfileReadContentsAtPath(PXCurrentProfileInfoPath())[@"ProfileId"] == nil);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:environmentPath]);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:[PXWeaponXDataPath() stringByAppendingPathComponent:@"Profiles"]]);
    NSString *otherProfilePath = [[PXWeaponXDataPath() stringByAppendingPathComponent:@"Profiles"]
        stringByAppendingPathComponent:@"other/identity/device_ids.plist"];
    assert(!PXProfileWriteDictionary(@{@"value": @"invalid"}, otherProfilePath));
    assert(![[NSFileManager defaultManager] fileExistsAtPath:[PXWeaponXDataPath() stringByAppendingPathComponent:@"Profiles"]]);
    dispatch_apply(24, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        NSString *name = [NSString stringWithFormat:@"field-%zu.plist", index];
        NSString *path = [PXCurrentProfileIdentityValuesPath() stringByAppendingPathComponent:name];
        assert(PXProfileWriteDictionary(@{@"index": @(index)}, path));
    });
    for (NSUInteger index = 0; index < 24; index++) {
        NSString *name = [NSString stringWithFormat:@"field-%lu.plist", (unsigned long)index];
        NSString *path = [PXCurrentProfileIdentityValuesPath() stringByAppendingPathComponent:name];
        assert([PXProfileReadDictionary(path)[@"index"] unsignedIntegerValue] == index);
    }
    assert([@"invalid plist" writeToFile:PXCurrentProfileInfoPath()
        atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    assert(!PXProfileWriteDictionary(@{@"value": @"must not replace damage"}, modelPath));
    assert(PXProfileReadDictionary(modelPath) == nil);
    assert([[NSString stringWithContentsOfFile:PXCurrentProfileInfoPath()
        encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"invalid plist"]);
    [[NSFileManager defaultManager] removeItemAtPath:weaponX error:nil];
}

static void testSharedPathsResolveBelowSuppliedJBRoot(void) {
    PXSetRootHidePathConvertersForTesting(TestJBRootConverter, TestRootFSConverter);

    NSString *expectedRoot = @"/private/randomized/.jbroot-TEST";
    assert([PXWeaponXDataPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/WeaponX"]]);
    assert([PXCurrentProfileInfoPath() isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"var/mobile/Library/WeaponX/current_profile.plist"]]);
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
    assert([PXCurrentProfileIdentityValuesPath() isEqualToString:@"current-profile/identity"]);
    assert([PXBootstrapCommandPath(@"killall") isEqualToString:
        [expectedRoot stringByAppendingPathComponent:@"usr/bin/killall"]]);
    assert([PXRootFSPath(@"/var/mobile/Containers") isEqualToString:
        @"/rootfs/var/mobile/Containers"]);
}

int main(void) {
    @autoreleasepool {
        testSharedPathsResolveBelowSuppliedJBRoot();
        testProfileAndCommandPathsPreserveLogicalLocation();
        testProfileValuesShareOnePlist();
    }
    return 0;
}
