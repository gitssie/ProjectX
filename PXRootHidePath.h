#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const PXWeaponXDataLogicalPath;
FOUNDATION_EXPORT NSString * const PXWeaponXProfilesLogicalPath;
FOUNDATION_EXPORT NSString * const PXWeaponXPreferencesLogicalPath;
FOUNDATION_EXPORT NSString * const PXWeaponXGuardianLogicalPath;
FOUNDATION_EXPORT NSString * const PXProjectXApplicationLogicalPath;

FOUNDATION_EXPORT NSString *PXJBRootPath(NSString *logicalPath);
FOUNDATION_EXPORT NSString *PXRootFSPath(NSString *rootFSPath);
FOUNDATION_EXPORT NSString *PXWeaponXDataPath(void);
FOUNDATION_EXPORT NSString *PXProfilesDirectoryPath(void);
FOUNDATION_EXPORT NSString *PXProfileDirectoryPath(NSString *profileID);
FOUNDATION_EXPORT NSString *PXProfileIdentityDirectoryPath(NSString *profileID);
FOUNDATION_EXPORT NSString *PXCurrentProfileInfoPath(void);
FOUNDATION_EXPORT NSString *PXActiveProfileInfoPath(void);
FOUNDATION_EXPORT NSString *PXPreferencesDirectoryPath(void);
FOUNDATION_EXPORT NSString *PXPreferencesFilePath(NSString *fileName);
FOUNDATION_EXPORT NSString *PXGlobalScopePreferencesPath(void);
FOUNDATION_EXPORT NSString *PXSecuritySettingsPath(void);
FOUNDATION_EXPORT NSString *PXGuardianDirectoryPath(void);
FOUNDATION_EXPORT NSString *PXWeaponXDaemonPath(void);
FOUNDATION_EXPORT NSString *PXWeaponXLaunchDaemonPath(void);
FOUNDATION_EXPORT NSString *PXProjectXApplicationPath(void);
FOUNDATION_EXPORT NSString *PXKeychainOneShotWorkerTemplatePath(void);
FOUNDATION_EXPORT NSString *PXKeychainOneShotOperationsPath(void);
FOUNDATION_EXPORT NSString *PXBootstrapCommandPath(NSString *commandName);

#if defined(PROJECTX_PATHS_TESTING)
typedef NSString * _Nonnull (*PXRootHidePathConverter)(NSString *path);
FOUNDATION_EXPORT void PXSetRootHidePathConvertersForTesting(
    PXRootHidePathConverter jbrootConverter,
    PXRootHidePathConverter rootFSConverter
);
#endif

NS_ASSUME_NONNULL_END
