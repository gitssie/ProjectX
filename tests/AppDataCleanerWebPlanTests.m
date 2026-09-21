#import <Foundation/Foundation.h>
#include <assert.h>

#import "AppDataCleaner.h"
#import "PXRootHidePath.h"

static NSString *TestJBRootConverter(NSString *logicalPath) {
    return [@"/private/randomized/.jbroot-CLEANER-TEST"
        stringByAppendingPathComponent:[logicalPath substringFromIndex:1]];
}

static NSString *TestRootFSConverter(NSString *rootFSPath) {
    return [@"/rootfs" stringByAppendingPathComponent:[rootFSPath substringFromIndex:1]];
}

static NSString *createTemporaryDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"AppDataCleanerWebPlanTests-%@", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:path
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&error]);
    assert(error == nil);
    return path;
}

static void createDirectory(NSString *path) {
    NSError *error = nil;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:path
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&error]);
    assert(error == nil);
}

static void createFile(NSString *path) {
    createDirectory(path.stringByDeletingLastPathComponent);
    assert([@"fixture" writeToFile:path
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:nil]);
}

static NSString *createContainer(NSString *basePath,
                                 NSString *name,
                                 id metadataIdentifier) {
    NSString *container = [basePath stringByAppendingPathComponent:name];
    createDirectory(container);
    NSDictionary *metadata = @{ @"MCMMetadataIdentifier": metadataIdentifier };
    assert([metadata writeToFile:[container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"] atomically:YES]);
    return container;
}

static BOOL arrayContainsPathSuffix(NSArray<NSString *> *paths, NSString *suffix) {
    for (NSString *path in paths) {
        if ([path hasSuffix:suffix]) {
            return YES;
        }
    }
    return NO;
}

static void removeFixture(NSString *root) {
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
}

@interface EnumerationForbiddenFileManager : NSFileManager
@property (nonatomic, copy) NSString *forbiddenEnumerationPath;
@end

@implementation EnumerationForbiddenFileManager

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    if ([path isEqualToString:self.forbiddenEnumerationPath]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadNoPermissionError
                                     userInfo:@{NSFilePathErrorKey: path}];
        }
        return nil;
    }
    return [super contentsOfDirectoryAtPath:path error:error];
}

@end

@interface InaccessibleBaseFileManager : NSFileManager
@property (nonatomic, copy) NSString *inaccessibleBasePath;
@end

@implementation InaccessibleBaseFileManager

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if ([path isEqualToString:self.inaccessibleBasePath]) {
        if (isDirectory) {
            *isDirectory = NO;
        }
        return NO;
    }
    return [super fileExistsAtPath:path isDirectory:isDirectory];
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path
                                                            error:(NSError **)error {
    if ([path isEqualToString:self.inaccessibleBasePath]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadNoPermissionError
                                     userInfo:@{NSFilePathErrorKey: path}];
        }
        return nil;
    }
    return [super attributesOfItemAtPath:path error:error];
}

@end

@interface RecordingContainerURLLookup : NSObject <PXAppDataContainerURLLookup>
@property (nonatomic, strong) NSURL *containerURL;
@property (nonatomic, strong) NSError *lookupError;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *createRequests;
@end

@implementation RecordingContainerURLLookup

- (instancetype)init {
    self = [super init];
    if (self) {
        _createRequests = [NSMutableArray array];
    }
    return self;
}

- (NSURL *)containerURLForBundleIdentifier:(NSString *)bundleIdentifier
                         createIfNecessary:(BOOL)createIfNecessary
                                      error:(NSError **)error {
    assert([bundleIdentifier isEqualToString:@"com.example.target"]);
    [self.createRequests addObject:@(createIfNecessary)];
    if (error) {
        *error = self.lookupError;
    }
    return self.containerURL;
}

@end

static void testRegistryContainerURLIsTheOnlyRawContainerSource(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"Containers/Data/Application"];
    NSString *currentContainer = createContainer(dataBase,
                                                 @"CURRENT-CONTAINER",
                                                 @"com.example.target");
    NSString *webData = [currentContainer stringByAppendingPathComponent:
        @"Library/WebKit/WebsiteData/LocalStorage/origin.localstorage"];
    createFile(webData);

    RecordingContainerURLLookup *registryLookup = [[RecordingContainerURLLookup alloc] init];
    registryLookup.containerURL = [NSURL fileURLWithPath:currentContainer];
    PXTrustedContainerResolver *resolver = [[PXTrustedContainerResolver alloc]
        initWithRegistryLookup:registryLookup];
    PXTrustedContainerResolution *resolution =
        [resolver resolutionForBundleIdentifier:@"com.example.target"];

    assert([registryLookup.createRequests isEqualToArray:@[@NO]]);
    assert(resolution.candidateURLs.count == 1);
    assert([resolution.candidateURLs.firstObject.path isEqualToString:
        registryLookup.containerURL.path]);

    EnumerationForbiddenFileManager *fileManager =
        [[EnumerationForbiddenFileManager alloc] init];
    fileManager.forbiddenEnumerationPath = dataBase;
    NSError *error = nil;
    PXWebDataCleanupPlan *plan = [PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:resolution.candidateURLs
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:fileManager
        error:&error];
    assert(plan != nil);
    assert(error == nil);
    assert([plan executeWithFileManager:fileManager error:&error]);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:webData]);
    removeFixture(fixtureRoot);
}

static void testRegistryLookupFailureReturnsItsConcreteErrorWithoutFallback(void) {
    RecordingContainerURLLookup *registryLookup = [[RecordingContainerURLLookup alloc] init];
    registryLookup.lookupError = [NSError errorWithDomain:@"test.launchservices"
                                                      code:71
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                      @"containerURL denied"}];
    PXTrustedContainerResolution *resolution = [[[PXTrustedContainerResolver alloc]
        initWithRegistryLookup:registryLookup]
        resolutionForBundleIdentifier:@"com.example.target"];

    assert([registryLookup.createRequests isEqualToArray:@[@NO]]);
    assert(resolution.candidateURLs.count == 0);
    assert(resolution.authoritativeError == registryLookup.lookupError);
    assert([resolution.outcomes isEqualToArray:@[@"ls-container-url-error"]]);
}

static void testMissingTrustedCandidateReportsItsResolutionOutcome(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"rootfs/var/mobile/Containers/Data/Application"];
    createDirectory(dataBase);
    NSURL *missingTrustedURL = [NSURL fileURLWithPath:[dataBase
        stringByAppendingPathComponent:@"MISSING-CONTAINER"]];

    NSError *error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[missingTrustedURL]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorContainerNotFound);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"ls-container-url-missing-on-filesystem"]);
    assert([error.localizedDescription containsString:@"does not exist"]);
    removeFixture(fixtureRoot);
}

static void testUnreadableTrustedCandidateReportsItsResolutionOutcome(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"rootfs/var/mobile/Containers/Data/Application"];
    NSString *targetContainer = createContainer(dataBase,
                                                 @"TARGET-CONTAINER",
                                                 @"com.example.target");
    InaccessibleBaseFileManager *fileManager = [[InaccessibleBaseFileManager alloc] init];
    fileManager.inaccessibleBasePath = targetContainer;

    NSError *error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[[NSURL fileURLWithPath:targetContainer]]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:fileManager
        error:&error] == nil);
    assert([error.domain isEqualToString:NSCocoaErrorDomain]);
    assert(error.code == NSFileReadNoPermissionError);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"trusted-candidate-unreadable"]);
    removeFixture(fixtureRoot);
}

static void testTrustedMetadataMismatchReportsItsResolutionOutcome(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"rootfs/var/mobile/Containers/Data/Application"];
    createDirectory(dataBase);
    NSString *otherContainer = createContainer(dataBase,
                                                @"OTHER-CONTAINER",
                                                @"com.example.other");

    NSError *error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[[NSURL fileURLWithPath:otherContainer]]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"ls-container-url-owner-mismatch"]);
    removeFixture(fixtureRoot);
}

static void testTrustedExactContainerAvoidsBroadRootHideEnumeration(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"rootfs/var/mobile/Containers/Data/Application"];
    createDirectory(dataBase);
    NSString *targetContainer = createContainer(dataBase,
                                                 @"TARGET-CONTAINER",
                                                 @"com.example.target");
    NSString *otherContainer = createContainer(dataBase,
                                                @"OTHER-CONTAINER",
                                                @"com.example.other");
    NSString *targetWebData = [targetContainer stringByAppendingPathComponent:
        @"Library/WebKit/WebsiteData/LocalStorage/target.localstorage"];
    NSString *otherWebData = [otherContainer stringByAppendingPathComponent:
        @"Library/WebKit/WebsiteData/LocalStorage/preserved.localstorage"];
    createFile(targetWebData);
    createFile(otherWebData);

    EnumerationForbiddenFileManager *fileManager =
        [[EnumerationForbiddenFileManager alloc] init];
    fileManager.forbiddenEnumerationPath = dataBase;
    NSError *error = nil;
    PXWebDataCleanupPlan *plan = [PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[[NSURL fileURLWithPath:targetContainer]]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:fileManager
        error:&error];

    assert(plan != nil);
    assert(error == nil);
    assert([plan.containerRoots isEqualToArray:@[
        targetContainer.stringByResolvingSymlinksInPath
    ]]);
    assert([plan executeWithFileManager:fileManager error:&error]);
    assert(error == nil);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:targetWebData]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:otherWebData]);
    removeFixture(fixtureRoot);
}

static void testSafariPlanClearsWebsiteStateAndPreservesSensitiveData(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"Containers/Data/Application"];
    NSString *libraryRoot = [fixtureRoot stringByAppendingPathComponent:@"Mobile/Library"];
    createDirectory(dataBase);
    createDirectory(libraryRoot);
    createContainer(dataBase, @"SAFARI-CONTAINER", @"com.apple.mobilesafari");

    NSArray<NSString *> *removableRelativePaths = @[
        @"Safari/History.db",
        @"Safari/History.db-wal",
        @"Safari/History.db-shm",
        @"Safari/TopSites.db",
        @"Safari/TopSites.db-wal",
        @"Safari/TopSites.db-shm",
        @"Cookies/Cookies.sqlite",
        @"Cookies/Cookies.sqlite-wal",
        @"Cookies/Cookies.sqlite-shm",
        @"WebKit/WebsiteData/LocalStorage/origin.localstorage",
        @"WebKit/WebsiteData/IndexedDB/indexed.db",
        @"WebKit/WebsiteData/ServiceWorkers/worker.js",
        @"Caches/com.apple.mobilesafari/cache.bin"
    ];
    for (NSString *relativePath in removableRelativePaths) {
        createFile([libraryRoot stringByAppendingPathComponent:relativePath]);
    }
    NSArray<NSString *> *preservedRelativePaths = @[
        @"Safari/Bookmarks.db",
        @"Safari/Bookmarks.db-wal",
        @"Safari/ReadingListArchives/article",
        @"Safari/AutoFillCorrections.db",
        @"Keychains/keychain-2.db",
        @"Accounts/Accounts3.sqlite",
        @"Safari/CloudTabs.db"
    ];
    for (NSString *relativePath in preservedRelativePaths) {
        createFile([libraryRoot stringByAppendingPathComponent:relativePath]);
    }

    NSError *error = nil;
    PXWebDataCleanupPlan *plan = [PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.apple.mobilesafari"
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[libraryRoot]
        fileManager:[NSFileManager defaultManager]
        error:&error];
    assert(plan != nil);
    assert(plan.isSafariTarget);
    assert(arrayContainsPathSuffix(plan.deletionPaths, @"Safari/History.db"));
    assert(arrayContainsPathSuffix(plan.deletionPaths, @"Safari/History.db-wal"));
    assert(arrayContainsPathSuffix(plan.deletionPaths, @"Safari/History.db-shm"));
    assert(arrayContainsPathSuffix(plan.deletionPaths, @"Safari/TopSites.db"));
    NSArray<NSString *> *excludedNames = @[
        @"bookmarks", @"readinglist", @"autofill", @"keychain", @"accounts", @"cloudtabs"
    ];
    for (NSString *path in plan.deletionPaths) {
        NSString *lowercasePath = path.lowercaseString;
        for (NSString *excludedName in excludedNames) {
            assert([lowercasePath rangeOfString:excludedName].location == NSNotFound);
        }
    }

    assert([plan executeWithFileManager:[NSFileManager defaultManager] error:&error]);
    assert(error == nil);
    for (NSString *relativePath in removableRelativePaths) {
        assert(![[NSFileManager defaultManager] fileExistsAtPath:
            [libraryRoot stringByAppendingPathComponent:relativePath]]);
    }
    for (NSString *relativePath in preservedRelativePaths) {
        assert([[NSFileManager defaultManager] fileExistsAtPath:
            [libraryRoot stringByAppendingPathComponent:relativePath]]);
    }
    removeFixture(fixtureRoot);
}

static void testSubstringMalformedAndUntrustedContainersNeverBecomeOwnedRoots(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"Containers/Data/Application"];
    createDirectory(dataBase);
    NSString *substringContainer = createContainer(dataBase,
                                                    @"SUBSTRING-CONTAINER",
                                                    @"com.example.targeted");
    NSString *extensionContainer = createContainer(dataBase,
                                                    @"EXTENSION-CONTAINER",
                                                    @"com.example.target.ShareExtension");
    NSString *malformedContainer = [dataBase stringByAppendingPathComponent:
        @"MALFORMED-CONTAINER"];
    createDirectory(malformedContainer);
    assert([@[@"com.example.target"] writeToFile:[malformedContainer
        stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]
                                      atomically:YES]);
    NSString *nestedIdentifierContainer = createContainer(
        dataBase,
        @"NESTED-IDENTIFIER-CONTAINER",
        @{@"UnrelatedValue": @"com.example.target"});
    createFile([substringContainer stringByAppendingPathComponent:
        @"Library/WebKit/WebsiteData/preserved"]);
    createFile([malformedContainer stringByAppendingPathComponent:
        @"Library/WebKit/WebsiteData/preserved"]);

    NSError *error = nil;
    NSURL *substringURL = [NSURL fileURLWithPath:substringContainer];
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[substringURL]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"ls-container-url-owner-mismatch"]);

    NSURL *extensionURL = [NSURL fileURLWithPath:extensionContainer];
    error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[extensionURL]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"ls-container-url-owner-mismatch"]);

    NSURL *malformedURL = [NSURL fileURLWithPath:malformedContainer];
    error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[malformedURL]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"ls-container-url-metadata-invalid"]);

    NSURL *nestedIdentifierURL = [NSURL fileURLWithPath:nestedIdentifierContainer];
    error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[nestedIdentifierURL]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"ls-container-url-metadata-invalid"]);

    NSString *outsideContainer = createContainer(fixtureRoot,
                                                  @"OUTSIDE-CONTAINER",
                                                  @"com.example.target");
    error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[[NSURL fileURLWithPath:outsideContainer]]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([error.userInfo[@"containerResolutionOutcomes"]
        containsObject:@"trusted-path-rejected"]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:[substringContainer
        stringByAppendingPathComponent:@"Library/WebKit/WebsiteData/preserved"]]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:[malformedContainer
        stringByAppendingPathComponent:@"Library/WebKit/WebsiteData/preserved"]]);
    removeFixture(fixtureRoot);
}

static void testMalformedUnresolvedAndEscapingTargetsFailClosed(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"Containers/Data/Application"];
    createDirectory(dataBase);
    NSError *error = nil;
    assert([PXWebDataCleanupPlan planForBundleIdentifier:@""
                                      containerBasePaths:@[dataBase]
                                      safariLibraryRoots:@[]
                                             fileManager:[NSFileManager defaultManager]
                                                   error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorInvalidBundleIdentifier);
    error = nil;
    assert([PXWebDataCleanupPlan planForBundleIdentifier:@"com..example"
                                      containerBasePaths:@[dataBase]
                                      safariLibraryRoots:@[]
                                             fileManager:[NSFileManager defaultManager]
                                                   error:&error] == nil);
    error = nil;
    assert([PXWebDataCleanupPlan planForBundleIdentifier:@"com.example.target"
                                      containerBasePaths:@[dataBase]
                                      safariLibraryRoots:@[]
                                             fileManager:[NSFileManager defaultManager]
                                                   error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorContainerNotFound);

    NSString *otherContainer = createContainer(dataBase,
                                               @"OTHER-CONTAINER",
                                               @"com.example.other");
    NSString *otherWebData = [otherContainer stringByAppendingPathComponent:
        @"Library/WebKit/WebsiteData/preserved"];
    createFile(otherWebData);
    error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[[NSURL fileURLWithPath:otherContainer]]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([[NSFileManager defaultManager] fileExistsAtPath:otherWebData]);

    NSString *targetContainer = createContainer(dataBase,
                                                @"TARGET-CONTAINER",
                                                @"com.example.target");
    NSString *externalDirectory = [fixtureRoot stringByAppendingPathComponent:@"ExternalWebKit"];
    NSString *externalMarker = [externalDirectory stringByAppendingPathComponent:@"preserved"];
    createFile(externalMarker);
    createDirectory([targetContainer stringByAppendingPathComponent:@"Library"]);
    NSError *linkError = nil;
    assert([[NSFileManager defaultManager]
        createSymbolicLinkAtPath:[targetContainer stringByAppendingPathComponent:@"Library/WebKit"]
             withDestinationPath:externalDirectory
                           error:&linkError]);
    assert(linkError == nil);
    error = nil;
    assert([PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[[NSURL fileURLWithPath:targetContainer]]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    assert([[NSFileManager defaultManager] fileExistsAtPath:externalMarker]);

    error = nil;
    NSString *traversalBase = [dataBase stringByAppendingPathComponent:@"../Application"];
    assert([PXWebDataCleanupPlan planForBundleIdentifier:@"com.example.target"
                                      containerBasePaths:@[traversalBase]
                                      safariLibraryRoots:@[]
                                             fileManager:[NSFileManager defaultManager]
                                                   error:&error] == nil);
    assert(error.code == PXAppDataCleanerErrorUnsafePath);
    removeFixture(fixtureRoot);
}

@interface FailingRemovalFileManager : NSFileManager
@property (nonatomic, copy) NSString *failedPath;
@end

@implementation FailingRemovalFileManager

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    if ([path isEqualToString:self.failedPath]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileWriteNoPermissionError
                                     userInfo:@{NSFilePathErrorKey: path}];
        }
        return NO;
    }
    return [super removeItemAtPath:path error:error];
}

@end

static void testCriticalDeletionFailureIsReturned(void) {
    NSString *fixtureRoot = createTemporaryDirectory();
    NSString *dataBase = [fixtureRoot stringByAppendingPathComponent:
        @"Containers/Data/Application"];
    createDirectory(dataBase);
    NSString *container = createContainer(dataBase,
                                          @"TARGET-CONTAINER",
                                          @"com.example.target");
    NSString *webKitPath = [container stringByAppendingPathComponent:@"Library/WebKit"];
    createFile([webKitPath stringByAppendingPathComponent:@"WebsiteData/data"]);

    NSError *error = nil;
    PXWebDataCleanupPlan *plan = [PXWebDataCleanupPlan
        planForBundleIdentifier:@"com.example.target"
        trustedContainerURLs:@[[NSURL fileURLWithPath:container]]
        containerBasePaths:@[dataBase]
        safariLibraryRoots:@[]
        fileManager:[NSFileManager defaultManager]
        error:&error];
    assert(plan != nil);
    FailingRemovalFileManager *fileManager = [[FailingRemovalFileManager alloc] init];
    fileManager.failedPath = webKitPath.stringByResolvingSymlinksInPath;
    assert(![plan executeWithFileManager:fileManager error:&error]);
    assert(error.code == PXAppDataCleanerErrorDeletionFailed);
    assert([error.userInfo[@"failedPaths"] containsObject:fileManager.failedPath]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:webKitPath]);
    removeFixture(fixtureRoot);
}

int main(void) {
    @autoreleasepool {
        PXSetRootHidePathConvertersForTesting(TestJBRootConverter, TestRootFSConverter);
        testRegistryContainerURLIsTheOnlyRawContainerSource();
        testRegistryLookupFailureReturnsItsConcreteErrorWithoutFallback();
        testMissingTrustedCandidateReportsItsResolutionOutcome();
        testUnreadableTrustedCandidateReportsItsResolutionOutcome();
        testTrustedMetadataMismatchReportsItsResolutionOutcome();
        testTrustedExactContainerAvoidsBroadRootHideEnumeration();
        testSafariPlanClearsWebsiteStateAndPreservesSensitiveData();
        testSubstringMalformedAndUntrustedContainersNeverBecomeOwnedRoots();
        testMalformedUnresolvedAndEscapingTargetsFailClosed();
        testCriticalDeletionFailureIsReturned();
    }
    return 0;
}
