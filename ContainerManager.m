#import "ContainerManager.h"
#import "PXRootHidePath.h"
#import <Foundation/Foundation.h>

@interface ContainerManager ()
@property (nonatomic, strong) NSFileManager *fileManager;
@end

@implementation ContainerManager

+ (instancetype)sharedManager {
    static ContainerManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

+ (instancetype)sharedInstance {
    return [self sharedManager];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileManager = [NSFileManager defaultManager];
    }
    return self;
}

#pragma mark - Path Translation

- (NSString *)translatePath:(NSString *)originalPath forApp:(NSString *)bundleID {
    if (!bundleID || !originalPath || originalPath.length == 0) {
        return originalPath;
    }
    
    NSString *appDataPath = [self appDataPath:bundleID];
    return [originalPath stringByReplacingOccurrencesOfString:@"/var/mobile/Library"
                                                  withString:[appDataPath stringByAppendingPathComponent:@"Library"]];
}

- (BOOL)isPathRedirectable:(NSString *)path forApp:(NSString *)bundleID {
    return [path hasPrefix:@"/var/mobile/Library"];
}

#pragma mark - Directory Structure

- (NSString *)appDataPath:(NSString *)bundleID {
    return [[PXWeaponXDataPath() stringByAppendingPathComponent:@"AppData"]
        stringByAppendingPathComponent:bundleID];
}

- (BOOL)prepareAppDataDirectory {
    NSString *basePath = [PXWeaponXDataPath() stringByAppendingPathComponent:@"AppData"];
    NSError *error = nil;
    BOOL success = [self.fileManager createDirectoryAtPath:basePath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&error];
    
    if (!success) {
        NSLog(@"[WeaponX] Failed to prepare app data directory: %@", error);
    }
    
    return success;
}

#pragma mark - System App Detection

- (BOOL)isSystemApp:(NSString *)bundleID {
    if (!bundleID) {
        return NO;
    }
    
    NSString *appPath = PXRootFSPath(
        [NSString stringWithFormat:@"/Applications/%@.app", bundleID]);
    return [self.fileManager fileExistsAtPath:appPath];
}

+ (NSString *)translatePathForEnvironment:(NSString *)path {
    if (!path) {
        return nil;
    }
    
    return [path hasPrefix:@"/"] ? PXRootFSPath(path) : path;
}

@end 
