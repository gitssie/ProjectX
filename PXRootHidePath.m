#import "PXRootHidePath.h"

#if !defined(PROJECTX_PATHS_TESTING)
#import <roothide.h>
#endif
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

NSString * const PXWeaponXDataLogicalPath = @"/var/mobile/Library/WeaponX";
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

NSString *PXCurrentProfileValuesPath(void) {
    return @"current-profile";
}

NSString *PXCurrentProfileIdentityValuesPath(void) {
    return [PXCurrentProfileValuesPath() stringByAppendingPathComponent:@"identity"];
}

NSString *PXCurrentProfileInfoPath(void) {
    return [PXWeaponXDataPath() stringByAppendingPathComponent:@"current_profile.plist"];
}

// Profile projections are dictionaries in current_profile.plist. These path
// shapes identify a value key; no file is opened under Profiles.
static NSString *PXProfileKeyForPath(NSString *path) {
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *profileRoot = [PXCurrentProfileValuesPath() stringByAppendingString:@"/"];
    if ([standardPath hasPrefix:profileRoot]) {
        return [standardPath substringFromIndex:profileRoot.length];
    }
    return nil;
}

static BOOL PXPathIsUnderOldProfilesDirectory(NSString *path) {
    if (![path containsString:@"/Profiles/"]) return NO;
#if defined(PROJECTX_PATHS_TESTING)
    if (!PXTestJBRootConverter) return NO;
#endif
    NSString *root = [[PXWeaponXDataPath() stringByAppendingPathComponent:@"Profiles"]
        stringByAppendingString:@"/"];
    return [path.stringByStandardizingPath hasPrefix:root];
}

BOOL PXProfilePathUsesCurrentFile(NSString *path) {
    if (PXProfileKeyForPath(path)) return YES;
    if (![path hasSuffix:@"/current_profile.plist"]) return NO;
#if defined(PROJECTX_PATHS_TESTING)
    if (!PXTestJBRootConverter) return NO;
#endif
    return [path.stringByStandardizingPath isEqualToString:PXCurrentProfileInfoPath().stringByStandardizingPath];
}

NSDictionary *PXProfileReadContentsAtPath(NSString *profilePath) {
    @synchronized([NSFileManager class]) {
        int directory = open(profilePath.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY);
        if (directory < 0) return nil;
        if (flock(directory, LOCK_SH) != 0) {
            close(directory);
            return nil;
        }
        NSDictionary *profile = [NSDictionary dictionaryWithContentsOfFile:profilePath];
        flock(directory, LOCK_UN);
        close(directory);
        return profile;
    }
}

BOOL PXProfileUpdateContentsAtPath(NSString *profilePath, void (^update)(NSMutableDictionary *profile)) {
    @synchronized([NSFileManager class]) {
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *directoryPath = profilePath.stringByDeletingLastPathComponent;
        if (![files createDirectoryAtPath:directoryPath withIntermediateDirectories:YES
                              attributes:nil error:nil]) return NO;
        int directory = open(directoryPath.fileSystemRepresentation, O_RDONLY);
        if (directory < 0) return NO;
        if (flock(directory, LOCK_EX) != 0) {
            close(directory);
            return NO;
        }
        BOOL exists = [files fileExistsAtPath:profilePath];
        NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:profilePath];
        BOOL valid = !exists || [stored isKindOfClass:[NSDictionary class]];
        BOOL saved = NO;
        if (valid) {
            NSMutableDictionary *profile = [stored mutableCopy] ?:
                [@{@"ProfileName": @"ProjectX", @"values": @{}} mutableCopy];
            update(profile);
            saved = [profile writeToFile:profilePath atomically:NO];
        }
        flock(directory, LOCK_UN);
        close(directory);
        return saved;
    }
}

NSDictionary *PXCurrentProfileValue(NSString *key) {
    if (key.length == 0) return nil;
    NSDictionary *profile = PXProfileReadContentsAtPath(PXCurrentProfileInfoPath());
    id values = profile[@"values"];
    id value = [values isKindOfClass:[NSDictionary class]] ? values[key] : nil;
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

BOOL PXSetCurrentProfileValue(NSString *key, NSDictionary *value) {
    if (key.length == 0 || ![value isKindOfClass:[NSDictionary class]]) return NO;
    return PXProfileUpdateContentsAtPath(PXCurrentProfileInfoPath(), ^(NSMutableDictionary *profile) {
        NSMutableDictionary *values = [profile[@"values"] isKindOfClass:[NSDictionary class]]
            ? [profile[@"values"] mutableCopy] : [NSMutableDictionary dictionary];
        values[key] = value;
        profile[@"values"] = values;
    });
}

NSDictionary *PXProfileReadDictionary(NSString *path) {
    NSString *key = PXProfileKeyForPath(path);
    if (!key) {
        if (PXPathIsUnderOldProfilesDirectory(path)) return nil;
        return PXProfilePathUsesCurrentFile(path)
            ? PXProfileReadContentsAtPath(path)
            : [NSDictionary dictionaryWithContentsOfFile:path];
    }
    return PXCurrentProfileValue(key);
}

BOOL PXProfileWriteDictionary(NSDictionary *dictionary, NSString *path) {
    NSString *key = PXProfileKeyForPath(path);
    if (!key) {
        if (PXPathIsUnderOldProfilesDirectory(path)) return NO;
        if (!PXProfilePathUsesCurrentFile(path)) {
            return [dictionary writeToFile:path atomically:YES];
        }
        return PXProfileUpdateContentsAtPath(path, ^(NSMutableDictionary *profile) {
            for (NSString *field in @[@"ProfileName", @"Description"]) {
                if (dictionary[field]) profile[field] = dictionary[field];
            }
        });
    }
    return PXSetCurrentProfileValue(key, dictionary);
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
