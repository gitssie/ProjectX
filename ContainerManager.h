#import <Foundation/Foundation.h>

@interface ContainerManager : NSObject


// Shared manager accessor
+ (instancetype)sharedManager;
+ (instancetype)sharedInstance;

// Path Translation
- (NSString *)translatePath:(NSString *)originalPath forApp:(NSString *)bundleID;
- (BOOL)isPathRedirectable:(NSString *)path forApp:(NSString *)bundleID;

// Directory Structure
- (NSString *)appDataPath:(NSString *)bundleID;
- (BOOL)prepareAppDataDirectory;

// Translates a real iOS filesystem path into the RootHide bootstrap namespace.
+ (NSString *)translatePathForEnvironment:(NSString *)path;

// System app detection
- (BOOL)isSystemApp:(NSString *)bundleID;

@end 
