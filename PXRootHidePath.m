#import "PXRootHidePath.h"

#if !defined(PROJECTX_PATHS_TESTING)
#import <roothide.h>
#endif

NSString * const PXWeaponXDataLogicalPath = @"/var/mobile/Library/WeaponX";
NSString * const PXWeaponXProfilesLogicalPath = @"/var/mobile/Library/WeaponX/Profiles";
NSString * const PXWeaponXPreferencesLogicalPath = @"/var/mobile/Library/Preferences";
NSString * const PXWeaponXGuardianLogicalPath = @"/Library/WeaponX/Guardian";
NSString * const PXProjectXApplicationLogicalPath = @"/Applications/ProjectX.app";

#if defined(PROJECTX_PATHS_TESTING)
static PXRootHidePathConverter PXTestJBRootConverter;
static PXRootHidePathConverter PXTestRootFSConverter;

void PXSetRootHidePathConvertersForTesting(PXRootHidePathConverter jbrootConverter,
                                           PXRootHidePathConverter rootFSConverter) {
    PXTestJBRootConverter = jbrootConverter;
    PXTestRootFSConverter = rootFSConverter;
}
#endif

static void PXRequireAbsoluteLogicalPath(NSString *path) {
    NSCParameterAssert(path.length > 0);
    NSCParameterAssert([path hasPrefix:@"/"]);
}

NSString *PXJBRootPath(NSString *logicalPath) {
    PXRequireAbsoluteLogicalPath(logicalPath);
#if defined(PROJECTX_PATHS_TESTING)
    NSCAssert(PXTestJBRootConverter != NULL, @"A deterministic jbroot converter is required in tests");
    return PXTestJBRootConverter(logicalPath);
#else
    return jbroot(logicalPath);
#endif
}

NSString *PXRootFSPath(NSString *rootFSPath) {
    PXRequireAbsoluteLogicalPath(rootFSPath);
#if defined(PROJECTX_PATHS_TESTING)
    NSCAssert(PXTestRootFSConverter != NULL, @"A deterministic rootfs converter is required in tests");
    return PXTestRootFSConverter(rootFSPath);
#else
    return rootfs(rootFSPath);
#endif
}

NSString *PXWeaponXDataPath(void) {
    return PXJBRootPath(PXWeaponXDataLogicalPath);
}

NSString *PXProfilesDirectoryPath(void) {
    return PXJBRootPath(PXWeaponXProfilesLogicalPath);
}

NSString *PXProfileDirectoryPath(NSString *profileID) {
    NSCParameterAssert(profileID.length > 0);
    return [PXProfilesDirectoryPath() stringByAppendingPathComponent:profileID];
}

NSString *PXProfileIdentityDirectoryPath(NSString *profileID) {
    return [PXProfileDirectoryPath(profileID) stringByAppendingPathComponent:@"identity"];
}

NSString *PXCurrentProfileInfoPath(void) {
    return [PXProfilesDirectoryPath() stringByAppendingPathComponent:@"current_profile_info.plist"];
}

NSString *PXActiveProfileInfoPath(void) {
    return [PXWeaponXDataPath() stringByAppendingPathComponent:@"active_profile_info.plist"];
}

NSString *PXPreferencesDirectoryPath(void) {
    return PXJBRootPath(PXWeaponXPreferencesLogicalPath);
}

NSString *PXPreferencesFilePath(NSString *fileName) {
    NSCParameterAssert(fileName.length > 0);
    NSCParameterAssert([fileName rangeOfString:@"/"].location == NSNotFound);
    return [PXPreferencesDirectoryPath() stringByAppendingPathComponent:fileName];
}

NSString *PXGlobalScopePreferencesPath(void) {
    return PXPreferencesFilePath(@"com.hydra.projectx.global_scope.plist");
}

NSString *PXSecuritySettingsPath(void) {
    return PXPreferencesFilePath(@"com.weaponx.securitySettings.plist");
}

NSString *PXGuardianDirectoryPath(void) {
    return PXJBRootPath(PXWeaponXGuardianLogicalPath);
}

NSString *PXWeaponXDaemonPath(void) {
    return [PXJBRootPath(@"/Library/WeaponX") stringByAppendingPathComponent:@"WeaponXDaemon"];
}

NSString *PXWeaponXLaunchDaemonPath(void) {
    return PXJBRootPath(@"/Library/LaunchDaemons/com.hydra.weaponx.guardian.plist");
}

NSString *PXProjectXApplicationPath(void) {
    return PXJBRootPath(PXProjectXApplicationLogicalPath);
}

NSString *PXKeychainOneShotWorkerTemplatePath(void) {
    return [PXJBRootPath(@"/Library/WeaponX") stringByAppendingPathComponent:
        @"ProjectXKeychainWorker"];
}

NSString *PXKeychainOneShotOperationsPath(void) {
    return [PXWeaponXDataPath() stringByAppendingPathComponent:@"KeychainOneShot"];
}

NSString *PXBootstrapCommandPath(NSString *commandName) {
    NSCParameterAssert(commandName.length > 0);
    NSCParameterAssert([commandName rangeOfString:@"/"].location == NSNotFound);
    return [PXJBRootPath(@"/usr/bin") stringByAppendingPathComponent:commandName];
}
