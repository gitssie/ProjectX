#import "AppDataCleaner.h"
#import "PXRootHidePath.h"

#if !defined(PX_APP_DATA_CLEANER_WEB_PLAN_ONLY)
#import "AppIdentity.h"
#import "IdentifierManager.h"
#import "KeychainCommand.h"
#import "PXKeychainOneShotExecution.h"
#import "ProfileManifest.h"
#import <errno.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>

// Add SearchableIndex framework if available
#import <CoreSpotlight/CoreSpotlight.h>
#endif

NSString * const PXAppDataCleanerErrorDomain = @"com.hydra.projectx.app-data-cleaner";

@interface PXWebDataCleanupPlan ()

@property (nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *containerRoots;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *deletionPaths;
@property (nonatomic, readwrite, getter=isSafariTarget) BOOL safariTarget;
@property (nonatomic, copy) NSArray<NSString *> *validationRoots;

@end

@interface PXTrustedContainerResolution ()

@property (nonatomic, copy, readwrite) NSArray<NSURL *> *candidateURLs;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *outcomes;
@property (nonatomic, strong, readwrite) NSError *authoritativeError;

@end


@interface PXTrustedContainerResolver ()

@property (nonatomic, strong) id<PXAppDataContainerURLLookup> registryLookup;

@end

static void PXSetCleanerError(NSError **error,
                              PXAppDataCleanerErrorCode code,
                              NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
}

static NSError *PXErrorByAddingResolutionOutcome(
    NSError *underlyingError,
    PXAppDataCleanerErrorCode fallbackCode,
    NSString *fallbackDescription,
    NSString *outcome
) {
    NSMutableDictionary<NSString *, id> *userInfo = [underlyingError.userInfo mutableCopy]
        ?: [NSMutableDictionary dictionary];
    if (![userInfo[NSLocalizedDescriptionKey] isKindOfClass:[NSString class]]) {
        userInfo[NSLocalizedDescriptionKey] = fallbackDescription;
    }
    NSMutableOrderedSet<NSString *> *outcomes = [NSMutableOrderedSet orderedSet];
    NSArray *existingOutcomes = [userInfo[@"containerResolutionOutcomes"]
        isKindOfClass:[NSArray class]]
        ? userInfo[@"containerResolutionOutcomes"]
        : @[];
    [outcomes addObjectsFromArray:existingOutcomes];
    [outcomes addObject:outcome];
    userInfo[@"containerResolutionOutcomes"] = outcomes.array;
    NSString *description = userInfo[NSLocalizedDescriptionKey];
    if ([description rangeOfString:outcome].location == NSNotFound) {
        userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:
            @"%@ (resolution outcome: %@)", description, outcome];
    }
    return [NSError errorWithDomain:underlyingError.domain ?: PXAppDataCleanerErrorDomain
                               code:underlyingError ? underlyingError.code : fallbackCode
                           userInfo:userInfo];
}

static BOOL PXPathContainsTraversal(NSString *path) {
    return [path.pathComponents containsObject:@".."];
}

static BOOL PXBundleIdentifierIsValid(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:[NSString class]] ||
        bundleIdentifier.length == 0 || bundleIdentifier.length > 255 ||
        [bundleIdentifier hasPrefix:@"."] || [bundleIdentifier hasSuffix:@"."] ||
        [bundleIdentifier containsString:@".."] ||
        [bundleIdentifier containsString:@"/"] ||
        [bundleIdentifier containsString:@"\\"] ||
        [bundleIdentifier rangeOfString:@"."].location == NSNotFound) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    return [bundleIdentifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *PXCanonicalPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0 ||
        !path.isAbsolutePath || PXPathContainsTraversal(path)) {
        return nil;
    }
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath.stringByStandardizingPath;
}

static BOOL PXPathIsWithinRoot(NSString *path, NSString *root) {
    if (path.length == 0 || root.length == 0 || [path isEqualToString:root]) {
        return NO;
    }
    return [path hasPrefix:[root stringByAppendingString:@"/"]];
}

@implementation PXTrustedContainerResolution
@end


@implementation PXTrustedContainerResolver

- (instancetype)initWithRegistryLookup:(id<PXAppDataContainerURLLookup>)registryLookup {
    self = [super init];
    if (self) {
        _registryLookup = registryLookup;
    }
    return self;
}

- (PXTrustedContainerResolution *)resolutionForBundleIdentifier:(NSString *)bundleIdentifier {
    NSMutableArray<NSURL *> *candidateURLs = [NSMutableArray array];
    NSMutableArray<NSString *> *outcomes = [NSMutableArray array];
    NSError *registryError = nil;
    NSURL *registryURL = [self.registryLookup
        containerURLForBundleIdentifier:bundleIdentifier
        createIfNecessary:NO
        error:&registryError];
    if (registryURL) {
        [outcomes addObject:@"ls-container-url-candidate"];
        [candidateURLs addObject:registryURL];
    } else if (registryError) {
        [outcomes addObject:@"ls-container-url-error"];
    } else if (self.registryLookup) {
        [outcomes addObject:@"ls-container-url-missing"];
    }

    PXTrustedContainerResolution *resolution = [[PXTrustedContainerResolution alloc] init];
    resolution.candidateURLs = candidateURLs;
    resolution.outcomes = outcomes;
    resolution.authoritativeError = registryError;
    return resolution;
}

@end

static NSError *PXContainerResolutionReportedError(
    PXTrustedContainerResolution *resolution,
    NSError *planningError
) {
    NSError *reportedError = resolution.authoritativeError ?: planningError;
    NSArray<NSString *> *planningOutcomes = [planningError.userInfo[@"containerResolutionOutcomes"]
        isKindOfClass:[NSArray class]]
        ? planningError.userInfo[@"containerResolutionOutcomes"]
        : @[];
    for (NSString *outcome in [resolution.outcomes arrayByAddingObjectsFromArray:planningOutcomes]) {
        reportedError = PXErrorByAddingResolutionOutcome(
            reportedError,
            PXAppDataCleanerErrorContainerNotFound,
            @"No exact App data container could be resolved",
            outcome);
    }
    return reportedError ?: [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                                code:PXAppDataCleanerErrorContainerNotFound
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"No exact App data container could be resolved"}];
}

static BOOL PXIsForbiddenDeletionRoot(NSString *path) {
    static NSSet<NSString *> *forbiddenRoots;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        forbiddenRoots = [NSSet setWithArray:@[
            @"/", @"/var", @"/private/var", @"/var/mobile", @"/private/var/mobile",
            PXJBRootPath(@"/"), PXJBRootPath(@"/var"), PXJBRootPath(@"/var/mobile"),
            PXRootFSPath(@"/"), PXRootFSPath(@"/var"), PXRootFSPath(@"/var/mobile")
        ]];
    });
    return [forbiddenRoots containsObject:path];
}

static BOOL PXMetadataValueOwnsBundleIdentifier(id value, NSString *bundleIdentifier) {
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value isEqualToString:bundleIdentifier];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            if (PXMetadataValueOwnsBundleIdentifier(item, bundleIdentifier)) {
                return YES;
            }
        }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        for (id item in [(NSDictionary *)value allValues]) {
            if (PXMetadataValueOwnsBundleIdentifier(item, bundleIdentifier)) {
                return YES;
            }
        }
    }
    return NO;
}

static NSDictionary<NSString *, id> *PXContainerMetadataAtPath(
    NSString *accessPath,
    NSString *canonicalContainerRoot,
    NSError **error
) {
    NSString *metadataPath = [accessPath stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"];
    NSString *canonicalMetadataPath = PXCanonicalPath(metadataPath);
    if (!canonicalMetadataPath ||
        !PXPathIsWithinRoot(canonicalMetadataPath, canonicalContainerRoot)) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorUnsafePath,
                          [NSString stringWithFormat:@"Container metadata escaped its root: %@",
                              metadataPath]);
        return nil;
    }
    NSError *readError = nil;
    NSData *metadataData = [NSData dataWithContentsOfFile:metadataPath
                                                 options:0
                                                   error:&readError];
    if (!metadataData) {
        if (readError.code != NSFileReadNoSuchFileError && error) {
            *error = readError;
        }
        return nil;
    }
    id propertyList = [NSPropertyListSerialization propertyListWithData:metadataData
                                                                 options:NSPropertyListImmutable
                                                                  format:nil
                                                                   error:nil];
    return [propertyList isKindOfClass:[NSDictionary class]] ? propertyList : nil;
}

static void PXAddDatabasePath(NSMutableOrderedSet<NSString *> *relativePaths,
                              NSString *relativePath) {
    [relativePaths addObject:relativePath];
    [relativePaths addObject:[relativePath stringByAppendingString:@"-wal"]];
    [relativePaths addObject:[relativePath stringByAppendingString:@"-shm"]];
}

static NSArray<NSString *> *PXAppWebDataRelativePaths(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSetWithArray:@[
        @"Library/Cookies",
        @"Library/WebKit",
        @"Library/WebKit/WebsiteData",
        @"Library/WebKit/WebsiteData/LocalStorage",
        @"Library/WebKit/WebsiteData/IndexedDB",
        @"Library/WebKit/WebsiteData/Databases",
        @"Library/WebKit/WebsiteData/ServiceWorkers",
        @"Library/WebKit/WebsiteData/WebSQL",
        @"Library/WebsiteData",
        @"Library/LocalStorage",
        @"Library/IndexedDB",
        @"Library/Databases",
        @"Library/ServiceWorkers",
        @"Library/HTTPStorages",
        @"Library/Application Support/WebKit",
        @"Library/Application Support/WebsiteData",
        @"Library/Caches/NSURLCache",
        @"Library/Caches/NetworkCache",
        @"Library/Caches/GPUCache",
        @"Library/Caches/MediaCache",
        @"Library/Caches/WebKit",
        @"Library/Caches/com.apple.WebKit",
        @"Library/Caches/com.apple.WebKit.GPU",
        @"Library/Caches/com.apple.WebKit.Networking",
        @"Library/Caches/com.apple.WebKit.WebContent",
        @"Library/Caches/com.apple.nsurlsessiond"
    ]];
    PXAddDatabasePath(paths, @"Library/Cookies/Cookies.sqlite");
    PXAddDatabasePath(paths, @"Library/HTTPStorages/httpstorages.sqlite");
    PXAddDatabasePath(paths,
                      @"Library/WebKit/WebsiteData/ResourceLoadStatistics/observations.db");
    return paths.array;
}

static NSArray<NSString *> *PXSafariWebDataRelativePaths(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSetWithArray:@[
        @"Safari/RecentlyClosedTabs.plist",
        @"Safari/LastSession.plist",
        @"Safari/Tabs",
        @"Safari/SessionStorage",
        @"Safari/WebsiteData",
        @"Safari/LocalStorage",
        @"Safari/IndexedDB",
        @"Safari/Databases",
        @"Safari/ServiceWorkers",
        @"WebKit/WebsiteData",
        @"WebKit/LocalStorage",
        @"WebKit/IndexedDB",
        @"WebKit/Databases",
        @"WebKit/ServiceWorkers",
        @"WebKit/NetworkCache",
        @"WebKit/GPUCache",
        @"WebKit/MediaCache",
        @"Cookies/Cookies.binarycookies",
        @"Caches/com.apple.mobilesafari",
        @"Caches/com.apple.Safari",
        @"Caches/com.apple.WebKit",
        @"Caches/com.apple.WebKit.Networking"
    ]];
    PXAddDatabasePath(paths, @"Safari/History.db");
    PXAddDatabasePath(paths, @"Safari/TopSites.db");
    PXAddDatabasePath(paths, @"Cookies/Cookies.sqlite");
    return paths.array;
}

static BOOL PXAddValidatedDeletionPath(NSMutableOrderedSet<NSString *> *paths,
                                       NSString *accessRoot,
                                       NSString *validationRoot,
                                       NSString *relativePath,
                                       NSFileManager *fileManager,
                                       NSError **error) {
    NSString *candidate = [accessRoot stringByAppendingPathComponent:relativePath];
    NSString *expectedCanonicalCandidate = [[validationRoot
        stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
    BOOL candidateExists = [fileManager fileExistsAtPath:candidate];
    NSString *canonicalCandidate = candidateExists
        ? PXCanonicalPath(candidate)
        : expectedCanonicalCandidate;
    if (!canonicalCandidate || !PXPathIsWithinRoot(candidate, accessRoot) ||
        !PXPathIsWithinRoot(canonicalCandidate, validationRoot) ||
        PXIsForbiddenDeletionRoot(canonicalCandidate)) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorUnsafePath,
                          [NSString stringWithFormat:@"Unsafe cleanup path rejected: %@", candidate]);
        return NO;
    }
    [paths addObject:candidate];
    return YES;
}

@implementation PXWebDataCleanupPlan

+ (BOOL)isSafariBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *normalized = bundleIdentifier.lowercaseString;
    return [normalized isEqualToString:@"com.apple.mobilesafari"] ||
        [normalized isEqualToString:@"com.apple.webapp"];
}

+ (instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                    trustedContainerURLs:(NSArray<NSURL *> *)trustedContainerURLs
                       containerBasePaths:(NSArray<NSString *> *)containerBasePaths
                       safariLibraryRoots:(NSArray<NSString *> *)safariLibraryRoots
                              fileManager:(NSFileManager *)fileManager
                                   error:(NSError **)error {
    if (!PXBundleIdentifierIsValid(bundleIdentifier)) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorInvalidBundleIdentifier,
                          @"Bundle identifier is empty or malformed");
        return nil;
    }
    if (![fileManager isKindOfClass:[NSFileManager class]]) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorUnsafePath,
                          @"A file manager is required to build a cleanup plan");
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *containerBases =
        [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *resolutionOutcomes =
        [NSMutableOrderedSet orderedSet];
    if (trustedContainerURLs.count == 0) {
        [resolutionOutcomes addObject:@"trusted-candidate-unavailable"];
    }
    for (NSString *basePath in containerBasePaths ?: @[]) {
        NSString *canonicalBase = PXCanonicalPath(basePath);
        if (!canonicalBase || PXIsForbiddenDeletionRoot(canonicalBase)) {
            PXSetCleanerError(error,
                              PXAppDataCleanerErrorUnsafePath,
                              [NSString stringWithFormat:@"Unsafe container base rejected: %@", basePath]);
            return nil;
        }
        [containerBases addObject:@{
            @"access": basePath,
            @"canonical": canonicalBase
        }];
    }

    NSMutableOrderedSet<NSString *> *ownedRoots = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSString *> *accessRootsByCanonicalRoot =
        [NSMutableDictionary dictionary];
    for (id value in trustedContainerURLs ?: @[]) {
        NSURL *containerURL = [value isKindOfClass:[NSURL class]] ? value : nil;
        NSString *accessRoot = containerURL.isFileURL ? containerURL.path : nil;
        NSString *canonicalRoot = PXCanonicalPath(accessRoot);
        NSString *matchingCanonicalBase = nil;
        for (NSDictionary<NSString *, NSString *> *containerBase in containerBases) {
            NSString *canonicalBase = containerBase[@"canonical"];
            if ([[canonicalRoot stringByDeletingLastPathComponent]
                isEqualToString:canonicalBase]) {
                matchingCanonicalBase = canonicalBase;
                break;
            }
        }
        if (!accessRoot || !canonicalRoot || !matchingCanonicalBase ||
            PXIsForbiddenDeletionRoot(canonicalRoot)) {
            if (error) {
                *error = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                             code:PXAppDataCleanerErrorUnsafePath
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Trusted target container is outside an allowed container base",
                    @"containerResolutionOutcomes": @[@"trusted-path-rejected"]
                }];
            }
            return nil;
        }
        NSError *attributesError = nil;
        NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager
            attributesOfItemAtPath:accessRoot
                             error:&attributesError];
        if (!attributes && [attributesError.domain isEqualToString:NSCocoaErrorDomain] &&
            (attributesError.code == NSFileNoSuchFileError ||
             attributesError.code == NSFileReadNoSuchFileError)) {
            if (error) {
                *error = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                             code:PXAppDataCleanerErrorContainerNotFound
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"LSApplicationProxy.containerURL path does not exist",
                    @"containerResolutionOutcomes": @[@"ls-container-url-missing-on-filesystem"]
                }];
            }
            return nil;
        }
        if (!attributes) {
            if (error) {
                *error = PXErrorByAddingResolutionOutcome(
                    attributesError,
                    PXAppDataCleanerErrorUnsafePath,
                    @"Trusted target container could not be inspected",
                    @"trusted-candidate-unreadable");
            }
            return nil;
        }
        if (![attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
            PXSetCleanerError(error,
                              PXAppDataCleanerErrorUnsafePath,
                              @"Trusted target container is not a directory");
            return nil;
        }
        NSError *metadataError = nil;
        NSDictionary<NSString *, id> *metadata = PXContainerMetadataAtPath(
            accessRoot,
            canonicalRoot,
            &metadataError);
        if (metadataError) {
            if (error) {
                *error = metadataError;
            }
            return nil;
        }
        id metadataIdentifier = metadata[@"MCMMetadataIdentifier"];
        if ([metadataIdentifier isKindOfClass:[NSString class]] &&
            [(NSString *)metadataIdentifier isEqualToString:bundleIdentifier]) {
            [ownedRoots addObject:canonicalRoot];
            accessRootsByCanonicalRoot[canonicalRoot] = accessRoot;
            break;
        } else if (metadata && [metadataIdentifier isKindOfClass:[NSString class]]) {
            if (error) {
                *error = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                             code:PXAppDataCleanerErrorUnsafePath
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"LSApplicationProxy.containerURL metadata does not own the selected bundle",
                    @"containerResolutionOutcomes": @[@"ls-container-url-owner-mismatch"]
                }];
            }
        } else {
            if (error) {
                *error = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                             code:PXAppDataCleanerErrorUnsafePath
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"LSApplicationProxy.containerURL metadata is missing or malformed",
                    @"containerResolutionOutcomes": @[@"ls-container-url-metadata-invalid"]
                }];
            }
        }
        return nil;
    }

    BOOL safariTarget = [self isSafariBundleIdentifier:bundleIdentifier];
    if (ownedRoots.count == 0 && !safariTarget) {
        if (error) {
            NSString *description = @"No container owned by the selected bundle could be resolved";
            if (resolutionOutcomes.count > 0) {
                description = [NSString stringWithFormat:@"%@ (resolution outcomes: %@)",
                    description,
                    [resolutionOutcomes.array componentsJoinedByString:@", "]];
            }
            *error = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                         code:PXAppDataCleanerErrorContainerNotFound
                                     userInfo:@{
                NSLocalizedDescriptionKey: description,
                @"containerResolutionOutcomes": resolutionOutcomes.array
            }];
        }
        return nil;
    }

    NSMutableOrderedSet<NSString *> *deletionPaths = [NSMutableOrderedSet orderedSet];
    for (NSString *root in ownedRoots) {
        NSString *accessRoot = accessRootsByCanonicalRoot[root] ?: root;
        for (NSString *relativePath in PXAppWebDataRelativePaths()) {
            if (!PXAddValidatedDeletionPath(
                deletionPaths,
                accessRoot,
                root,
                relativePath,
                fileManager,
                error)) {
                return nil;
            }
        }
    }

    NSMutableOrderedSet<NSString *> *validationRoots = [ownedRoots mutableCopy];
    if (safariTarget) {
        NSUInteger existingSafariRootCount = 0;
        for (NSString *libraryRoot in safariLibraryRoots ?: @[]) {
            NSString *canonicalLibraryRoot = PXCanonicalPath(libraryRoot);
            if (!canonicalLibraryRoot || PXIsForbiddenDeletionRoot(canonicalLibraryRoot) ||
                ![canonicalLibraryRoot.lastPathComponent isEqualToString:@"Library"]) {
                PXSetCleanerError(error,
                                  PXAppDataCleanerErrorUnsafePath,
                                  [NSString stringWithFormat:@"Unsafe Safari library root rejected: %@", libraryRoot]);
                return nil;
            }
            BOOL isDirectory = NO;
            if (![fileManager fileExistsAtPath:canonicalLibraryRoot isDirectory:&isDirectory]) {
                continue;
            }
            if (!isDirectory) {
                PXSetCleanerError(error,
                                  PXAppDataCleanerErrorUnsafePath,
                                  [NSString stringWithFormat:@"Safari library root is not a directory: %@",
                                      libraryRoot]);
                return nil;
            }
            existingSafariRootCount++;
            [validationRoots addObject:canonicalLibraryRoot];
            for (NSString *relativePath in PXSafariWebDataRelativePaths()) {
                if (!PXAddValidatedDeletionPath(
                    deletionPaths,
                    libraryRoot,
                    canonicalLibraryRoot,
                    relativePath,
                    fileManager,
                    error)) {
                    return nil;
                }
            }
        }
        if (existingSafariRootCount == 0) {
            PXSetCleanerError(error,
                              PXAppDataCleanerErrorContainerNotFound,
                              @"No Safari library root could be resolved");
            return nil;
        }
    }

    PXWebDataCleanupPlan *plan = [[self alloc] init];
    plan.bundleIdentifier = [bundleIdentifier copy];
    plan.containerRoots = [[ownedRoots.array
        sortedArrayUsingSelector:@selector(compare:)] copy];
    plan.deletionPaths = [[deletionPaths.array
        sortedArrayUsingSelector:@selector(compare:)] copy];
    plan.safariTarget = safariTarget;
    plan.validationRoots = [[validationRoots.array
        sortedArrayUsingSelector:@selector(compare:)] copy];
    return plan;
}

+ (instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                       containerBasePaths:(NSArray<NSString *> *)containerBasePaths
                       safariLibraryRoots:(NSArray<NSString *> *)safariLibraryRoots
                              fileManager:(NSFileManager *)fileManager
                                    error:(NSError **)error {
    return [self planForBundleIdentifier:bundleIdentifier
                    trustedContainerURLs:@[]
                       containerBasePaths:containerBasePaths
                       safariLibraryRoots:safariLibraryRoots
                              fileManager:fileManager
                                    error:error];
}

- (BOOL)executeWithFileManager:(NSFileManager *)fileManager error:(NSError **)error {
    NSMutableArray<NSString *> *minimalPaths = [NSMutableArray array];
    NSArray<NSString *> *pathsByLength = [self.deletionPaths sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *left, NSString *right) {
            if (left.length < right.length) return NSOrderedAscending;
            if (left.length > right.length) return NSOrderedDescending;
            return [left compare:right];
        }];
    for (NSString *path in pathsByLength) {
        BOOL coveredByParent = NO;
        for (NSString *parent in minimalPaths) {
            if (PXPathIsWithinRoot(path, parent)) {
                coveredByParent = YES;
                break;
            }
        }
        if (!coveredByParent) {
            [minimalPaths addObject:path];
        }
    }

    NSMutableArray<NSError *> *failures = [NSMutableArray array];
    NSMutableArray<NSString *> *failedPaths = [NSMutableArray array];
    for (NSString *path in minimalPaths) {
        if (![fileManager fileExistsAtPath:path]) {
            continue;
        }
        NSString *canonicalPath = PXCanonicalPath(path);
        BOOL isWithinValidationRoot = NO;
        for (NSString *root in self.validationRoots) {
            if (PXPathIsWithinRoot(canonicalPath, root)) {
                isWithinValidationRoot = YES;
                break;
            }
        }
        if (!canonicalPath || !isWithinValidationRoot || PXIsForbiddenDeletionRoot(canonicalPath)) {
            NSError *pathError = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                                      code:PXAppDataCleanerErrorUnsafePath
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                      [NSString stringWithFormat:@"Cleanup path became unsafe: %@", path]}];
            [failures addObject:pathError];
            [failedPaths addObject:path];
            continue;
        }
        NSError *removalError = nil;
        if (![fileManager removeItemAtPath:path error:&removalError]) {
            NSError *reportedError = removalError ?: [NSError
                errorWithDomain:PXAppDataCleanerErrorDomain
                code:PXAppDataCleanerErrorDeletionFailed
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Could not remove web data at %@", path]}];
            [failures addObject:reportedError];
            [failedPaths addObject:path];
        }
    }
    if (failures.count > 0) {
        if (error) {
            *error = [NSError errorWithDomain:PXAppDataCleanerErrorDomain
                                         code:PXAppDataCleanerErrorDeletionFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"One or more critical web-data paths could not be removed",
                NSUnderlyingErrorKey: failures.firstObject,
                @"failedPaths": [failedPaths copy],
                @"underlyingErrors": [failures copy]
            }];
        }
        return NO;
    }
    return YES;
}

@end

#if !defined(PX_APP_DATA_CLEANER_WEB_PLAN_ONLY)

extern char **environ;

static NSString *PXCurrentApplicationDataBasePath(void) {
    return @"/private/var/mobile/Containers/Data/Application";
}

static NSArray<NSString *> *PXDefaultSafariLibraryRoots(void) {
    return @[PXRootFSPath(@"/var/mobile/Library")];
}

// For NSTask compatibility on iOS
@interface NSTask : NSObject
- (void)setLaunchPath:(NSString *)path;
- (void)setArguments:(NSArray *)arguments;
- (void)setStandardOutput:(id)output;
- (void)setStandardError:(id)error;
- (void)launch;
- (void)waitUntilExit;
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)bundleIdentifier;
@property (nonatomic, readonly) NSString *bundleExecutable;
@end

@interface PXLaunchServicesAppDataContainerLookup : NSObject <PXAppDataContainerURLLookup>
@end

@implementation PXLaunchServicesAppDataContainerLookup

- (NSURL *)containerURLForBundleIdentifier:(NSString *)bundleIdentifier
                         createIfNecessary:(BOOL)createIfNecessary
                                      error:(NSError **)error {
    if (createIfNecessary) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorUnsafePath,
                          @"LaunchServices container lookup must not create a container");
        return nil;
    }
    LSApplicationProxy *proxy = [LSApplicationProxy
        applicationProxyForIdentifier:bundleIdentifier];
    SEL containerURLSelector = NSSelectorFromString(@"containerURL");
    if (!proxy || !containerURLSelector || ![proxy respondsToSelector:containerURLSelector]) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorContainerNotFound,
                          @"LSApplicationProxy.containerURL is unavailable for the selected bundle");
        return nil;
    }
    IMP implementation = [proxy methodForSelector:containerURLSelector];
    if (!implementation) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorContainerNotFound,
                          @"LSApplicationProxy.containerURL cannot be read");
        return nil;
    }
    NSURL *(*containerURLGetter)(id, SEL) = (NSURL *(*)(id, SEL))implementation;
    NSURL *containerURL = containerURLGetter(proxy, containerURLSelector);
    if (![containerURL isKindOfClass:[NSURL class]] || !containerURL.isFileURL ||
        !containerURL.path.isAbsolutePath) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorUnsafePath,
                          @"LSApplicationProxy.containerURL returned an invalid file URL");
        return nil;
    }
    return containerURL;
}

@end


static PXTrustedContainerResolution *PXTrustedContainerResolutionForBundleIdentifier(
    NSString *bundleIdentifier
) {
    static PXTrustedContainerResolver *resolver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resolver = [[PXTrustedContainerResolver alloc]
            initWithRegistryLookup:[[PXLaunchServicesAppDataContainerLookup alloc] init]];
    });
    return [resolver resolutionForBundleIdentifier:bundleIdentifier];
}

@implementation AppDataCleaner {
    NSFileManager *_fileManager;
    PXKeychainOneShotController *_keychainOneShotController;
}

+ (instancetype)sharedManager {
    static AppDataCleaner *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileManager = [NSFileManager defaultManager];
        _keychainOneShotController = [[PXKeychainOneShotController alloc]
            initWithExecution:[[PXKeychainOneShotExecution alloc] init]];
    }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)activeKeychainProfileContextWithError:(NSError **)error {
    NSDictionary<NSString *, id> *profileInfo = [NSDictionary dictionaryWithContentsOfFile:
        PXCurrentProfileInfoPath()];
    NSString *profileID = [profileInfo[@"ProfileId"] isKindOfClass:[NSString class]]
        ? profileInfo[@"ProfileId"]
        : nil;
    if (!PXKeychainCommandProfileIdentifierIsValid(profileID)) {
        if (error) {
            *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"No valid active Profile is available for Keychain cleanup"}];
        }
        return nil;
    }
    NSString *identityDirectory = [[IdentifierManager sharedManager].profileIdentityPath
        stringByStandardizingPath];
    NSString *identityProfileID = identityDirectory.stringByDeletingLastPathComponent.lastPathComponent;
    if (identityDirectory.length == 0 ||
        [identityProfileID caseInsensitiveCompare:profileID] != NSOrderedSame) {
        if (error) {
            *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Active Profile metadata does not match its identity directory"}];
        }
        return nil;
    }
    NSError *manifestError = nil;
    PXProfileManifest *manifest = [[[PXProfileStore alloc]
        initWithIdentityDirectory:identityDirectory] activeManifestWithError:&manifestError];
    if (!manifest || manifest.schemaVersion != 5 ||
        ![[NSUUID alloc] initWithUUIDString:manifest.generationID]) {
        if (error) {
            *error = manifestError ?: [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                                          code:11
                                                      userInfo:@{NSLocalizedDescriptionKey: @"Active Profile generation is unavailable or invalid"}];
        }
        return nil;
    }
    return @{
        @"profileID": profileID.lowercaseString,
        @"generationID": manifest.generationID.lowercaseString
    };
}

- (NSArray<NSString *> *)keychainTargetsForBundleID:(NSString *)bundleID
                                    includeAppFamily:(BOOL)includeAppFamily {
    IdentifierManager *manager = [IdentifierManager sharedManager];
    if (!PXAppIdentityBundleIsEligible(bundleID,
                                       [manager isApplicationEnabled:bundleID],
                                       [manager isExtensionEnabled:bundleID])) {
        return @[];
    }
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSetWithObject:bundleID];
    if (!includeAppFamily) {
        return targets.array;
    }
    NSArray *dataDirectories = [self listDirectoriesInPath:
        PXRootFSPath(@"/var/mobile/Containers/Data/Application")];
    NSArray *bundleDirectories = [self listDirectoriesInPath:
        PXRootFSPath(@"/var/containers/Bundle/Application")];
    NSArray<NSDictionary *> *extensions = [self optimized_findExtensionContainers:bundleID
                                                                           dataDirs:dataDirectories
                                                                         bundleDirs:bundleDirectories];
    for (NSDictionary *extension in extensions) {
        NSString *extensionBundleID = [extension[@"bundleID"] isKindOfClass:[NSString class]]
            ? extension[@"bundleID"]
            : nil;
        if (PXAppIdentityBundleIsEligible(extensionBundleID,
                                          [manager isApplicationEnabled:extensionBundleID],
                                          [manager isExtensionEnabled:extensionBundleID])) {
            [targets addObject:extensionBundleID];
        }
    }
    return targets.array;
}

- (void)clearKeychainTargets:(NSArray<NSString *> *)targets
                       index:(NSUInteger)index
                   profileID:(NSString *)profileID
                generationID:(NSString *)generationID
                    responses:(NSMutableArray<PXKeychainCommandResponse *> *)responses
                   completion:(void (^)(BOOL,
                                       NSArray<PXKeychainCommandResponse *> *,
                                       NSError *))completion {
    if (index >= targets.count) {
        completion(YES, [responses copy], nil);
        return;
    }
    NSError *requestError = nil;
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        freshRequestForBundleIdentifier:targets[index]
        profileID:profileID
        generationID:generationID
        includeSharedAccessGroups:NO
        includeSynchronizableItems:NO
        now:[NSDate date]
        ttl:30
        error:&requestError];
    if (!request) {
        completion(NO, [responses copy], requestError);
        return;
    }
    IdentifierManager *manager = [IdentifierManager sharedManager];
    PXKeychainCommandContext *context = [[PXKeychainCommandContext alloc]
        initWithBundleIdentifier:request.targetBundleID
                       profileID:profileID
                    generationID:generationID
              applicationEnabled:[manager isApplicationEnabled:request.targetBundleID]
                extensionEnabled:[manager isExtensionEnabled:request.targetBundleID]];
    NSError *commandError = nil;
    PXKeychainCommandResponse *response = [_keychainOneShotController
        executeRequest:request
        context:context
            now:[NSDate date]
          error:&commandError];
    if (!response || !response.isSuccessful) {
        if (response) {
            [responses addObject:response];
        }
        completion(NO, [responses copy], commandError ?: [NSError
            errorWithDomain:PXKeychainCommandErrorDomain
            code:12
            userInfo:@{NSLocalizedDescriptionKey:
                @"One-shot worker reported incomplete Keychain cleanup"}]);
        return;
    }
    [responses addObject:response];
    [self clearKeychainTargets:targets
                         index:index + 1
                     profileID:profileID
                  generationID:generationID
                     responses:responses
                    completion:completion];
}

- (void)clearKeychainForBundleID:(NSString *)bundleID
                includeAppFamily:(BOOL)includeAppFamily
                      completion:(void (^)(BOOL,
                                           NSArray<PXKeychainCommandResponse *> *,
                                           NSError *))completion {
    [self clearKeychainForBundleID:bundleID
                  includeAppFamily:includeAppFamily
        includeSynchronizableItems:NO
                        completion:completion];
}

- (void)clearKeychainForBundleID:(NSString *)bundleID
                includeAppFamily:(BOOL)includeAppFamily
      includeSynchronizableItems:(BOOL)includeSynchronizableItems
                       completion:(void (^)(BOOL,
                                            NSArray<PXKeychainCommandResponse *> *,
                                            NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (includeSynchronizableItems) {
            completion(NO, @[], [NSError
                errorWithDomain:PXKeychainCommandErrorDomain
                code:14
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Automatic Keychain cleanup never deletes synchronizable items"}]);
            return;
        }
        NSError *contextError = nil;
        NSDictionary<NSString *, NSString *> *profileContext =
            [self activeKeychainProfileContextWithError:&contextError];
        NSArray<NSString *> *targets = [self keychainTargetsForBundleID:bundleID
                                                       includeAppFamily:includeAppFamily];
        if (!profileContext || targets.count == 0) {
            NSError *error = contextError ?: [NSError
                errorWithDomain:PXKeychainCommandErrorDomain
                code:13
                userInfo:@{NSLocalizedDescriptionKey: @"Keychain cleanup target is not an enabled Scoped App"}];
            completion(NO, @[], error);
            return;
        }
        [self clearKeychainTargets:targets
                            index:0
                        profileID:profileContext[@"profileID"]
                     generationID:profileContext[@"generationID"]
                        responses:[NSMutableArray array]
                       completion:completion];
    });
}

#pragma mark - Main Public Methods

- (BOOL)runExecutable:(NSString *)executablePath
             arguments:(NSArray<NSString *> *)arguments
    acceptableExitCodes:(NSIndexSet *)acceptableExitCodes
                  error:(NSError **)error {
    if (executablePath.length == 0 || !executablePath.isAbsolutePath ||
        ![_fileManager isExecutableFileAtPath:executablePath]) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorProcessTerminationFailed,
                          @"Required executable is unavailable");
        return NO;
    }
    NSUInteger argumentCount = arguments.count;
    char **argv = calloc(argumentCount + 2, sizeof(char *));
    if (!argv) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorProcessTerminationFailed,
                          @"Could not allocate process arguments");
        return NO;
    }
    argv[0] = strdup(executablePath.fileSystemRepresentation);
    for (NSUInteger index = 0; index < argumentCount; index++) {
        argv[index + 1] = strdup(arguments[index].UTF8String);
    }

    pid_t processID = 0;
    int spawnStatus = posix_spawn(&processID,
                                  executablePath.fileSystemRepresentation,
                                  NULL,
                                  NULL,
                                  argv,
                                  environ);
    for (NSUInteger index = 0; index < argumentCount + 1; index++) {
        free(argv[index]);
    }
    free(argv);
    if (spawnStatus != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:spawnStatus userInfo:nil];
        }
        return NO;
    }

    int processStatus = 0;
    pid_t waitResult;
    do {
        waitResult = waitpid(processID, &processStatus, 0);
    } while (waitResult < 0 && errno == EINTR);
    if (waitResult < 0 || !WIFEXITED(processStatus) ||
        ![acceptableExitCodes containsIndex:(NSUInteger)WEXITSTATUS(processStatus)]) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorProcessTerminationFailed,
                          @"Target process termination failed");
        return NO;
    }
    return YES;
}

- (BOOL)terminateTargetForWebCleanup:(NSString *)bundleID error:(NSError **)error {
    NSString *executableName = [LSApplicationProxy
        applicationProxyForIdentifier:bundleID].bundleExecutable;
    if (executableName.length == 0 || [executableName containsString:@"/"]) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorProcessTerminationFailed,
                          @"Target App executable is unavailable");
        return NO;
    }
    NSArray<NSString *> *killallPaths = @[PXBootstrapCommandPath(@"killall")];
    NSString *killallPath = nil;
    for (NSString *candidate in killallPaths) {
        if ([_fileManager isExecutableFileAtPath:candidate]) {
            killallPath = candidate;
            break;
        }
    }
    if (!killallPath) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorProcessTerminationFailed,
                          @"No argument-safe target termination mechanism is available");
        return NO;
    }
    NSMutableIndexSet *acceptableExitCodes = [NSMutableIndexSet indexSetWithIndex:0];
    [acceptableExitCodes addIndex:1];
    return [self runExecutable:killallPath
                     arguments:@[@"-9", executableName]
            acceptableExitCodes:acceptableExitCodes
                          error:error];
}

- (BOOL)terminateTargetBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    if (!PXBundleIdentifierIsValid(bundleIdentifier)) {
        PXSetCleanerError(error,
                          PXAppDataCleanerErrorInvalidBundleIdentifier,
                          @"Bundle identifier is empty or malformed");
        return NO;
    }
    return [self terminateTargetForWebCleanup:bundleIdentifier error:error];
}

- (PXWebDataCleanupPlan *)webDataCleanupPlanForBundleID:(NSString *)bundleID
                                                   error:(NSError **)error {
    if ([PXWebDataCleanupPlan isSafariBundleIdentifier:bundleID]) {
        return [PXWebDataCleanupPlan
            planForBundleIdentifier:bundleID
            trustedContainerURLs:@[]
            containerBasePaths:@[]
            safariLibraryRoots:PXDefaultSafariLibraryRoots()
            fileManager:_fileManager
            error:error];
    }
    PXTrustedContainerResolution *containerResolution =
        PXTrustedContainerResolutionForBundleIdentifier(bundleID);
    if (containerResolution.candidateURLs.count != 1) {
        if (error) {
            *error = PXContainerResolutionReportedError(containerResolution, nil);
        }
        return nil;
    }
    PXWebDataCleanupPlan *plan = [PXWebDataCleanupPlan
        planForBundleIdentifier:bundleID
        trustedContainerURLs:containerResolution.candidateURLs
        containerBasePaths:@[PXCurrentApplicationDataBasePath()]
        safariLibraryRoots:@[]
        fileManager:_fileManager
        error:error];
    if (!plan) {
        if (error) {
            *error = PXContainerResolutionReportedError(containerResolution, *error);
        }
        return nil;
    }
    return plan;
}

- (BOOL)clearWebDataForBundleID:(NSString *)bundleID error:(NSError **)error {
    PXWebDataCleanupPlan *plan = [self webDataCleanupPlanForBundleID:bundleID error:error];
    if (!plan) {
        return NO;
    }
    return [self executeWebDataCleanupPlan:plan error:error];
}

- (BOOL)executeWebDataCleanupPlan:(PXWebDataCleanupPlan *)plan error:(NSError **)error {
    if (![self terminateTargetForWebCleanup:plan.bundleIdentifier error:error]) {
        return NO;
    }
    return [plan executeWithFileManager:_fileManager error:error];
}

- (void)clearDataForBundleID:(NSString *)bundleID completion:(void (^)(BOOL, NSError *))completion {
    NSLog(@"[AppDataCleaner] Starting data clearing process for %@", bundleID);
    if (!PXBundleIdentifierIsValid(bundleID)) {
        NSError *invalidBundleError = [NSError
            errorWithDomain:PXAppDataCleanerErrorDomain
            code:PXAppDataCleanerErrorInvalidBundleIdentifier
            userInfo:@{NSLocalizedDescriptionKey: @"Bundle identifier is empty or malformed"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, invalidBundleError);
        });
        return;
    }
    NSError *planningError = nil;
    PXWebDataCleanupPlan *webCleanupPlan = [self
        webDataCleanupPlanForBundleID:bundleID
        error:&planningError];
    if (!webCleanupPlan) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, planningError);
        });
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *cleanupError = nil;
        BOOL success = [webCleanupPlan executeWithFileManager:self->_fileManager
                                                        error:&cleanupError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, cleanupError);
        });
    });
}

#pragma mark - RootHide App Data Wiping

- (void)completeAppDataWipe:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Starting complete wipe for %@", bundleID);
    NSError *webCleanupError = nil;
    if (![self clearWebDataForBundleID:bundleID error:&webCleanupError]) {
        NSLog(@"[AppDataCleaner] Aborting cleanup after critical web-data failure: %@",
              webCleanupError.localizedDescription);
        return;
    }
    if ([PXWebDataCleanupPlan isSafariBundleIdentifier:bundleID]) {
        return;
    }
    
    // --- Optimized: Cache directory listings for this cleaning pass ---
    NSArray *cachedDataDirs = [self listDirectoriesInPath:
        PXRootFSPath(@"/var/mobile/Containers/Data/Application")];
    NSArray *cachedBundleDirs = [self listDirectoriesInPath:
        PXRootFSPath(@"/var/containers/Bundle/Application")];
    NSArray *cachedGroupDirs = [self listDirectoriesInPath:
        PXRootFSPath(@"/var/mobile/Containers/Shared/AppGroup")];

    // Optimized lookups using cached listings
    NSString *dataUUID = [self optimized_findDataContainerUUID:bundleID inDirectories:cachedDataDirs];
    NSArray *groupUUIDs = [self optimized_findAppGroupUUIDs:bundleID inDirectories:cachedGroupDirs];
    NSString *bundleUUID = [self optimized_findBundleContainerUUID:bundleID
                                                     inDirectories:cachedBundleDirs];

    // Find extension containers (pass cached dirs for speed)
    NSLog(@"[AppDataCleaner] Finding extension containers for %@", bundleID);
    NSArray *extensionContainers = [self optimized_findExtensionContainers:bundleID
                                                                    dataDirs:cachedDataDirs
                                                                  bundleDirs:cachedBundleDirs];
    
    NSLog(@"[AppDataCleaner] Found UUIDs - Bundle: %@, Data: %@, Groups: %@, Extensions: %@",
          bundleUUID, dataUUID, groupUUIDs,
          extensionContainers.count > 0 ? extensionContainers : @"Not found");
    
    // Clear data container
    if (dataUUID) {
        NSString *dataContainerPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", dataUUID]);
        NSLog(@"[AppDataCleaner] Fixing permissions for path: %@", dataContainerPath);
        
        // Fix permissions and attributes
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"chmod -R 0777 '%@' 2>/dev/null || true", dataContainerPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"chflags -R nouchg,noschg,nohidden '%@' 2>/dev/null || true", dataContainerPath]];
        
        // Wipe key directories
        NSArray *subDirs = @[
            @"Documents",
            @"Library/Caches",
            @"Library/Preferences",
            @"Library/Saved Application State",
            @"Library/WebKit",
            @"Library/Application Support",
            @"Library/SplashBoard",
            @"Library/Cookies",
            @"Library/UserNotifications",
            @"Library/BackgroundAssets",
            @"Library/PrivateDocuments",
            @"Library/HTTPStorages",
            @"Library/SQLiteDatabases",
            @"Library/Caches/com.apple.nsurlsessiond",
            @"Library/Caches/com.apple.networking*",
            @"tmp"
        ];
        
        // Parallelize directory wipes for speed and safety
        dispatch_group_t wipeGroup = dispatch_group_create();
        for (NSString *dir in subDirs) {
            NSString *fullPath = [dataContainerPath stringByAppendingPathComponent:dir];
            dispatch_group_enter(wipeGroup);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [self wipeDirectoryContents:fullPath keepDirectoryStructure:YES];
                // Special handling for WebKit directory
                if ([dir isEqualToString:@"Library/WebKit"]) {
                    NSLog(@"[AppDataCleaner] Using specialized WebKit cleaning for: %@", fullPath);
                    [self runCommandWithPrivileges:[NSString stringWithFormat:@"chmod -R 777 '%@' 2>/dev/null || true", fullPath]];
                    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'/* 2>/dev/null", fullPath]];
                    // Deep clean WebsiteData directory
                    NSString *websiteDataPath = [fullPath stringByAppendingPathComponent:@"WebsiteData"];
                    NSLog(@"[AppDataCleaner] Deep cleaning WebsiteData at: %@", websiteDataPath);
                    [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -mindepth 1 -maxdepth 1 -not -name '.com.apple*' -exec rm -rf {} \\; 2>/dev/null", websiteDataPath]];
                    [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@/LocalStorage' -type f -exec rm -f {} \\; 2>/dev/null", websiteDataPath]];
                    // Deep clean IndexedDB
                    NSString *indexedDBPath = [websiteDataPath stringByAppendingPathComponent:@"IndexedDB"];
                    NSLog(@"[AppDataCleaner] Deep cleaning IndexedDB at: %@", indexedDBPath);
                    [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type f -exec rm -f {} \\; 2>/dev/null", indexedDBPath]];
                    [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type d -name 'v*' -exec rm -rf {} \\; 2>/dev/null", indexedDBPath]];
                }
                dispatch_group_leave(wipeGroup);
            });
        }
        dispatch_group_wait(wipeGroup, DISPATCH_TIME_FOREVER);
        // End parallelization
    }
    
    // Clear App Store receipt
    [self clearAppReceiptData:bundleID withBundleUUID:bundleUUID];
    
    // Process the real iOS bundle container.
    if (bundleUUID) {
        NSString *bundlePath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@", bundleUUID]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'/*", bundlePath]];
        }
    }
    
    // Process group containers (SAFE: Only app's own groups)
    [self cleanAppGroupContainers:bundleID];
    
    // Process extension containers (SAFE: Only app's own extensions)
    if (extensionContainers.count > 0) {
        dispatch_group_t extGroup = dispatch_group_create();
        for (NSDictionary *extInfo in extensionContainers) {
            NSString *extDataUUID = extInfo[@"dataUUID"];
            NSString *containerPath = PXRootFSPath(
                [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", extDataUUID]);
            NSLog(@"[AppDataCleaner] Wiping extension container: %@ (%@)", containerPath, extInfo[@"bundleID"]);
            dispatch_group_enter(extGroup);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [self completelyWipeContainer:containerPath];
                dispatch_group_leave(extGroup);
            });
        }
        dispatch_group_wait(extGroup, DISPATCH_TIME_FOREVER);
    } else {
        NSLog(@"[AppDataCleaner] No extension containers found to clear for %@", bundleID);
    }
    
    // Clear PluginKit data
    NSLog(@"[AppDataCleaner] Clearing PluginKit and extension data for %@", bundleID);
    [self clearPluginKitData:bundleID];
    
    // Additional paths to wipe (SAFE: Only app's own files, no wildcards outside app scope)
    NSArray *additionalPaths = @[
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/%@", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Spotlight/%@", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Application Support/%@", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/SpringBoard/ApplicationState/%@.plist", bundleID])
    ];
    dispatch_group_t addPathsGroup = dispatch_group_create();
    for (NSString *path in additionalPaths) {
        dispatch_group_enter(addPathsGroup);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSLog(@"[AppDataCleaner] Wiping additional path: %@", path);
            [self fixPermissionsAndRemovePath:path];
            dispatch_group_leave(addPathsGroup);
        });
    }
    dispatch_group_wait(addPathsGroup, DISPATCH_TIME_FOREVER);
    
    // Clear URL credentials
    NSLog(@"[AppDataCleaner] Clearing URL credentials for %@", bundleID);
    [self clearURLCredentialsForBundleID:bundleID];
    
    // Clean RootHide var data (SAFE: Only app's own files, no wildcards outside app scope)
    NSLog(@"[AppDataCleaner] Cleaning RootHide var data for %@", bundleID);
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/%@", bundleID])]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleID])]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/root/Library/Preferences/%@.plist", bundleID])]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@.plist", bundleID])]];

    // Clear iCloud-related data
    NSLog(@"[AppDataCleaner] Clearing iCloud-related data for %@", bundleID);
    [self clearICloudData:bundleID];
    
    // Clear app state data
    NSLog(@"[AppDataCleaner] Clearing app state data for %@", bundleID);
    [self _internalClearAppStateData:bundleID];
    
    // Clear URL credentials again
    [self clearURLCredentialsForBundleID:bundleID];
    
    // Clear encrypted data 
    NSLog(@"[AppDataCleaner] Clearing encrypted data for %@", bundleID);
    [self _internalClearEncryptedData:bundleID];
    
    // If we have a data container, verify HTTPStorages are wiped
    if (dataUUID) {
        NSString *authPath = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@/Library/HTTPStorages", dataUUID];
        NSLog(@"[AppDataCleaner] Wiping auth directory: %@", authPath);
        [self wipeDirectoryContents:authPath keepDirectoryStructure:YES];
    }
    
    // Clear Spotlight data
    NSLog(@"[AppDataCleaner] Clearing Spotlight indexes for %@", bundleID);
    [self clearSpotlightIndexes:bundleID];
    
    // Process media data
    NSLog(@"[AppDataCleaner] Clearing media data for %@", bundleID);
    [self clearMediaData:bundleID];
    
    // Process health data
    NSLog(@"[AppDataCleaner] Clearing health data for %@", bundleID);
    [self clearHealthData:bundleID];
    
    // Clean Safari data
    NSLog(@"[AppDataCleaner] Clearing Safari data for %@", bundleID);
    [self clearSafariData:bundleID];
    
    // Clean SiriAnalytics
    [self cleanSiriAnalyticsDatabase:bundleID];
    
    // Clean IconState.plist
    [self cleanIconStatePlist:bundleID];
    
    // Clean LaunchServices database
    [self cleanLaunchServicesDatabase:bundleID];
    
    // Refresh system services to apply changes
    [self refreshSystemServices];
    
    // === FINAL SWEEP FOR 100% COVERAGE ===
    NSLog(@"[AppDataCleaner] Starting final sweep for any remaining traces of %@", bundleID);
    NSMutableArray *finalSweepPaths = [NSMutableArray array];
    if (dataUUID) {
        [finalSweepPaths addObject:PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", dataUUID])];
    }
    for (NSString *groupUUID in groupUUIDs) {
        NSString *path = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/%@", groupUUID]);
        NSLog(@"[AppDataCleaner][Detect] App Group Container: %@", path);
        [finalSweepPaths addObject:path];
    }
    for (NSDictionary *extInfo in extensionContainers) {
        NSString *extDataUUID = extInfo[@"dataUUID"];
        NSString *path = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", extDataUUID]);
        NSLog(@"[AppDataCleaner][Detect] Extension Data Container: %@", path);
        [finalSweepPaths addObject:path];
    }
    // Recursively remove all non-Apple files from each container (parallelized)
    dispatch_apply(finalSweepPaths.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        NSString *containerPath = finalSweepPaths[i];
        NSLog(@"[AppDataCleaner][Sweep] Starting sweep for container: %@", containerPath);
        [self finalSweepForContainer:containerPath];
        NSLog(@"[AppDataCleaner][Sweep] Finished sweep for container: %@", containerPath);
    });
    // Sweep for crash logs and system logs
    [self removeCrashLogsForBundleID:bundleID];
    NSLog(@"[AppDataCleaner] Completed wipe for %@", bundleID);
}

// FINAL SWEEP: Recursively remove all files/folders except .com.apple* or system files
- (void)finalSweepForContainer:(NSString *)containerPath {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:containerPath];
    NSString *item;
    while ((item = [enumerator nextObject])) {
        if (![item.lastPathComponent hasPrefix:@".com.apple"]) {
            NSString *fullPath = [containerPath stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            [fm fileExistsAtPath:fullPath isDirectory:&isDir];
            NSLog(@"[AppDataCleaner][FinalSweep] Deleting: %@", fullPath);
            [self fixPermissionsAndRemovePath:fullPath];
            if ([fm fileExistsAtPath:fullPath]) {
                NSLog(@"[AppDataCleaner][FinalSweep] Could not delete: %@", fullPath);
            }
        }
    }
}

- (void)universalKeychainWipeForBundleID:(NSString *)bundleID {
    [self clearKeychainForBundleID:bundleID
                  includeAppFamily:NO
        includeSynchronizableItems:NO
                        completion:^(BOOL success,
                                     NSArray<PXKeychainCommandResponse *> *responses,
                                     NSError *error) {
        (void)success;
        (void)responses;
        (void)error;
    }];
}

// Remove crash logs and system logs for this bundleID
- (void)removeCrashLogsForBundleID:(NSString *)bundleID {
    NSArray *crashLogDirs = @[
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/private/var/logs/CrashReporter"
    ];
    for (NSString *dir in crashLogDirs) {
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in contents) {
            if ([file containsString:bundleID]) {
                NSString *fullPath = [dir stringByAppendingPathComponent:file];
                [self fixPermissionsAndRemovePath:fullPath];
                if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
                    NSLog(@"[AppDataCleaner][CrashLogSweep] Could not delete crash log: %@", fullPath);
                }
            }
        }
    }
}


// NEW: Method to clear app store receipt data
- (void)clearAppReceiptData:(NSString *)bundleID withBundleUUID:(NSString *)bundleUUID {
    if (!bundleUUID) {
        NSLog(@"[AppDataCleaner] No bundle UUID found for cleaning app receipt");
        return;
    }
    
    NSLog(@"[AppDataCleaner] Clearing App Store receipt for %@", bundleID);
    
    // First find the app name from the bundle directory
    NSString *bundlePath = PXRootFSPath(
        [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@", bundleUUID]);
    NSArray *bundleContents = [self listDirectoriesInPath:bundlePath];
    
    for (NSString *item in bundleContents) {
        if ([item hasSuffix:@".app"]) {
            // Found the app bundle, now target the _MASReceipt directory
            NSString *receiptPath = PXRootFSPath(
                [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@/%@/_MASReceipt",
                 bundleUUID, item]);
            
            NSLog(@"[AppDataCleaner] Wiping app receipt at: %@", receiptPath);
            
            // Use a more aggressive approach due to potential permission issues
            [self fixPermissionsAndRemovePath:receiptPath];
            
            // Create an empty directory to avoid errors 
            [_fileManager createDirectoryAtPath:receiptPath
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:nil];
            break;
        }
    }
}

// NEW: Enhanced method to clear app group containers with better subfolder handling
- (void)clearAppGroupContainers:(NSString *)bundleID withGroupUUIDs:(NSArray *)groupUUIDs {
    NSString *basePath = PXRootFSPath(@"/var/mobile/Containers/Shared/AppGroup/%@");
    
    for (NSString *groupUUID in groupUUIDs) {
        NSString *groupPath = [NSString stringWithFormat:basePath, groupUUID];
        NSLog(@"[AppDataCleaner] Completely wiping app group at: %@", groupPath);
        
        // Use forceful command to clear EVERYTHING inside except Apple metadata
        NSString *forceCommand = [NSString stringWithFormat:@"find '%@' -not -path \"*/.com.apple*\" -not -path \"%@/.com.apple*\" -delete 2>/dev/null || true", groupPath, groupPath];
        [self runCommandWithPrivileges:forceCommand];
        
        // Rebuild essential directory structure
        NSArray *essentialDirs = @[
            @"Library/Caches",
            @"Library/Preferences",
            @"Library/Application Support",
            @"Documents"
        ];
        
        for (NSString *dir in essentialDirs) {
            NSString *dirPath = [NSString stringWithFormat:@"%@/%@", groupPath, dir];
            [_fileManager createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
}

// NEW: Helper method to fix permissions and forcefully remove paths
- (void)fixPermissionsAndRemovePath:(NSString *)path {
    if (![_fileManager fileExistsAtPath:path]) {
        return;
    }
    
    NSLog(@"[AppDataCleaner] Fixing permissions before removal: %@", path);
    
    // Try to fix permissions with chmod and remove flags with chflags
    NSString *chmodCommand = [NSString stringWithFormat:@"chmod -R 0777 '%@' 2>/dev/null || true", path];
    [self runCommandWithPrivileges:chmodCommand];
    
    NSString *chflagsCommand = [NSString stringWithFormat:@"chflags -R nouchg,noschg,nohidden '%@' 2>/dev/null || true", path];
    [self runCommandWithPrivileges:chflagsCommand];
    
    // Try standard file manager removal
    NSError *error;
    BOOL success = [_fileManager removeItemAtPath:path error:&error];
    
    if (!success) {
        NSLog(@"[AppDataCleaner] Standard removal failed: %@", error.localizedDescription);
        
        // Try more aggressive removal with rm -rf
        NSString *rmCommand = [NSString stringWithFormat:@"rm -rf '%@' 2>/dev/null", path];
        [self runCommandWithPrivileges:rmCommand];
    }
}

// Add the Spotlight indexes clearing method
- (void)clearSpotlightIndexes:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing Spotlight indexes for %@", bundleID);
    
    // Use reflection to check if CoreSpotlight is available
    Class csSearchableIndexClass = NSClassFromString(@"CSSearchableIndex");
    if (csSearchableIndexClass) {
        // Use performSelector to avoid direct link dependency
        id defaultIndex = [csSearchableIndexClass performSelector:@selector(defaultSearchableIndex)];
        if (defaultIndex && [defaultIndex respondsToSelector:@selector(deleteSearchableItemsWithDomainIdentifiers:completionHandler:)]) {
            NSLog(@"[AppDataCleaner] Using CSSearchableIndex to clear Spotlight data");
            
            // Create dispatch group to wait for completion
            dispatch_group_t group = dispatch_group_create();
            dispatch_group_enter(group);
            
            // Delete searchable items
            [defaultIndex performSelector:@selector(deleteSearchableItemsWithDomainIdentifiers:completionHandler:) 
                               withObject:@[bundleID]
                               withObject:^(NSError * _Nullable error) {
                if (error) {
                    NSLog(@"[AppDataCleaner] Error clearing Spotlight indexes: %@", error.localizedDescription);
                } else {
                    NSLog(@"[AppDataCleaner] Spotlight indexes cleared successfully");
                }
                dispatch_group_leave(group);
            }];
            
            // Wait for completion with timeout
            dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
            dispatch_group_wait(group, timeout);
        }
    }
    
    // Also manually clear Spotlight directories regardless of API result
    NSArray *spotlightPaths = @[
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Spotlight/%@*", bundleID]),
        PXRootFSPath(@"/var/mobile/Library/Caches/com.apple.Spotlight*")
    ];
    
    for (NSString *pattern in spotlightPaths) {
            NSArray *matches = [self findPathsMatchingPattern:pattern];
            for (NSString *path in matches) {
            NSLog(@"[AppDataCleaner] Removing Spotlight file: %@", path);
                [self securelyWipeFile:path];
        }
    }
}

#pragma mark - UUID Finding Methods

- (NSString *)findBundleUUID:(NSString *)bundleID {
    NSString *bundleRoot = PXRootFSPath(@"/var/containers/Bundle/Application");
    NSArray *bundleDirs = [self listDirectoriesInPath:bundleRoot];
    
    for (NSString *uuid in bundleDirs) {
        NSString *appPath = [bundleRoot stringByAppendingPathComponent:uuid];
        NSArray *appContents = [self listDirectoriesInPath:appPath];
        
        for (NSString *item in appContents) {
            if ([item hasSuffix:@".app"]) {
                NSString *infoPlistPath = [[appPath stringByAppendingPathComponent:item]
                    stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                NSString *itemBundleID = infoPlist[@"CFBundleIdentifier"];
                
                if ([itemBundleID isEqualToString:bundleID]) {
                    return uuid;
                }
            }
        }
    }
    return nil;
}

- (NSString *)findDataContainerUUID:(NSString *)bundleID aggressive:(BOOL)aggressive {
    // Extract company and app short name
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *company = parts.count > 1 ? parts[1] : @"";
    NSString *shortName = parts.lastObject;
    NSString *dataRoot = PXRootFSPath(@"/var/mobile/Containers/Data/Application");
    NSArray *dataDirs = [self listDirectoriesInPath:dataRoot];
    for (NSString *uuid in dataDirs) {
        NSString *containerPath = [dataRoot stringByAppendingPathComponent:uuid];
        NSString *metadataPath = [containerPath
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *containerBundleID = metadata[@"MCMMetadataIdentifier"];
        // 1. Exact match
        if ([containerBundleID isEqualToString:bundleID]) return uuid;
        // 2. Aggressive/fuzzy matching
        if (aggressive) {
            if ([containerBundleID containsString:bundleID] ||
                (company.length && [containerBundleID containsString:company]) ||
                (shortName.length && [containerBundleID containsString:shortName])) {
                NSLog(@"[AppDataCleaner][Aggressive] Matched data container %@ by fuzzy metadata: %@", uuid, containerBundleID);
                return uuid;
            }
            // 3. Scan for app-named files/dirs
            NSArray *contents = [self listDirectoriesInPath:containerPath];
            for (NSString *item in contents) {
                if (([item containsString:bundleID] ||
                     (company.length && [item containsString:company]) ||
                     (shortName.length && [item containsString:shortName]))) {
                    NSLog(@"[AppDataCleaner][Aggressive] Matched data container %@ by file/dir: %@", uuid, item);
                    return uuid;
                }
            }
        }
    }
    return nil;
}

// Default to exact metadata ownership so another app's container is never selected.
- (NSString *)findDataContainerUUID:(NSString *)bundleID {
    return [self findDataContainerUUID:bundleID aggressive:NO];
}

- (NSArray *)findAppGroupUUIDs:(NSString *)bundleID aggressive:(BOOL)aggressive {
    (void)aggressive;
    NSMutableArray *groupUUIDs = [NSMutableArray array];
    NSString *groupRoot = PXRootFSPath(@"/var/mobile/Containers/Shared/AppGroup");
    NSArray *groupDirs = [self listDirectoriesInPath:groupRoot];
    for (NSString *uuid in groupDirs) {
        NSString *metadataPath = [[groupRoot stringByAppendingPathComponent:uuid]
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if (PXMetadataValueOwnsBundleIdentifier(metadata, bundleID)) {
            [groupUUIDs addObject:uuid];
        }
    }
    return groupUUIDs;
}

- (NSArray *)findAppGroupUUIDs:(NSString *)bundleID {
    return [self findAppGroupUUIDs:bundleID aggressive:NO];
}

#pragma mark - Cleaning Methods

- (void)wipeDirectoryContents:(NSString *)path keepDirectoryStructure:(BOOL)keepStructure {
    if (![_fileManager fileExistsAtPath:path]) {
        return;
    }
    
    NSError *error;
    NSArray *contents = [_fileManager contentsOfDirectoryAtPath:path error:&error];
    
    if (error) {
        NSLog(@"[AppDataCleaner] Error listing directory %@: %@", path, error.localizedDescription);
        // Try to recover with force command
        NSString *forceCommand = [NSString stringWithFormat:@"rm -rf '%@'/* 2>/dev/null || true", path];
        [self runCommandWithPrivileges:forceCommand];
        return;
    }
    
    for (NSString *item in contents) {
        NSString *itemPath = [path stringByAppendingPathComponent:item];
        
        // Skip metadata plists if keeping structure
        if (keepStructure && [item hasPrefix:@".com.apple"]) {
            continue;
        }
        
        // Securely delete the file/directory with better error handling
        if (![self securelyWipeFile:itemPath]) {
            // If standard removal fails, try force
            NSLog(@"[AppDataCleaner] Standard wipe failed for %@, using force removal", itemPath);
            [self fixPermissionsAndRemovePath:itemPath];
        }
    }
    
    // Double-check the directory is now empty
    NSArray *remainingContents = [_fileManager contentsOfDirectoryAtPath:path error:&error];
    if (remainingContents.count > 0 && ![remainingContents[0] hasPrefix:@"."]) {
        NSLog(@"[AppDataCleaner] Directory still has content after wiping, using force command: %@", path);
        NSString *forceCommand = [NSString stringWithFormat:@"rm -rf '%@'/* 2>/dev/null || true", path];
        [self runCommandWithPrivileges:forceCommand];
    }
}

- (BOOL)securelyWipeFile:(NSString *)path {
    if (![_fileManager fileExistsAtPath:path]) {
        return YES; // Already doesn't exist
    }
    
    // For directories, recursively wipe contents
    BOOL isDirectory = NO;
    [_fileManager fileExistsAtPath:path isDirectory:&isDirectory];
    
    if (isDirectory) {
        NSDirectoryEnumerator *enumerator = [_fileManager enumeratorAtPath:path];
        NSString *file;
        
        while ((file = [enumerator nextObject])) {
            NSString *fullPath = [path stringByAppendingPathComponent:file];
            [self securelyWipeFile:fullPath];
        }
    }
    
    // Secure overwrite for files (not directories)
    if (!isDirectory) {
    const char *cPath = [path fileSystemRepresentation];
    int fd = open(cPath, O_RDWR);
        if (fd >= 0) {
    off_t fileSize = lseek(fd, 0, SEEK_END);
            if (fileSize > 0) {
    // Multiple pass overwrite
    for (int pass = 0; pass < 3; pass++) {
        lseek(fd, 0, SEEK_SET);
        char *buffer = (char *)calloc(1024, 1);
        
        if (pass == 0) memset(buffer, 0xFF, 1024);  // First pass: 1's
        if (pass == 1) memset(buffer, 0x00, 1024);  // Second pass: 0's
        if (pass == 2) arc4random_buf(buffer, 1024); // Third pass: random
        
        size_t bytesRemaining = fileSize;
        while (bytesRemaining > 0) {
            size_t bytesToWrite = MIN(bytesRemaining, 1024);
            write(fd, buffer, bytesToWrite);
            bytesRemaining -= bytesToWrite;
        }
        
        free(buffer);
    }
            }
    close(fd);
        }
    }
    
    // Finally remove the file/directory
    NSError *error;
    BOOL success = [_fileManager removeItemAtPath:path error:&error];
    if (!success) {
        NSLog(@"[AppDataCleaner] Error removing %@: %@", path, error.localizedDescription);
        
        // Try with higher privileges if normal removal fails
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf \"%@\"", path]];
        
        // Check if it's gone now
        return ![_fileManager fileExistsAtPath:path];
    }
    
    return YES;
}

- (void)clearKeychainItemsForBundleID:(NSString *)bundleID {
    [self clearKeychainForBundleID:bundleID
                  includeAppFamily:NO
        includeSynchronizableItems:NO
                        completion:^(BOOL success,
                                     NSArray<PXKeychainCommandResponse *> *responses,
                                     NSError *error) {
        (void)success;
        (void)responses;
        (void)error;
    }];
#if 0
    NSLog(@"[AppDataCleaner] Clearing keychain items for %@", bundleID);
    
    // More aggressive approach for keychain clearing
    
    // 1. Build an array of possible access groups and service names
    NSMutableArray *possibleAccessGroups = [NSMutableArray arrayWithObjects:
        bundleID,
        [NSString stringWithFormat:@"%@.*", bundleID],
        nil];
    
    // Get the app identifier prefix (team ID) for enterprise apps
    NSArray *bundleComponents = [bundleID componentsSeparatedByString:@"."];
    if (bundleComponents.count >= 2) {
        NSString *appIdPrefix = [NSString stringWithFormat:@"%@.%@", bundleComponents[0], bundleComponents[1]];
        [possibleAccessGroups addObject:appIdPrefix];
        [possibleAccessGroups addObject:[NSString stringWithFormat:@"%@.*", appIdPrefix]];
    }
    
    // Add common group patterns
    [possibleAccessGroups addObject:[NSString stringWithFormat:@"group.%@", bundleID]];
    [possibleAccessGroups addObject:[NSString stringWithFormat:@"%@.group", bundleID]];
    [possibleAccessGroups addObject:[NSString stringWithFormat:@"*%@*", bundleID]]; // Wildcard match
    
    // For Uber and similar apps using Firebase, add these specific groups
    [possibleAccessGroups addObject:@"com.google.firebase.auth"];
    [possibleAccessGroups addObject:@"com.google.HTTPClient"];
    [possibleAccessGroups addObject:@"com.firebase.auth"];
    [possibleAccessGroups addObject:@"com.google.ios.auth"];
    
    // Special groups for delivery/rideshare apps
    [possibleAccessGroups addObject:@"com.uber.keychainaccess"];
    [possibleAccessGroups addObject:@"com.ubercab.keychainaccess"];
    [possibleAccessGroups addObject:@"com.ubercab.UberClient.keychainaccess"]; // Added specific UberClient keychain
    [possibleAccessGroups addObject:@"com.helix.keychainaccess"]; // Added Helix (Uber alternative name)
    [possibleAccessGroups addObject:@"com.lyft.keychainaccess"];
    [possibleAccessGroups addObject:@"com.lyft.ios.keychainaccess"]; // Added com.lyft.ios keychain access
    [possibleAccessGroups addObject:@"com.zimride.instant.keychainaccess"]; // Updated Lyft
    [possibleAccessGroups addObject:@"com.grubhub.search.keychainaccess"]; // Updated GrubHub
    [possibleAccessGroups addObject:@"doordash.DoorDashConsumer.keychainaccess"]; // Updated DoorDash
    [possibleAccessGroups addObject:@"doordash.DoorDashConsumer.5P29S428QN.keychainaccess"]; // DoorDash with profile ID
    [possibleAccessGroups addObject:@"*uber*"];
    [possibleAccessGroups addObject:@"*ubercab*"];
    [possibleAccessGroups addObject:@"*helix*"]; // Added Helix wildcard
    [possibleAccessGroups addObject:@"*lyft*"]; // Keep original Lyft wildcard
    [possibleAccessGroups addObject:@"*zimride*"]; // Added Zimride wildcard
    [possibleAccessGroups addObject:@"*grubhub*"];
    [possibleAccessGroups addObject:@"*doordash*"];
    
    // Even more aggressive - extract keywords from the bundle ID
    for (NSString *component in bundleComponents) {
        if (component.length > 3 && ![component isEqualToString:@"com"] && 
            ![component isEqualToString:@"org"] && ![component isEqualToString:@"net"]) {
            [possibleAccessGroups addObject:[NSString stringWithFormat:@"*%@*", component]];
            [possibleAccessGroups addObject:component];
        }
    }
    
    // 2. Additional search terms for Uber and similar apps
    NSMutableArray *searchTerms = [NSMutableArray arrayWithObject:bundleID];
    
    // Extract app name without com.company prefix
    if (bundleComponents.count > 1) {
        [searchTerms addObject:[bundleComponents lastObject]];
    }

    // Add common keywords for auth data
    [searchTerms addObjectsFromArray:@[
        @"auth", @"token", @"credential", @"session", @"login", 
        @"oauth", @"account", @"user", @"api", @"firebase",
        @"google", @"identity", @"refresh", @"jwt", @"device"
    ]];
    
    // 3. Keychain security classes
    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];
    
    // 4. Very aggressive clearing - iterate through different combinations
    for (id secClass in secClasses) {
        // First try with direct bundle ID match with all items
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        
        // 4.1 Retrieve all items of this class first to inspect them
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        
        if (status == errSecSuccess && result != NULL) {
            NSArray *items = (__bridge_transfer NSArray *)result;
            
            // 4.2 Examine each item to see if it matches our bundle ID or keywords
            for (NSDictionary *item in items) {
                BOOL shouldDelete = NO;
                
                // 4.3 Check access group
                NSString *accessGroup = item[(__bridge id)kSecAttrAccessGroup];
                if (accessGroup) {
                    for (NSString *groupPattern in possibleAccessGroups) {
                        if ([accessGroup containsString:groupPattern] || 
                            ([groupPattern containsString:@"*"] && [accessGroup containsString:[groupPattern stringByReplacingOccurrencesOfString:@"*" withString:@""]])) {
                            shouldDelete = YES;
                            break;
                        }
                    }
                }
                
                // 4.4 Check service name
                NSString *service = item[(__bridge id)kSecAttrService];
                if (!shouldDelete && service) {
                    for (NSString *term in searchTerms) {
                        if ([service containsString:term]) {
                            shouldDelete = YES;
                            break;
                        }
                    }
                }
                
                // 4.5 Check account name
                NSString *account = item[(__bridge id)kSecAttrAccount];
                if (!shouldDelete && account) {
                    for (NSString *term in searchTerms) {
                        if ([account containsString:term]) {
                            shouldDelete = YES;
                            break;
                        }
                    }
                }
                
                // 4.6 Check label
                NSString *label = item[(__bridge id)kSecAttrLabel];
                if (!shouldDelete && label) {
                    for (NSString *term in searchTerms) {
                        if ([label containsString:term]) {
                            shouldDelete = YES;
                            break;
                        }
                    }
                }
                
                // 4.7 If we should delete this item, create a query that matches it exactly
                if (shouldDelete) {
                    NSMutableDictionary *deleteQuery = [NSMutableDictionary dictionaryWithDictionary:@{
                        (__bridge id)kSecClass: secClass
                    }];
                    
                    // Add all available attributes to ensure we match only this item
                    if (accessGroup) deleteQuery[(__bridge id)kSecAttrAccessGroup] = accessGroup;
                    if (service) deleteQuery[(__bridge id)kSecAttrService] = service;
                    if (account) deleteQuery[(__bridge id)kSecAttrAccount] = account;
                    if (label) deleteQuery[(__bridge id)kSecAttrLabel] = label;
                    
                    OSStatus deleteStatus = SecItemDelete((__bridge CFDictionaryRef)deleteQuery);
                    NSLog(@"[AppDataCleaner] Deleted keychain item: %@ (status: %d)", item, (int)deleteStatus);
                }
            }
        }
        
        // 5. Original direct matches approach - keep this for backward compatibility
        for (NSString *accessGroup in possibleAccessGroups) {
            query = @{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecAttrAccessGroup: accessGroup,
                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
        }
        
        // 6. Try service name matches with all search terms
        for (NSString *term in searchTerms) {
            query = @{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecAttrService: term,
                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
        }
        
        // 7. Try account matches with all search terms
        for (NSString *term in searchTerms) {
            query = @{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecAttrAccount: term,
                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
        }
    }
    
    // 8. Clear URL credentials which might store login sessions
    [self clearURLCredentialsForBundleID:bundleID];
    
    // 9. Use command-line security tool as a backup method
    NSString *keychainScript = [NSString stringWithFormat:
                               @"security delete-generic-password -l '%@' 2>/dev/null || true;"
                               @"security delete-internet-password -l '%@' 2>/dev/null || true", 
                               bundleID, bundleID];
    [self runCommandWithPrivileges:keychainScript];
    
    // 10. For Uber and apps like it, clear Google tokens
    [self runCommandWithPrivileges:@"security delete-generic-password -l 'com.google.HTTPClient' 2>/dev/null || true"];
    [self runCommandWithPrivileges:@"security delete-generic-password -l 'com.google.ios.auth' 2>/dev/null || true"];
#endif
}

- (void)clearURLCredentialsForBundleID:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing URL credentials for %@", bundleID);
    
    // Get URL credential storage
    NSURLCredentialStorage *storage = [NSURLCredentialStorage sharedCredentialStorage];
    
    // Get all the host/protection space combinations
    NSDictionary *allCredentials = [storage allCredentials];
    
    // Parse out domain names from the bundle ID (like 'uber' from 'com.ubercab.UberClient')
    NSArray *bundleComponents = [bundleID componentsSeparatedByString:@"."];
    NSMutableArray *possibleDomains = [NSMutableArray array];
    for (NSString *component in bundleComponents) {
        if (component.length > 3 && ![component isEqualToString:@"com"] && 
            ![component isEqualToString:@"org"] && ![component isEqualToString:@"net"]) {
            [possibleDomains addObject:component];
        }
    }
    
    // Loop through all credentials and remove any that might be related to this app
    for (NSURLProtectionSpace *protectionSpace in allCredentials.allKeys) {
        BOOL shouldClear = NO;
        
        // Check if host matches any possible domain
        for (NSString *domain in possibleDomains) {
            if ([protectionSpace.host containsString:domain]) {
                shouldClear = YES;
                break;
            }
        }
        
        // Also check for matches in the realm
        if (!shouldClear && protectionSpace.realm) {
            for (NSString *domain in possibleDomains) {
                if ([protectionSpace.realm containsString:domain]) {
                    shouldClear = YES;
                    break;
                }
            }
        }
        
        if (shouldClear) {
            NSDictionary *credentials = [storage credentialsForProtectionSpace:protectionSpace];
            for (NSString *username in credentials.allKeys) {
                NSURLCredential *credential = credentials[username];
                [storage removeCredential:credential forProtectionSpace:protectionSpace];
                NSLog(@"[AppDataCleaner] Removed credential for %@ at %@", username, protectionSpace.host);
            }
        }
    }
}

- (void)cleanRootHideVarData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Cleaning RootHide var data for %@", bundleID);
    
    // RootHide stores some data in these locations
    NSArray *rootHidePaths = @[
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@*.plist", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/%@", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/%@*", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/tmp/%@*", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/tmp/%@*", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Application Support/%@*", bundleID]),
        // RootHide specific paths
        PXRootFSPath([NSString stringWithFormat:@"/var/root/Library/Preferences/%@*.plist", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@*.plist", bundleID])
    ];
    
    for (NSString *pattern in rootHidePaths) {
        NSArray *matches = [self findPathsMatchingPattern:pattern];
        for (NSString *path in matches) {
            NSLog(@"[AppDataCleaner] Wiping RootHide path: %@", path);
            [self securelyWipeFile:path];
        }
    }
    
    // Use elevated permissions to ensure clean var
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/%@*", bundleID])]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@*", bundleID])]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/root/Library/Preferences/%@*", bundleID])]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@*", bundleID])]];
}

- (void)clearPluginKitData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing PluginKit and extension data for %@", bundleID);
    
    // PluginKit stores data about app extensions which can also contain auth data
    NSArray *pluginKitPaths = @[
        @"/var/mobile/Library/PlugInKit/",
        PXRootFSPath(@"/var/mobile/Library/PlugInKit/"),
        @"/var/mobile/Library/MobileContainerManager/PluginKitPlugin/",
        PXRootFSPath(@"/var/mobile/Library/MobileContainerManager/PluginKitPlugin/")
    ];
    
    for (NSString *basePath in pluginKitPaths) {
        if ([_fileManager fileExistsAtPath:basePath]) {
            // Look for plists and DBs with this app's bundle ID
            NSArray *matches = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@**/%@*", basePath, bundleID]];
            for (NSString *path in matches) {
                NSLog(@"[AppDataCleaner] Wiping PluginKit file: %@", path);
        [self securelyWipeFile:path];
            }
            
            // Also look for any domain components (like "uber" from "com.ubercab.UberClient")
            NSArray *bundleComponents = [bundleID componentsSeparatedByString:@"."];
            for (NSString *component in bundleComponents) {
                if (component.length > 3 && ![component isEqualToString:@"com"] && 
                    ![component isEqualToString:@"org"] && ![component isEqualToString:@"net"]) {
                    matches = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@**/*%@*", basePath, component]];
                    for (NSString *path in matches) {
                        NSLog(@"[AppDataCleaner] Wiping PluginKit file with component %@: %@", component, path);
                        [self securelyWipeFile:path];
                    }
                }
            }
        }
    }
    
    // Check for container manager data
    NSString *containerMgrPath = PXRootFSPath(
        @"/var/mobile/Library/MobileContainerManager/containers.plist");
    if ([_fileManager fileExistsAtPath:containerMgrPath]) {
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"containers.plist.temp"];
        [_fileManager copyItemAtPath:containerMgrPath toPath:tempPath error:nil];
        
        NSMutableDictionary *containers = [NSMutableDictionary dictionaryWithContentsOfFile:tempPath];
        if (containers) {
            BOOL modified = NO;
            NSArray *keys = [containers allKeys];
            for (NSString *key in keys) {
                id value = containers[key];
                if ([value isKindOfClass:[NSDictionary class]]) {
                    NSString *identifier = value[@"identifier"];
                    if ([identifier isKindOfClass:[NSString class]] && [identifier containsString:bundleID]) {
                        [containers removeObjectForKey:key];
                        modified = YES;
                        NSLog(@"[AppDataCleaner] Removed container reference %@ for %@", key, bundleID);
                    }
                }
            }
            
            if (modified) {
                [containers writeToFile:tempPath atomically:YES];
                [self runCommandWithPrivileges:[NSString stringWithFormat:@"cp '%@' '%@'", tempPath, containerMgrPath]];
            }
        }
        
        [_fileManager removeItemAtPath:tempPath error:nil];
    }
}

- (void)clearThumbnailCaches:(NSString *)bundleID {
    NSArray *paths = @[
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/com.apple.thumbnailservices/%@*", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/com.apple.QuickLook.thumbnailcache/%@*", bundleID])
    ];
    
    for (NSString *pattern in paths) {
        NSArray *matches = [self findPathsMatchingPattern:pattern];
        for (NSString *path in matches) {
            NSLog(@"[AppDataCleaner] Wiping thumbnail cache: %@", path);
            [self securelyWipeFile:path];
        }
    }
}

- (void)clearICloudData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing iCloud-related data for %@", bundleID);
    
    // Target iCloud containers, which may contain auth tokens and sync data
    NSArray *iCloudPaths = @[
        PXRootFSPath(@"/var/mobile/Library/Mobile Documents/"),
        PXRootFSPath(@"/var/mobile/Library/Application Support/CloudDocs/"),
        PXRootFSPath(@"/var/mobile/Library/Application Support/CloudKit/"),
        PXRootFSPath(@"/var/mobile/Library/Accounts/")
    ];
    
    // Parse out domain names from the bundle ID (like 'uber' from 'com.ubercab.UberClient')
    NSArray *bundleComponents = [bundleID componentsSeparatedByString:@"."];
    NSMutableArray *searchTerms = [NSMutableArray arrayWithObject:bundleID];
    
    // Add domain component variations to search for iCloud docs
    for (NSString *component in bundleComponents) {
        if (component.length > 3 && ![component isEqualToString:@"com"] && 
            ![component isEqualToString:@"org"] && ![component isEqualToString:@"net"]) {
            [searchTerms addObject:component];
            [searchTerms addObject:[NSString stringWithFormat:@"iCloud.%@", component]];
            [searchTerms addObject:[NSString stringWithFormat:@"%@.icloud", component]];
            [searchTerms addObject:[NSString stringWithFormat:@"com.apple.CloudDocs.%@", component]];
        }
    }
    
    // Look through iCloud paths for matches
    for (NSString *basePath in iCloudPaths) {
        if ([_fileManager fileExistsAtPath:basePath]) {
            for (NSString *term in searchTerms) {
                NSArray *matches = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@**/*%@*", basePath, term]];
                for (NSString *path in matches) {
                    NSLog(@"[AppDataCleaner] Wiping iCloud data: %@", path);
                    
                    if ([_fileManager fileExistsAtPath:path isDirectory:NULL]) {
                        // Fix permissions before removal
                        [self fixPermissionsAndRemovePath:path];
                    }
                }
            }
        }
    }
    
    // Clear iCloud accounts info 
    NSString *accountsDBPath = PXRootFSPath(@"/var/mobile/Library/Accounts/Accounts3.sqlite");
    if ([_fileManager fileExistsAtPath:accountsDBPath]) {
        // We'll use sqlite3 command to delete records related to this app
        for (NSString *term in searchTerms) {
            NSString *sqlCommand = [NSString stringWithFormat:
                                   @"sqlite3 '%@' \"DELETE FROM ZACCOUNT WHERE ZNAME LIKE '%%%@%%' OR ZIDENTIFIER LIKE '%%%@%%' OR ZOWNINGBUNDLEID LIKE '%%%@%%';\"",
                                   accountsDBPath, term, term, term];
            [self runCommandWithPrivileges:sqlCommand];
        }
    }
}

- (void)clearSystemLogs:(NSString *)bundleID {
    NSArray *logPaths = @[
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Logs/CrashReporter/%@*", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Logs/DiagnosticReports/%@*", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/log/asl/*%@*", bundleID]),
        PXRootFSPath([NSString stringWithFormat:@"/var/log/system.log.*%@*", bundleID])
    ];
    
    for (NSString *pattern in logPaths) {
        NSArray *matches = [self findPathsMatchingPattern:pattern];
        for (NSString *path in matches) {
            NSLog(@"[AppDataCleaner] Wiping system log: %@", path);
            [self securelyWipeFile:path];
        }
    }
}

#pragma mark - Helper Methods

- (NSArray *)listDirectoriesInPath:(NSString *)path {
    NSError *error;
    NSArray *contents = [_fileManager contentsOfDirectoryAtPath:path error:&error];
    if (error) {
        NSLog(@"[AppDataCleaner] Error listing directory %@: %@", path, error.localizedDescription);
        return @[];
    }
    return contents;
}

- (BOOL)directoryHasContent:(NSString *)path {
    if (![_fileManager fileExistsAtPath:path]) {
        NSLog(@"[AppDataCleaner] Directory does not exist: %@", path);
        return NO;
    }
    
    NSError *error;
    NSArray *contents = [_fileManager contentsOfDirectoryAtPath:path error:&error];
    
    if (error) {
        NSLog(@"[AppDataCleaner] Error reading directory %@: %@", path, error.localizedDescription);
        return NO;
    }
    
    // Filter out system files that start with .com.apple
    NSMutableArray *nonSystemFiles = [NSMutableArray array];
    for (NSString *item in contents) {
        if (![item hasPrefix:@".com.apple"]) {
            [nonSystemFiles addObject:item];
        }
    }
    
    NSLog(@"[AppDataCleaner] Directory %@ has %lu non-system files", path, (unsigned long)nonSystemFiles.count);
    if (nonSystemFiles.count > 0) {
        NSLog(@"[AppDataCleaner] First few files: %@", [nonSystemFiles subarrayWithRange:NSMakeRange(0, MIN(5, nonSystemFiles.count))]);
    }
    
    return (nonSystemFiles.count > 0);
}

- (NSArray *)findPathsMatchingPattern:(NSString *)pattern {
    NSMutableArray *paths = [NSMutableArray array];
    
    // Create a pipe to read command output
    int pipefds[2];
    pipe(pipefds);
    
    // Set up the find command and arguments
    pid_t pid;
    NSString *findExecutablePath = PXBootstrapCommandPath(@"find");
    const char *findPath = findExecutablePath.fileSystemRepresentation;
    const char *args[] = {
        findPath,
        "-L",  // Follow symbolic links
        "/",
        "-path",
        [pattern UTF8String],
        NULL
    };
    
    // Set up the file actions to redirect output
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, pipefds[0]);
    posix_spawn_file_actions_adddup2(&actions, pipefds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefds[1]);
    
    // Spawn the process
    int status = posix_spawn(&pid, findPath, &actions, NULL, (char *const *)args, NULL);
    
    if (status == 0) {
        // Close write end of pipe in parent
        close(pipefds[1]);
        
        // Read output from the pipe
        NSMutableData *data = [NSMutableData data];
        char buffer[1024];
        ssize_t bytesRead;
        
        while ((bytesRead = read(pipefds[0], buffer, sizeof(buffer))) > 0) {
            [data appendBytes:buffer length:bytesRead];
        }
        
        // Close read end of pipe
        close(pipefds[0]);
        
        // Wait for process to complete
        waitpid(pid, &status, 0);
        
        // Convert output to string and split into paths
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (output) {
            [paths addObjectsFromArray:[output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
        }
    }
    
    // Clean up
    posix_spawn_file_actions_destroy(&actions);
    
    // Filter out empty strings
    return [paths filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [object isKindOfClass:[NSString class]] && [(NSString *)object length] > 0;
    }]];
}

- (void)runCommandWithPrivileges:(NSString *)command {
    NSLog(@"[AppDataCleaner] Running command with privileges: %@", command);
    
    pid_t pid;
    NSString *shellPath = PXJBRootPath(@"/bin/sh");
    const char *args[] = {shellPath.fileSystemRepresentation, "-c", command.UTF8String, NULL};
    int spawnStatus = posix_spawn(&pid,
                                  shellPath.fileSystemRepresentation,
                                  NULL,
                                  NULL,
                                  (char *const *)args,
                                  environ);
    if (spawnStatus != 0) {
        NSLog(@"[AppDataCleaner] Failed to spawn RootHide shell: %d", spawnStatus);
        return;
    }
    if (waitpid(pid, NULL, 0) < 0) {
        NSLog(@"[AppDataCleaner] Failed to wait for RootHide shell: %s", strerror(errno));
    }
}

- (BOOL)verifyDataCleared:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Verifying data cleared for %@", bundleID);
    
    // Create an array to store paths that weren't cleared properly
    NSMutableArray *unclearedPaths = [NSMutableArray array];
    
    // 1. Verify app data container is cleared
    NSString *dataContainerUUID = [self findDataContainerUUID:bundleID];
    if (dataContainerUUID) {
        NSString *dataContainerPath = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", dataContainerUUID];
        [self verifyClearedPath:dataContainerPath reportingTo:unclearedPaths];
    }
    
    // 2. Verify bundle container
    NSString *bundleContainerUUID = [self findBundleContainerUUID:bundleID];
    if (bundleContainerUUID) {
        NSString *bundleContainerPath = [NSString stringWithFormat:@"/var/mobile/Containers/Bundle/Application/%@", bundleContainerUUID];
        [self verifyClearedPath:bundleContainerPath reportingTo:unclearedPaths];
    }
    
    // 3. Verify group containers
    NSArray *groupContainerUUIDs = [self findGroupContainerUUIDsForBundleID:bundleID];
    for (NSString *groupUUID in groupContainerUUIDs) {
        NSString *groupContainerPath = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/%@", groupUUID];
        [self verifyClearedPath:groupContainerPath reportingTo:unclearedPaths];
    }
    
    // 4. Verify extension containers
    NSArray *extensionDataUUIDs = [self findExtensionDataContainersForBundleID:bundleID];
    for (NSString *extensionUUID in extensionDataUUIDs) {
        NSString *extensionPath = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", extensionUUID];
        [self verifyClearedPath:extensionPath reportingTo:unclearedPaths];
    }
    
    // 5. Verify system paths
    NSArray *systemPaths = @[
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleID],
        [NSString stringWithFormat:@"/var/mobile/Library/Caches/%@", bundleID],
        [NSString stringWithFormat:@"/var/mobile/Library/Application Support/%@", bundleID],
        [NSString stringWithFormat:@"/var/mobile/Library/SpringBoard/ApplicationState/%@.plist", bundleID]
    ];
    
    for (NSString *path in systemPaths) {
        if ([_fileManager fileExistsAtPath:path]) {
            [unclearedPaths addObject:@{
                @"path": path,
                @"info": @"System path still exists"
            }];
        }
    }
    
    // 6. Filter out special paths and expected system-created directories before reporting.
    // Keychain verification is completed in the target process before this filesystem phase.
    NSMutableArray *filteredPaths = [NSMutableArray array];
    for (NSDictionary *item in unclearedPaths) {
        NSString *path = item[@"path"];
        NSString *info = item[@"info"];
        
        // Skip SiriAnalytics.db which we've specially cleaned
        if ([path containsString:@"SiriAnalytics.db"]) {
            continue;
        }
        
        // Skip IconState.plist which we've specially cleaned
        if ([path containsString:@"IconState.plist"]) {
            continue;
        }
        
        // Skip app container paths that only contain system directories
        if ([path containsString:@"/var/mobile/Containers/Data/Application"] && 
            ([info containsString:@"StoreKit"] || 
             [info containsString:@"Directory has 0 non-system files"] ||
             [info containsString:@"Directory has 1 non-system files: Documents"] ||
             [info containsString:@"Directory has 2 non-system files: Documents, Library"] ||
             [info containsString:@"Directory has 3 non-system files: Documents, Library, tmp"] ||
             [info containsString:@"Directory has 4 non-system files: StoreKit, Documents, Library, tmp"])) {
            continue;
        }
        
        [filteredPaths addObject:item];
    }
    
    // 8. Final verification summary
    if (filteredPaths.count > 0) {
        NSLog(@"[AppDataCleaner] ⚠️ WARNING: Verification found %lu uncleared data paths:", (unsigned long)filteredPaths.count);
        for (NSDictionary *item in filteredPaths) {
            NSLog(@"[AppDataCleaner] - UNCLEARED: %@ (%@)", item[@"path"], item[@"info"]);
        }
        return NO;
    } else {
        NSLog(@"[AppDataCleaner] ✅ All data successfully cleared for %@", bundleID);
        return YES;
    }
}

// Helper method to verify a path is properly cleaned
- (void)verifyClearedPath:(NSString *)path reportingTo:(NSMutableArray *)unclearedPaths {
    if (![_fileManager fileExistsAtPath:path]) {
        return; // Path doesn't exist, so it's clean
    }
    
    // Check if it's a directory
    BOOL isDirectory = NO;
    [_fileManager fileExistsAtPath:path isDirectory:&isDirectory];
    
    if (isDirectory) {
        NSError *error;
        NSArray *contents = [_fileManager contentsOfDirectoryAtPath:path error:&error];
        
        if (error) {
            [unclearedPaths addObject:@{
                @"path": path,
                @"info": [NSString stringWithFormat:@"Error listing directory: %@", error.localizedDescription]
            }];
            return;
        }
        
        NSMutableArray *nonSystemFiles = [NSMutableArray array];
        
        for (NSString *item in contents) {
            // Skip system metadata files and empty system-created directories
            if ([item hasPrefix:@".com.apple"] || 
                [item isEqualToString:@"StoreKit"] || 
                [item isEqualToString:@"Documents"] || 
                [item isEqualToString:@"Library"] || 
                [item isEqualToString:@"tmp"]) {
                continue;
            }
            
            NSString *fullPath = [path stringByAppendingPathComponent:item];
            BOOL itemIsDirectory = NO;
            [_fileManager fileExistsAtPath:fullPath isDirectory:&itemIsDirectory];
            
            // Check if it's an empty directory (system created)
            if (itemIsDirectory) {
                NSArray *subContents = [_fileManager contentsOfDirectoryAtPath:fullPath error:nil];
                if (subContents.count == 0 || [self containsOnlySystemFiles:subContents]) {
                    continue; // Skip empty directories or directories with only system files
                }
            }
            
            [nonSystemFiles addObject:item];
        }
        
        if (nonSystemFiles.count > 0) {
            // Directory has non-system files
            NSString *infoString = [NSString stringWithFormat:@"Directory has %lu non-system files: %@", 
                                   (unsigned long)nonSystemFiles.count, 
                                   [nonSystemFiles count] > 4 ? 
                                   [[nonSystemFiles subarrayWithRange:NSMakeRange(0, MIN(4, nonSystemFiles.count))] componentsJoinedByString:@", "] : 
                                   [nonSystemFiles componentsJoinedByString:@", "]];
            
            [unclearedPaths addObject:@{
                @"path": path,
                @"info": infoString
            }];
        }
    } else {
        // It's a file, report it
        [unclearedPaths addObject:@{
            @"path": path,
            @"info": @"File exists"
        }];
    }
}

// Helper to check if an array contains only system files
- (BOOL)containsOnlySystemFiles:(NSArray *)files {
    for (NSString *file in files) {
        if (![file hasPrefix:@".com.apple"]) {
            return NO;
        }
    }
    return YES;
}

// Verify keychain items are properly cleared
- (void)verifyKeychainClearedForBundleID:(NSString *)bundleID reportingTo:(NSMutableArray *)unclearedPaths {
    (void)bundleID;
    (void)unclearedPaths;
#if 0
    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];
    
    for (id secClass in secClasses) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        
        if (status == errSecSuccess && result != NULL) {
            NSArray *items = (__bridge_transfer NSArray *)result;
            
            for (NSDictionary *item in items) {
                NSString *service = item[(__bridge id)kSecAttrService];
                NSString *account = item[(__bridge id)kSecAttrAccount];
                NSString *accessGroup = item[(__bridge id)kSecAttrAccessGroup];
                NSString *label = item[(__bridge id)kSecAttrLabel];
                
                // Check for any keychain items related to our bundle ID
                if (([service containsString:bundleID]) ||
                    ([account containsString:bundleID]) ||
                    ([accessGroup containsString:bundleID]) ||
                    ([label containsString:bundleID])) {
                    
                    [unclearedPaths addObject:@{
                        @"path": @"Keychain",
                        @"info": [NSString stringWithFormat:@"Item still exists: service=%@, account=%@, group=%@, label=%@",
                                 service ?: @"nil", account ?: @"nil", accessGroup ?: @"nil", label ?: @"nil"]
                    }];
                }
                
                // Also check component matches (like "uber" from "com.ubercab.UberClient")
                NSArray *components = [bundleID componentsSeparatedByString:@"."];
                for (NSString *component in components) {
                    if (component.length > 3 && ![component isEqualToString:@"com"] && 
                        ![component isEqualToString:@"org"] && ![component isEqualToString:@"net"]) {
                        
                        if (([service containsString:component]) ||
                            ([account containsString:component]) ||
                            ([accessGroup containsString:component]) ||
                            ([label containsString:component])) {
                            
                            [unclearedPaths addObject:@{
                                @"path": @"Keychain",
                                @"info": [NSString stringWithFormat:@"Item with component '%@' still exists: service=%@, account=%@, group=%@, label=%@",
                                         component, service ?: @"nil", account ?: @"nil", accessGroup ?: @"nil", label ?: @"nil"]
                            }];
                        }
                    }
                }
            }
        }
    }
#endif
}

// Verify SQLite databases don't have references to the app
- (void)verifySQLiteReferencesCleared:(NSString *)bundleID reportingTo:(NSMutableArray *)unclearedPaths {
    NSArray *systemDBs = @[
        @"/var/mobile/Library/SpringBoard/ApplicationHistory.sqlite",
        @"/var/mobile/Library/Assistant/SiriAnalytics.db",
        @"/var/mobile/Library/SpringBoard/IconState.plist"
    ];
    
    for (NSString *dbPath in systemDBs) {
        if ([_fileManager fileExistsAtPath:dbPath]) {
            // For plist files
            if ([dbPath hasSuffix:@".plist"]) {
                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:dbPath];
                NSString *plistStr = [plist description];
                
                if ([plistStr containsString:bundleID]) {
                    [unclearedPaths addObject:@{
                        @"path": dbPath,
                        @"info": @"Plist still contains references to app"
                    }];
                }
            }
            // For SQLite we'll just mark the file for manual inspection
            else if ([dbPath hasSuffix:@".sqlite"] || [dbPath hasSuffix:@".db"]) {
                // We can't easily check SQLite content without sqlite3 libraries
                // So we'll just report these files for manual inspection
                [unclearedPaths addObject:@{
                    @"path": dbPath,
                    @"info": @"SQLite database requires manual inspection"
                }];
            }
        }
    }
}

// Helper to run a command and get its output
- (NSString *)runCommandAndGetOutput:(NSString *)command {
    NSLog(@"[AppDataCleaner] Running command: %@", command);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:PXJBRootPath(@"/bin/sh")];
    [task setArguments:@[@"-c", command]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        NSData *data = [file readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        // Trim whitespace from output
        output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        return output;
    } @catch (NSException *exception) {
        NSLog(@"[AppDataCleaner] Error running command: %@", exception);
        return @"error";
    } @finally {
        [file closeFile];
    }
}

#pragma mark - Public Header Methods

- (BOOL)hasDataToClear:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Checking for data to clear for %@", bundleID);
    
    // Force system to flush pending disk operations
    [self runCommandWithPrivileges:@"sync"];
    
    // Check if there's any data to clear for this bundle ID
    NSString *appDataUUID = [self findDataContainerUUID:bundleID];
    NSArray *appGroupUUIDs = [self findAppGroupUUIDs:bundleID];
    
    NSLog(@"[AppDataCleaner] Found UUIDs - Data: %@, Groups: %@",
          appDataUUID ?: @"Not found", appGroupUUIDs);
    
    // IMPROVEMENT: If we found any containers at all, assume there's data to clear
    // This avoids the "no data" message when containers exist but appear empty
    if (appDataUUID || appGroupUUIDs.count > 0) {
        NSLog(@"[AppDataCleaner] Found containers - assuming app has data to clear");
        
        // Calculate usage for UI display
        NSDictionary *usage = [self getDataUsage:bundleID];
        
        // Store this information in UserDefaults for the ProjectXViewController to access
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:usage forKey:[NSString stringWithFormat:@"DataUsage_%@", bundleID]];
        [defaults synchronize];
        
        return YES;
    }
    
    BOOL hasData = NO;
    
    // Real iOS data container checks.
    if (appDataUUID) {
        NSString *containerPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", appDataUUID]);
        if ([self directoryExistsAndHasAnyContent:containerPath]) {
            NSLog(@"[AppDataCleaner] Found data in application container: %@", containerPath);
            hasData = YES;
        }
    }
    
    // App groups - check entire container, not just top level
    for (NSString *groupUUID in appGroupUUIDs) {
        NSString *groupPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/%@", groupUUID]);
        if ([self directoryExistsAndHasAnyContent:groupPath]) {
            NSLog(@"[AppDataCleaner] Found data in App Group: %@", groupPath);
            hasData = YES;
        }
    }

    // Check preferences
    NSString *prefsPath = PXRootFSPath(
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleID]);
    if ([_fileManager fileExistsAtPath:prefsPath]) {
        NSLog(@"[AppDataCleaner] Found preference file: %@", prefsPath);
        hasData = YES;
    }
    
    // NEW: Check for keychain items even if no files found
    if (!hasData && [self hasKeychainItemsForBundleID:bundleID]) {
        NSLog(@"[AppDataCleaner] Found keychain items for %@", bundleID);
        hasData = YES;
    }
    
    // NEW: Check for system database references as a last resort
    if (!hasData) {
        if ([self hasSystemDatabaseReferencesForBundleID:bundleID]) {
            NSLog(@"[AppDataCleaner] Found system database references for %@", bundleID);
            hasData = YES;
        }
    }
    
    // If we have data, calculate size for UI display
    if (hasData) {
        NSDictionary *usage = [self getDataUsage:bundleID];
        
        // Store this information in UserDefaults for the ProjectXViewController to access
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:usage forKey:[NSString stringWithFormat:@"DataUsage_%@", bundleID]];
        [defaults synchronize];
    } else {
        NSLog(@"[AppDataCleaner] No data found to clear for %@", bundleID);
    }
    
    return hasData;
}

// --- Optimized lookup helpers (local to this file, do not break existing API) ---

- (NSString *)optimized_findDataContainerUUID:(NSString *)bundleID inDirectories:(NSArray *)dataDirs {
    NSString *dataRoot = PXRootFSPath(@"/var/mobile/Containers/Data/Application");
    for (NSString *uuid in [dataDirs sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *metadataPath = [[dataRoot stringByAppendingPathComponent:uuid]
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *containerBundleID = metadata[@"MCMMetadataIdentifier"];
        if ([containerBundleID isEqualToString:bundleID]) {
            return uuid;
        }
    }
    return nil;
}

- (NSArray *)optimized_findAppGroupUUIDs:(NSString *)bundleID inDirectories:(NSArray *)groupDirs {
    NSMutableArray *groupUUIDs = [NSMutableArray array];
    NSString *groupRoot = PXRootFSPath(@"/var/mobile/Containers/Shared/AppGroup");
    for (NSString *uuid in [groupDirs sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *metadataPath = [[groupRoot stringByAppendingPathComponent:uuid]
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if (PXMetadataValueOwnsBundleIdentifier(metadata, bundleID)) {
            [groupUUIDs addObject:uuid];
        }
    }
    return groupUUIDs;
}

- (NSString *)optimized_findBundleContainerUUID:(NSString *)bundleID
                                   inDirectories:(NSArray *)bundleDirs {
    __block NSString *result = nil;
    NSString *bundleRoot = PXRootFSPath(@"/var/containers/Bundle/Application");
    dispatch_apply(bundleDirs.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        if (result) return;
        NSString *uuid = bundleDirs[i];
        NSString *appPath = [bundleRoot stringByAppendingPathComponent:uuid];
        NSArray *appContents = [self listDirectoriesInPath:appPath];
        for (NSString *item in appContents) {
            if ([item hasSuffix:@".app"]) {
                NSString *infoPlistPath = [[appPath stringByAppendingPathComponent:item]
                    stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                NSString *itemBundleID = infoPlist[@"CFBundleIdentifier"];
                if ([itemBundleID isEqualToString:bundleID]) { result = uuid; return; }
            }
        }
    });
    return result;
}

- (NSArray *)optimized_findExtensionContainers:(NSString *)bundleID
                                        dataDirs:(NSArray *)dataDirs
                                      bundleDirs:(NSArray *)bundleDirs {
    NSMutableArray *extensionInfo = [NSMutableArray array];
    NSString *dataRoot = PXRootFSPath(@"/var/mobile/Containers/Data/Application");
    dispatch_apply(dataDirs.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        NSString *uuid = dataDirs[i];
        NSString *metadataPath = [[dataRoot stringByAppendingPathComponent:uuid]
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *containerBundleID = metadata[@"MCMMetadataIdentifier"];
        if (containerBundleID && [containerBundleID hasPrefix:bundleID] && ![containerBundleID isEqualToString:bundleID]) {
            // Find bundle UUID for extension
            NSString *extBundleUUID = [self optimized_findBundleContainerUUID:containerBundleID
                                                                  inDirectories:bundleDirs];
            @synchronized(extensionInfo) {
                [extensionInfo addObject:@{ @"bundleID": containerBundleID, @"dataUUID": uuid, @"bundleUUID": extBundleUUID ?: @"", @"type": @"extension" }];
            }
        }
    });
    return extensionInfo;
}

// Helper method to create human-readable file sizes
- (NSString *)humanReadableFileSize:(long long)size {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    return [formatter stringFromByteCount:size];
}

// Implementation of helper methods that map to the main cleaning function
- (void)performFullCleanup:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Starting full cleanup for %@", bundleID);

    // First clear app state data which stores login sessions
    [self _internalClearAppStateData:bundleID];
    
    // Get UUIDs for containers
    NSString *dataUUID = [self findDataContainerUUID:bundleID];
    NSString *bundleUUID = [self findBundleContainerUUID:bundleID];
    
    NSLog(@"[AppDataCleaner] Found UUIDs - Data: %@, Bundle: %@",
          dataUUID ?: @"Not found", bundleUUID ?: @"Not found");
    
    if (dataUUID) {
        [self completelyWipeContainer:PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", dataUUID])];
    }
    
    // Clear all remaining non-Keychain user data after the target process has been terminated.
    [self clearURLCredentialsForBundleID:bundleID];
    [self clearICloudData:bundleID];
    [self clearPluginKitData:bundleID];
    [self clearThumbnailCaches:bundleID];
    [self clearSystemLogs:bundleID];
    [self cleanAppGroupContainers:bundleID];
    [self clearAppReceiptData:bundleID withBundleUUID:bundleUUID];
    [self clearPushNotificationData:bundleID];
    [self clearBluetoothData:bundleID];
    
    // Clear app settings
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@*", bundleID])]];
    
    // Clear encrypted data
    [self _internalClearEncryptedData:bundleID];
    
    // Process iOS 15+ specific issues
    [self clearAppIssuesForIOS15:bundleID];
    
    // NEW: Run app-specific deep cleaning for ride-sharing & food delivery
    
    // Refresh system services to ensure changes are applied
    [self refreshSystemServices];
}

- (void)performSecondaryCleanup:(NSString *)bundleID {
    [self completeAppDataWipe:bundleID];
}

// Implementation of specialized cleanup methods
- (void)clearAppData:(NSString *)bundleID {
    [self completeAppDataWipe:bundleID];
}

- (void)clearAppCache:(NSString *)bundleID {
    NSString *appDataUUID = [self findDataContainerUUID:bundleID];
    
    if (appDataUUID) {
        NSString *cachePath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@/Library/Caches", appDataUUID]);
        [self wipeDirectoryContents:cachePath keepDirectoryStructure:YES];
    }

    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Caches/%@*", bundleID])]];
}

- (void)clearAppPreferences:(NSString *)bundleID {
    NSString *appDataUUID = [self findDataContainerUUID:bundleID];
    
    if (appDataUUID) {
        NSString *prefsPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@/Library/Preferences", appDataUUID]);
        [self wipeDirectoryContents:prefsPath keepDirectoryStructure:YES];
    }

    [self securelyWipeFile:PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleID])];
}

- (void)clearAppCookies:(NSString *)bundleID {
    NSError *error = nil;
    if (![self clearWebDataForBundleID:bundleID error:&error]) {
        NSLog(@"[AppDataCleaner] App cookie cleanup failed: %@", error.localizedDescription);
    }
}

- (void)clearAppWebKitData:(NSString *)bundleID {
    NSError *error = nil;
    if (![self clearWebDataForBundleID:bundleID error:&error]) {
        NSLog(@"[AppDataCleaner] App WebKit cleanup failed: %@", error.localizedDescription);
    }
}

- (void)clearAppKeychain:(NSString *)bundleID {
    [self clearKeychainItemsForBundleID:bundleID];
}

- (void)clearAppGroupData:(NSString *)bundleID {
    NSArray *appGroupUUIDs = [self findAppGroupUUIDs:bundleID];
    
    for (NSString *groupUUID in appGroupUUIDs) {
        NSString *groupPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/%@", groupUUID]);
        [self wipeDirectoryContents:groupPath keepDirectoryStructure:YES];
    }
}

// Map the remaining methods to the main function
- (void)clearKeychainData:(NSString *)bundleID { [self clearKeychainItemsForBundleID:bundleID]; }
- (void)clearSharedContainers:(NSString *)bundleID { [self clearAppGroupData:bundleID]; }
- (void)clearUserDefaults:(NSString *)bundleID { [self clearAppPreferences:bundleID]; }
- (void)clearSQLiteDatabases:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearPrivateVarData:(NSString *)bundleID { [self cleanRootHideVarData:bundleID]; }
- (void)clearDeviceDatabase:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearInstallationLogs:(NSString *)bundleID { [self clearSystemLogs:bundleID]; }
- (void)clearNetworkConfigurations:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearCarrierData:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearNetworkData:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearDNSCache:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearCrashReports:(NSString *)bundleID { [self clearSystemLogs:bundleID]; }
- (void)clearDiagnosticData:(NSString *)bundleID { [self clearSystemLogs:bundleID]; }
- (void)clearBluetoothData:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearPushNotificationData:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearThumbnailCache:(NSString *)bundleID { [self clearThumbnailCaches:bundleID]; }
- (void)clearWebCache:(NSString *)bundleID { [self clearAppWebKitData:bundleID]; }
- (void)clearGameData:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearTemporaryFiles:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearBinaryPlists:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearEncryptedData:(NSString *)bundleID { 
    [self _internalClearEncryptedData:bundleID];
}
- (void)clearJailbreakDetectionLogs:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearSpotlightData:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearSiriData:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearSystemLoggerData:(NSString *)bundleID { [self clearSystemLogs:bundleID]; }
- (void)clearASLLogs:(NSString *)bundleID { [self clearSystemLogs:bundleID]; }
- (void)clearClipboard { 
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    [pasteboard setItems:@[]];
}
- (void)clearPasteboardData:(NSString *)bundleID { [self clearClipboard]; }
- (void)clearURLCache:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearBackgroundAssets:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearSharedStorage:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }
- (void)clearAppStateData:(NSString *)bundleID {
    [self _internalClearAppStateData:bundleID];
}
- (void)secureDataWipe:(NSString *)bundleID { [self completeAppDataWipe:bundleID]; }

- (NSDictionary *)getDataUsage:(NSString *)bundleID {
    NSMutableDictionary *usage = [NSMutableDictionary dictionary];
    
    // Calculate app data usage
    NSString *appDataUUID = [self findDataContainerUUID:bundleID];
    if (appDataUUID) {
        NSString *dataPath = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", appDataUUID];
        usage[@"dataSize"] = @([self calculateDirectorySize:dataPath]);
    }
    
    // Calculate app bundle size
    NSString *bundleUUID = [self findBundleUUID:bundleID];
    if (bundleUUID) {
        NSString *bundlePath = [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@", bundleUUID];
        usage[@"bundleSize"] = @([self calculateDirectorySize:bundlePath]);
    }
    
    // Calculate shared data size
    NSArray *appGroupUUIDs = [self findAppGroupUUIDs:bundleID];
    long long sharedSize = 0;
    for (NSString *groupUUID in appGroupUUIDs) {
        NSString *groupPath = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/%@", groupUUID];
        sharedSize += [self calculateDirectorySize:groupPath];
    }
    usage[@"sharedSize"] = @(sharedSize);
    
    // Total size
    long long total = [usage[@"dataSize"] longLongValue] + 
                    [usage[@"bundleSize"] longLongValue] + 
                    [usage[@"sharedSize"] longLongValue];
    usage[@"totalSize"] = @(total);
    
    return usage;
}

// Helper method for getDataUsage
- (long long)calculateDirectorySize:(NSString *)path {
    if (![_fileManager fileExistsAtPath:path]) {
        return 0;
    }
    
    NSError *error = nil;
    NSDictionary *attributes = [_fileManager attributesOfItemAtPath:path error:&error];
    if (error) {
        return 0;
    }
    
    if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
        return [attributes[NSFileSize] longLongValue];
    }
    
    NSArray *contents = [_fileManager contentsOfDirectoryAtPath:path error:&error];
    if (error) {
        return 0;
    }
    
    long long size = 0;
    for (NSString *item in contents) {
        NSString *fullPath = [path stringByAppendingPathComponent:item];
        NSDictionary *itemAttribs = [_fileManager attributesOfItemAtPath:fullPath error:&error];
        if (error) {
            continue;
        }
        
        if ([itemAttribs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
            size += [self calculateDirectorySize:fullPath];
        } else {
            size += [itemAttribs[NSFileSize] longLongValue];
        }
    }
    
    return size;
}

// Add a specialized method for WebKit directories to handle the recursion issues
- (void)wipeWebKitDirectoryContents:(NSString *)path {
    if (![_fileManager fileExistsAtPath:path]) {
        return;
    }
    
    NSLog(@"[AppDataCleaner] Using specialized WebKit cleaning for: %@", path);
    
    // 1. First fix permissions at root level
    NSString *permissionCommand = [NSString stringWithFormat:@"chmod -R 777 '%@' 2>/dev/null || true", path];
    [self runCommandWithPrivileges:permissionCommand];
    
    // 2. Create a separate process to clean WebKit with appropriate permissions
    NSString *command = [NSString stringWithFormat:@"rm -rf '%@'/* 2>/dev/null", path];
    [self runCommandWithPrivileges:command];
    
    // 3. Specifically target WebsiteData subdirectory with all storage types
    NSString *websiteDataPath = [path stringByAppendingPathComponent:@"WebsiteData"];
    if ([_fileManager fileExistsAtPath:websiteDataPath]) {
        NSLog(@"[AppDataCleaner] Deep cleaning WebsiteData at: %@", websiteDataPath);
        
        // Use find command to handle any nested storage structure (more robust)
        NSString *command = [NSString stringWithFormat:@"find '%@' -mindepth 1 -maxdepth 1 -not -name '.com.apple*' -exec rm -rf {} \\; 2>/dev/null", websiteDataPath];
        [self runCommandWithPrivileges:command];
        
        // Recreate standard WebKit storage directories to avoid crashes
        NSArray *webStorageDirs = @[
            @"LocalStorage",
            @"IndexedDB",
            @"WebSQL",
            @"ServiceWorkers",
            @"CacheStorage"
        ];
        
        for (NSString *dir in webStorageDirs) {
            NSString *dirPath = [websiteDataPath stringByAppendingPathComponent:dir];
            [_fileManager createDirectoryAtPath:dirPath 
                    withIntermediateDirectories:YES 
                                     attributes:nil 
                                          error:nil];
        }
    }
    
    // 4. Forcefully remove LocalStorage (often contains auth tokens)
    NSString *localStoragePath = [websiteDataPath stringByAppendingPathComponent:@"LocalStorage"];
    command = [NSString stringWithFormat:@"find '%@' -type f -exec rm -f {} \\; 2>/dev/null", localStoragePath];
    [self runCommandWithPrivileges:command];
    
    // 5. Specific handling for IndexedDB to ensure we catch all nested structures
    NSString *indexedDBPath = [websiteDataPath stringByAppendingPathComponent:@"IndexedDB"];
    NSLog(@"[AppDataCleaner] Deep cleaning IndexedDB at: %@", indexedDBPath);
    
    // Use find with greater depth to catch all nested structure
    command = [NSString stringWithFormat:@"find '%@' -type f -exec rm -f {} \\; 2>/dev/null", indexedDBPath];
    [self runCommandWithPrivileges:command];
    command = [NSString stringWithFormat:@"find '%@' -type d -name 'v*' -exec rm -rf {} \\; 2>/dev/null", indexedDBPath];
    [self runCommandWithPrivileges:command];
}

// Add new method to handle app state data cleaning for modern apps
- (void)_internalClearAppStateData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing app state data for %@", bundleID);
    
    // Clear app state data which can contain login sessions
    NSArray *statePaths = @[
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/SpringBoard/ApplicationState/%@.plist", bundleID])
    ];
    
    for (NSString *path in statePaths) {
            [self securelyWipeFile:path];
    }
    
    // Modern apps also store state in FrontBoard
    NSArray *frontBoardPaths = [self findPathsMatchingPattern:PXRootFSPath(
        [NSString stringWithFormat:@"/var/mobile/Library/FrontBoard/*/%@*", bundleID])];
    for (NSString *path in frontBoardPaths) {
        [self securelyWipeFile:path];
    }
    // iOS 15+ has additional state storage locations
    NSArray *modernStatePaths = @[
        // LiveActivities state
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/LiveActivities/%@*", bundleID]),
        // App state in different format
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/SpringBoard/RecentlyTerminatedAppState/%@*", bundleID]),
        // Backgrounding state
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/BackgroundTasks/*/%@*", bundleID]),
        // Permission state
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/TCC/*/%@*", bundleID]),
        // Additional state locations
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Containers/*/Data/System/com.apple.nsurlsessiond/SessionData/%@*", bundleID]),
        // iOS 15 specific frontend state
        PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/com.apple.UIKit.SplitView.%@.plist", bundleID])
    ];
    
    for (NSString *pattern in modernStatePaths) {
        NSArray *matches = [self findPathsMatchingPattern:pattern];
        for (NSString *path in matches) {
            NSLog(@"[AppDataCleaner] Wiping modern state file: %@", path);
            [self securelyWipeFile:path];
        }
    }
}

// Override the existing clearAppStateData method to call our internal implementation

// Fix for line ~1757 - Replace the duplicate clearEncryptedData
- (void)_internalClearEncryptedData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing encrypted data for %@", bundleID);
    
    // 1. Check for encrypted plist files in preferences
    NSArray *encryptedPrefs = [self findPathsMatchingPattern:PXRootFSPath(
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@*.enc*", bundleID])];
    encryptedPrefs = [encryptedPrefs arrayByAddingObjectsFromArray:
                     [self findPathsMatchingPattern:PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@*.encrypted*", bundleID])]];
    encryptedPrefs = [encryptedPrefs arrayByAddingObjectsFromArray:
                     [self findPathsMatchingPattern:PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@*.secure*", bundleID])]];
    
    for (NSString *path in encryptedPrefs) {
        [self securelyWipeFile:path];
    }
    // 2. Find data container for more thorough search
    NSString *dataUUID = [self findDataContainerUUID:bundleID];
    if (dataUUID) {
        NSString *dataPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", dataUUID]);
        
        // 4. Target all encrypted storage formats in data container
        NSArray *encryptionPatterns = @[
            @"*.enc*", @"*.encrypted*", @"*.secure*", @"*.token*", @"*Token*",
            @"*Auth*", @"*auth*", @"*cred*", @"*Cred*", @"*secret*", @"*Secret*",
            @"*login*", @"*Login*", @"*session*", @"*Session*", @"*api*key*",
            @"*firebase*", @"*google*auth*", @"*oauth*", @"*jwt*"
        ];
        
        for (NSString *pattern in encryptionPatterns) {
            NSArray *matches = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@/**/%@", dataPath, pattern]];
        for (NSString *path in matches) {
                NSLog(@"[AppDataCleaner] Wiping encrypted file: %@", path);
            [self securelyWipeFile:path];
        }
    }
        
        // 5. Specifically target Google/Firebase auth folders
        NSArray *googlePaths = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@/**/Google*/", dataPath]];
        for (NSString *path in googlePaths) {
            NSLog(@"[AppDataCleaner] Wiping Google auth directory: %@", path);
            [self wipeDirectoryContents:path keepDirectoryStructure:YES];
        }
        
        // 6. Target Firebase-related files
        NSArray *firebasePaths = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@/**/Firebase*/", dataPath]];
        for (NSString *path in firebasePaths) {
            NSLog(@"[AppDataCleaner] Wiping Firebase directory: %@", path);
            [self wipeDirectoryContents:path keepDirectoryStructure:YES];
        }
        
        // 7. Target OAuth directories
        NSArray *oauthPaths = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@/**/*oauth*/", dataPath]];
        for (NSString *path in oauthPaths) {
            NSLog(@"[AppDataCleaner] Wiping OAuth directory: %@", path);
            [self wipeDirectoryContents:path keepDirectoryStructure:YES];
        }
        
        // 8. Uber-specific directories (other apps use similar patterns)
        NSArray *authDirs = @[
            @"Library/Application Support/Credentials",
            @"Library/Application Support/Authentication",
            @"Library/Application Support/GoogleService-Info",
            @"Library/Application Support/Google/FIRApp",
            @"Library/Application Support/com.firebase",
            @"Library/Caches/com.google.firebase",
            @"Library/Caches/com.firebase",
            @"Library/HTTPStorages"
        ];
        
        for (NSString *dir in authDirs) {
            NSString *fullPath = [dataPath stringByAppendingPathComponent:dir];
            if ([_fileManager fileExistsAtPath:fullPath]) {
                NSLog(@"[AppDataCleaner] Wiping auth directory: %@", fullPath);
                [self wipeDirectoryContents:fullPath keepDirectoryStructure:YES];
            }
        }
    }
    
    // 9. Check app group containers
    NSArray *appGroupUUIDs = [self findAppGroupUUIDs:bundleID];
    for (NSString *groupUUID in appGroupUUIDs) {
        NSString *groupPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/%@", groupUUID]);
        
        // Look for encrypted/auth files in group containers
        NSArray *encryptionPatterns = @[
            @"*.enc*", @"*.encrypted*", @"*.secure*", @"*.token*", @"*Token*",
            @"*Auth*", @"*auth*", @"*cred*", @"*Cred*", @"*secret*", @"*Secret*"
        ];
        
        for (NSString *pattern in encryptionPatterns) {
            NSArray *matches = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@/**/%@", groupPath, pattern]];
        for (NSString *path in matches) {
                NSLog(@"[AppDataCleaner] Wiping encrypted file in group: %@", path);
            [self securelyWipeFile:path];
        }
    }
}
}

// Override the existing clearEncryptedData method to call our internal implementation

// Add this method to handle clearing secure storage

// Add this new method to explicitly find extension containers
- (NSArray *)findExtensionContainers:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Finding extension containers for %@", bundleID);
    NSMutableArray *extensionInfo = [NSMutableArray array];
    
    // 1. Find extension data containers in the real iOS filesystem.
    NSString *dataRoot = PXRootFSPath(@"/var/mobile/Containers/Data/Application");
    NSArray *allDataContainers = [self listDirectoriesInPath:dataRoot];
    
    for (NSString *uuid in allDataContainers) {
        NSString *metadataPath = [[dataRoot stringByAppendingPathComponent:uuid]
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *containerBundleID = metadata[@"MCMMetadataIdentifier"];
        
        // Check if this is an extension of our app (extensions often have the app's bundle ID as a prefix)
        if (containerBundleID && 
            [containerBundleID hasPrefix:bundleID] && 
            ![containerBundleID isEqualToString:bundleID]) {
            
            NSLog(@"[AppDataCleaner] Found extension data container: %@ for %@", uuid, containerBundleID);
            
            // Also search for the corresponding bundle UUID
            NSString *extBundleUUID = [self findBundleUUIDForExtension:containerBundleID];
            
            [extensionInfo addObject:@{
                @"bundleID": containerBundleID,
                @"dataUUID": uuid,
                @"bundleUUID": extBundleUUID ?: @"",
                @"type": @"extension"
            }];
        }
    }
    // 2. Also check PluginKitPlugin containers which can contain extension data.
    NSArray *pluginKitPaths = [self findPathsMatchingPattern:
        PXRootFSPath(@"/var/mobile/Containers/Data/PluginKitPlugin/*")];
    for (NSString *pluginPath in pluginKitPaths) {
        NSString *metadataPath = [pluginPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        
        NSString *containerID = metadata[@"MCMMetadataIdentifier"];
        if (containerID && [containerID hasPrefix:bundleID]) {
            NSString *uuid = [pluginPath lastPathComponent];
            NSLog(@"[AppDataCleaner] Found PluginKit container: %@ for %@", uuid, containerID);
            
            [extensionInfo addObject:@{
                @"bundleID": containerID,
                @"dataUUID": uuid,
                @"type": @"pluginkit"
            }];
        }
    }
    NSLog(@"[AppDataCleaner] Found %lu extension containers for %@", (unsigned long)extensionInfo.count, bundleID);
    return extensionInfo;
}

// Find bundle UUID for an extension
- (NSString *)findBundleUUIDForExtension:(NSString *)extensionBundleID {
    NSString *bundleRoot = PXRootFSPath(@"/var/containers/Bundle/Application");
    NSArray *bundleDirs = [self listDirectoriesInPath:bundleRoot];
    
    for (NSString *uuid in bundleDirs) {
        NSString *appPath = [bundleRoot stringByAppendingPathComponent:uuid];
        NSArray *appContents = [self listDirectoriesInPath:appPath];
        
        // Extensions are often in a Plugins or PlugIns directory
        for (NSString *item in appContents) {
            if ([item hasSuffix:@".app"] || [item hasSuffix:@".appex"] || 
                [item isEqualToString:@"PlugIns"] || [item isEqualToString:@"Plugins"]) {
                
                // Check if this is the extension's bundle
                if ([item hasSuffix:@".appex"]) {
                    NSString *infoPlistPath = [[appPath stringByAppendingPathComponent:item]
                        stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                    NSString *itemBundleID = infoPlist[@"CFBundleIdentifier"];
                    
                    if ([itemBundleID isEqualToString:extensionBundleID]) {
                        return uuid;
                    }
                } 
                // Check in Plugins/PlugIns directory for extension bundles
                else if ([item isEqualToString:@"PlugIns"] || [item isEqualToString:@"Plugins"]) {
                    NSString *pluginsPath = [appPath stringByAppendingPathComponent:item];
                    NSArray *plugins = [self listDirectoriesInPath:pluginsPath];
                    
                    for (NSString *plugin in plugins) {
                        if ([plugin hasSuffix:@".appex"]) {
                            NSString *infoPlistPath = [[pluginsPath stringByAppendingPathComponent:plugin]
                                stringByAppendingPathComponent:@"Info.plist"];
                            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                            NSString *itemBundleID = infoPlist[@"CFBundleIdentifier"];
                            
                            if ([itemBundleID isEqualToString:extensionBundleID]) {
                                return uuid;
                            }
                        }
                    }
                }
            }
        }
    }
    
    return nil;
}

// Method to clear extension containers
- (void)clearExtensionContainers:(NSArray *)extensionInfo forApp:(NSString *)bundleID {
    if (extensionInfo.count == 0) {
        NSLog(@"[AppDataCleaner] No extension containers found to clear for %@", bundleID);
        return;
    }
    
    NSLog(@"[AppDataCleaner] Clearing %lu extension containers for %@", (unsigned long)extensionInfo.count, bundleID);
    
    for (NSDictionary *extension in extensionInfo) {
        NSString *extensionBundleID = extension[@"bundleID"];
        NSString *dataUUID = extension[@"dataUUID"];
        NSString *bundleUUID = extension[@"bundleUUID"];
        NSString *type = extension[@"type"];
        
        // 1. Clear extension data container
        if (dataUUID.length > 0) {
            NSString *basePath = PXRootFSPath(@"/var/mobile/Containers/Data/");
            
            NSString *containerType = [type isEqualToString:@"pluginkit"] ? @"PluginKitPlugin" : @"Application";
            NSString *dataPath = [NSString stringWithFormat:@"%@%@/%@", basePath, containerType, dataUUID];
            
            NSLog(@"[AppDataCleaner] Clearing extension data container: %@", dataPath);
            
            // Fix permissions first
            [self fixPermissionsForPath:dataPath];
            
            // Clear important directories
            NSArray *subDirs = @[
                        @"Documents",
                        @"Library/Caches",
                        @"Library/Preferences",
                        @"Library/WebKit",
                        @"Library/Application Support",
                @"tmp"
            ];
            
            for (NSString *subDir in subDirs) {
                NSString *fullPath = [dataPath stringByAppendingPathComponent:subDir];
                
                if ([subDir isEqualToString:@"Library/WebKit"]) {
                    [self wipeWebKitDirectoryContents:fullPath];
                } else {
                    [self wipeDirectoryContents:fullPath keepDirectoryStructure:YES];
                }
            }
            
            // Clear databases
            NSArray *dbFiles = [self findPathsMatchingPattern:[NSString stringWithFormat:@"%@/Library/**/*.sqlite*", dataPath]];
            for (NSString *dbPath in dbFiles) {
                [self securelyWipeFile:dbPath];
                [self securelyWipeFile:[dbPath stringByAppendingString:@"-journal"]];
                [self securelyWipeFile:[dbPath stringByAppendingString:@"-wal"]];
                [self securelyWipeFile:[dbPath stringByAppendingString:@"-shm"]];
            }
        }
        
        // 2. Clear extension bundle receipt if available
        if (bundleUUID.length > 0) {
            NSString *basePath = PXRootFSPath(@"/var/containers/Bundle/Application/");
            
            // Extensions can be directly in the bundle directory or in PlugIns/Plugins subdirectory
            NSString *bundlePath = [NSString stringWithFormat:@"%@%@", basePath, bundleUUID];
            NSArray *bundleContents = [self listDirectoriesInPath:bundlePath];
            
            for (NSString *item in bundleContents) {
                // Direct .appex file
                if ([item hasSuffix:@".appex"]) {
                    NSString *infoPlistPath = [NSString stringWithFormat:@"%@%@/Info.plist", bundlePath, item];
                    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                    NSString *itemBundleID = infoPlist[@"CFBundleIdentifier"];
                    
                    if ([itemBundleID isEqualToString:extensionBundleID]) {
                        NSString *receiptPath = [NSString stringWithFormat:@"%@%@/_MASReceipt", bundlePath, item];
                        NSLog(@"[AppDataCleaner] Clearing extension receipt: %@", receiptPath);
                        [self fixPermissionsAndRemovePath:receiptPath];
                    }
                }
                // Check in PlugIns/Plugins directory
                else if ([item isEqualToString:@"PlugIns"] || [item isEqualToString:@"Plugins"]) {
                    NSString *pluginsPath = [NSString stringWithFormat:@"%@%@", bundlePath, item];
                    NSArray *plugins = [self listDirectoriesInPath:pluginsPath];
                    
                    for (NSString *plugin in plugins) {
                        if ([plugin hasSuffix:@".appex"]) {
                            NSString *infoPlistPath = [NSString stringWithFormat:@"%@/%@/Info.plist", pluginsPath, plugin];
                            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                            NSString *itemBundleID = infoPlist[@"CFBundleIdentifier"];
                            
                            if ([itemBundleID isEqualToString:extensionBundleID]) {
                                NSString *receiptPath = [NSString stringWithFormat:@"%@/%@/_MASReceipt", pluginsPath, plugin];
                                NSLog(@"[AppDataCleaner] Clearing extension receipt in plugins: %@", receiptPath);
                                [self fixPermissionsAndRemovePath:receiptPath];
                            }
                        }
                    }
                }
            }
        }
        
        // 3. Clear extension preferences after target-context Keychain cleanup.
        NSString *prefsPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", extensionBundleID]);
        [self securelyWipeFile:prefsPath];
    }
}

// Helper method to fix permissions on a path
- (void)fixPermissionsForPath:(NSString *)path {
    if (![_fileManager fileExistsAtPath:path]) {
        return;
    }
    
    NSLog(@"[AppDataCleaner] Fixing permissions for path: %@", path);
    
    // Command to fix permissions of the entire directory
    NSString *chmodCommand = [NSString stringWithFormat:@"chmod -R 0777 '%@' 2>/dev/null || true", path];
    [self runCommandWithPrivileges:chmodCommand];
    
    // Remove any immutable or hidden flags
    NSString *chflagsCommand = [NSString stringWithFormat:@"chflags -R nouchg,noschg,nohidden '%@' 2>/dev/null || true", path];
    [self runCommandWithPrivileges:chflagsCommand];
}

// Add a new method for aggressive cleanup of stubborn files
- (void)performAggressiveCleanupFor:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Performing aggressive cleanup for %@", bundleID);
    
    // Get the data container
    NSString *dataUUID = [self findDataContainerUUID:bundleID];
    if (dataUUID) {
        NSString *dataContainerPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@", dataUUID]);
        
        // Add additional aggressive cleaning of the Documents directory
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@/Documents' -type f -exec rm -f {} \\; 2>/dev/null || true", dataContainerPath]];
        
        // Force proper permissions on Library
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"chmod -R 755 '%@/Library' 2>/dev/null || true", dataContainerPath]];
        
        // Find and remove all database files which may contain authentication data
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -name '*.db*' -exec rm -f {} \\; 2>/dev/null || true", dataContainerPath]];
        
        // NEW: Use the comprehensive container wipe
        [self completelyWipeContainer:dataContainerPath];
    }
    
    // Clear PushStore which can contain tokens
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@' 2>/dev/null || true", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/SpringBoard/PushStore/%@*", bundleID])]];
    
    // Clear UsageLog which tracks app usage
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@' 2>/dev/null || true", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/UsageLog/%@*", bundleID])]];
    
    // Clear account data specific to this app
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@' 2>/dev/null || true", PXRootFSPath([NSString stringWithFormat:@"/var/mobile/Library/Accounts/%@*", bundleID])]];
    
    // NEW: Clean the SiriAnalytics database
    [self cleanSiriAnalyticsDatabase:bundleID];
    
    // NEW: Clean IconState.plist
    [self cleanIconStatePlist:bundleID];
    
    // NEW: Clean LaunchServices database
    [self cleanLaunchServicesDatabase:bundleID];
}

- (NSString *)findBundleContainerUUID:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Searching for bundle container UUID for %@", bundleID);
    
    NSString *bundlesPath = PXRootFSPath(@"/var/containers/Bundle/Application");
    
    NSError *error;
    NSArray *contents = [_fileManager contentsOfDirectoryAtPath:bundlesPath error:&error];
    
    if (error) {
        NSLog(@"[AppDataCleaner] Error listing app bundle containers: %@", error.localizedDescription);
        return nil;
    }
    
    // Iterate through UUIDs to find our app.
    for (NSString *uuid in contents) {
        NSString *appPath = [bundlesPath stringByAppendingPathComponent:uuid];
        NSArray *appContents = [_fileManager contentsOfDirectoryAtPath:appPath error:nil];
        
        for (NSString *item in appContents) {
            if ([item hasSuffix:@".app"]) {
                NSString *infoPlistPath = [NSString stringWithFormat:@"%@/%@/Info.plist", appPath, item];
                NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                
                if ([infoPlist[@"CFBundleIdentifier"] isEqualToString:bundleID]) {
                    NSLog(@"[AppDataCleaner] Found bundle container UUID: %@ for %@", uuid, bundleID);
                    return uuid;
                }
            }
        }
    }
    NSLog(@"[AppDataCleaner] No bundle container UUID found for %@", bundleID);
    return nil;
}

- (void)clearAppReceiptData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing App Store receipt for %@", bundleID);
    
    // 1. Find the bundle container UUID
    NSString *bundleUUID = [self findBundleContainerUUID:bundleID];
    if (!bundleUUID) {
        NSLog(@"[AppDataCleaner] Could not find bundle UUID to clear receipt");
        return;
    }
    
    // Clear the receipt path in the real iOS bundle container.
    NSString *receiptPath = PXRootFSPath(
        [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@/*/_MASReceipt", bundleUUID]);
    NSArray *receipts = [self findPathsMatchingPattern:receiptPath];
    for (NSString *path in receipts) {
        NSLog(@"[AppDataCleaner] Wiping app receipt at: %@", path);
        [self wipeDirectoryContents:path keepDirectoryStructure:YES];
    }
}

// Add these methods to our collection for the most comprehensive clearing

// MEDIA STORAGE: Add method to clean media traces that apps sometimes leave behind
- (void)clearMediaData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing media data for %@", bundleID);
    
    // Parse app name from bundle ID
    NSArray *components = [bundleID componentsSeparatedByString:@"."];
    NSString *appName = [components lastObject];
    
    if (appName.length > 3) {  // Skip short/generic names
        // Check Camera Roll for app-generated photos
        NSString *dcimPath = @"/var/mobile/Media/DCIM/100APPLE/";
        if ([_fileManager fileExistsAtPath:dcimPath]) {
            NSString *command = [NSString stringWithFormat:@"find '%@' -name '*%@*' -exec rm -f {} \\; 2>/dev/null || true", 
                                dcimPath, appName];
            [self runCommandWithPrivileges:command];
        }
        
        // Check Downloads folder
        NSString *downloadsPath = @"/var/mobile/Media/Downloads/";
        if ([_fileManager fileExistsAtPath:downloadsPath]) {
            NSString *command = [NSString stringWithFormat:@"find '%@' -name '*%@*' -exec rm -f {} \\; 2>/dev/null || true", 
                                downloadsPath, appName];
            [self runCommandWithPrivileges:command];
        }
        
        // Check for attachments in Messages
        NSString *attachmentsPath = @"/var/mobile/Library/SMS/Attachments/";
        if ([_fileManager fileExistsAtPath:attachmentsPath]) {
            NSString *command = [NSString stringWithFormat:@"find '%@' -name '*%@*' -exec rm -f {} \\; 2>/dev/null || true", 
                                attachmentsPath, appName];
            [self runCommandWithPrivileges:command];
        }
    }
    
    // Check for app's media in general Library locations
    NSArray *mediaPaths = @[
        @"/var/mobile/Media/PhotoData/LocalItems/",
        @"/var/mobile/Media/PhotoData/Caches/",
        @"/var/mobile/Media/PhotoData/Thumbnails/",
        @"/var/mobile/Media/PhotoStreamsData/",
        @"/var/mobile/Media/Photos/Thumbnails/",
        @"/var/mobile/Library/Photos/"
    ];
    
    for (NSString *basePath in mediaPaths) {
        if ([_fileManager fileExistsAtPath:basePath]) {
            NSString *command = [NSString stringWithFormat:@"find '%@' -name '*%@*' -exec rm -f {} \\; 2>/dev/null || true", 
                                basePath, bundleID];
            [self runCommandWithPrivileges:command];
            
            if (appName.length > 3) {
                command = [NSString stringWithFormat:@"find '%@' -name '*%@*' -exec rm -f {} \\; 2>/dev/null || true", 
                          basePath, appName];
                [self runCommandWithPrivileges:command];
            }
        }
    }
}

// HEALTH DATA: Some apps like fitness trackers can store health data
- (void)clearHealthData:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Clearing health data for %@", bundleID);
    
    NSArray *healthPaths = @[
        @"/var/mobile/Library/Health/",
        @"/var/mobile/Library/HealthKit/",
        PXRootFSPath(@"/var/mobile/Library/Health/"),
        PXRootFSPath(@"/var/mobile/Library/HealthKit/")
    ];
    
    for (NSString *basePath in healthPaths) {
        if ([_fileManager fileExistsAtPath:basePath]) {
            NSString *command = [NSString stringWithFormat:@"find '%@' -name '*%@*' -exec rm -f {} \\; 2>/dev/null || true", 
                                basePath, bundleID];
            [self runCommandWithPrivileges:command];
        }
    }
}

// SAFARI DATA: Some apps use SafariViewController and leave data there
- (void)clearSafariData:(NSString *)bundleID {
    if (![PXWebDataCleanupPlan isSafariBundleIdentifier:bundleID]) {
        NSLog(@"[AppDataCleaner] Skipping global Safari cleanup for unrelated bundle %@", bundleID);
        return;
    }
    NSError *error = nil;
    if (![self clearWebDataForBundleID:bundleID error:&error]) {
        NSLog(@"[AppDataCleaner] Safari website-data cleanup failed: %@",
              error.localizedDescription);
    }
}

// NEW: Method to completely wipe a container directory
- (void)completelyWipeContainer:(NSString *)containerPath {
    if (![_fileManager fileExistsAtPath:containerPath]) {
        return;
    }
    
    NSLog(@"[AppDataCleaner] Completely wiping container: %@", containerPath);
    
    // Set all permissions before removal
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"chmod -R 777 '%@'", containerPath]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type d -exec chmod 777 {} \\;", containerPath]];
    
    // First handle special iOS system files that need targeted cleaning
    NSArray *systemFiles = @[
        @".com.apple.containermanagerd.metadata.plist",
        @".com.apple.mobile_container_manager.metadata.plist"
    ];
    
    for (NSString *systemFile in systemFiles) {
        NSString *fullPath = [containerPath stringByAppendingPathComponent:systemFile];
        if ([_fileManager fileExistsAtPath:fullPath]) {
            NSLog(@"[AppDataCleaner] Preserving system file structure: %@", fullPath);
            // For system files, preserve but clear non-essential data
            if ([systemFile hasSuffix:@".plist"]) {
                // Read the plist to keep only essential system keys
                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:fullPath];
                if (plist && [plist isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *cleanPlist = [NSMutableDictionary dictionary];
                    
                    // Preserve only critical system keys
                    NSArray *keysToPreserve = @[
                        @"MCMMetadataIdentifier",
                        @"MCMMetadataUUID",
                        @"MCMMetadataPath"
                    ];
                    
                    for (NSString *key in keysToPreserve) {
                        if (plist[key]) {
                            cleanPlist[key] = plist[key];
                        }
                    }
                    
                    // Write the cleaned plist back
                    [cleanPlist writeToFile:fullPath atomically:YES];
                }
            }
        }
    }
    
    // Remove all non-system files first
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type f -not -name '.com.apple*' -exec rm -f {} \\;", containerPath]];
    
    // Then remove empty non-system directories from bottom up
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -depth -type d -not -name '.com.apple*' -empty -delete", containerPath]];
    
    // Create minimal structure to avoid iOS crashes
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"mkdir -p '%@/Documents' '%@/Library/Caches' '%@/Library/Preferences' '%@/tmp'", 
        containerPath, containerPath, containerPath, containerPath]];
    
    // Set proper permissions on the directories
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"chmod 755 '%@/Documents' '%@/Library' '%@/Library/Caches' '%@/Library/Preferences' '%@/tmp'", 
        containerPath, containerPath, containerPath, containerPath, containerPath]];
    
    // Touch standard files that apps might expect
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"touch '%@/Documents/.nomedia' '%@/Library/Preferences/.initialized'", 
        containerPath, containerPath]];
}

// NEW: Method to clean IconState.plist
- (void)cleanIconStatePlist:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Cleaning SpringBoard IconState.plist for %@", bundleID);
    
    // First, backup the original plist
    [self runCommandWithPrivileges:@"cp '/var/mobile/Library/SpringBoard/IconState.plist' '/var/tmp/IconState.plist'"];
    [self runCommandWithPrivileges:@"chmod 644 '/var/tmp/IconState.plist'"];
    
    // Convert binary plist to XML format for easy text processing
    [self runCommandWithPrivileges:@"plutil -convert xml1 '/var/tmp/IconState.plist'"];
    
    // Aggressively remove any references to this app by bundle ID
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"grep -v '%@' '/var/tmp/IconState.plist' > '/var/tmp/IconState_filtered.plist'", bundleID]];
    
    // Convert back to binary format
    [self runCommandWithPrivileges:@"plutil -convert binary1 '/var/tmp/IconState_filtered.plist'"];
    
    // Replace the original plist with the filtered one
    [self runCommandWithPrivileges:@"cp '/var/tmp/IconState_filtered.plist' '/var/mobile/Library/SpringBoard/IconState.plist'"];
    
    // Clean up the temporary files
    [self runCommandWithPrivileges:@"rm -f '/var/tmp/IconState.plist' '/var/tmp/IconState_filtered.plist'"];
    
    // Additional aggressive cleanup of IconState
    // Use a more comprehensive approach to also clean any partial fragments
    // Extract app name from bundle ID (e.g., "UberClient" from "com.ubercab.UberClient")
    NSArray *components = [bundleID componentsSeparatedByString:@"."];
    NSString *appName = components.lastObject;
    
    // Dump, filter, and restore method  
    [self runCommandWithPrivileges:@"cp '/var/mobile/Library/SpringBoard/IconState.plist' '/var/tmp/IconState2.plist'"];
    [self runCommandWithPrivileges:@"chmod 644 '/var/tmp/IconState2.plist'"];
    [self runCommandWithPrivileges:@"plutil -convert xml1 '/var/tmp/IconState2.plist'"];
    
    if (appName && appName.length > 0) {
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"grep -v '%@' '/var/tmp/IconState2.plist' > '/var/tmp/IconState2_filtered.plist'", appName]];
        [self runCommandWithPrivileges:@"plutil -convert binary1 '/var/tmp/IconState2_filtered.plist'"];
        [self runCommandWithPrivileges:@"cp '/var/tmp/IconState2_filtered.plist' '/var/mobile/Library/SpringBoard/IconState.plist'"];
        [self runCommandWithPrivileges:@"rm -f '/var/tmp/IconState2.plist' '/var/tmp/IconState2_filtered.plist'"];
    }
    
    // Also clean up DefaultIconState.plist as a safety measure
    if ([_fileManager fileExistsAtPath:@"/var/mobile/Library/SpringBoard/DefaultIconState.plist"]) {
        [self runCommandWithPrivileges:@"cp '/var/mobile/Library/SpringBoard/DefaultIconState.plist' '/var/tmp/DefaultIconState.plist'"];
        [self runCommandWithPrivileges:@"chmod 644 '/var/tmp/DefaultIconState.plist'"];
        [self runCommandWithPrivileges:@"plutil -convert xml1 '/var/tmp/DefaultIconState.plist'"];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"grep -v '%@' '/var/tmp/DefaultIconState.plist' > '/var/tmp/DefaultIconState_filtered.plist'", bundleID]];
        [self runCommandWithPrivileges:@"plutil -convert binary1 '/var/tmp/DefaultIconState_filtered.plist'"];
        [self runCommandWithPrivileges:@"cp '/var/tmp/DefaultIconState_filtered.plist' '/var/mobile/Library/SpringBoard/DefaultIconState.plist'"];
        [self runCommandWithPrivileges:@"rm -f '/var/tmp/DefaultIconState.plist' '/var/tmp/DefaultIconState_filtered.plist'"];
    }
}

// NEW: Method to clean SiriAnalytics database
- (void)cleanSiriAnalyticsDatabase:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Cleaning SiriAnalytics database for %@", bundleID);
    
    // Extract app name from bundle ID (e.g., "UberClient" from "com.ubercab.UberClient")
    NSArray *components = [bundleID componentsSeparatedByString:@"."];
    NSString *appName = components.lastObject;
    
    // Delete from main table
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM main WHERE bundleid = '%@';\"", bundleID]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM main WHERE app_id = '%@';\"", bundleID]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM app_usage WHERE bundleid = '%@';\"", bundleID]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM usage_contexts WHERE data LIKE '%%%@%%';\"", bundleID]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM analytics WHERE data LIKE '%%%@%%';\"", bundleID]];
    
    // Also check by app name
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM main WHERE bundleid LIKE '%%%@%%';\"", appName]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM main WHERE app_id LIKE '%%%@%%';\"", appName]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM app_usage WHERE bundleid LIKE '%%%@%%';\"", appName]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM usage_contexts WHERE data LIKE '%%%@%%';\"", appName]];
    [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM analytics WHERE data LIKE '%%%@%%';\"", appName]];
    
    // Also delete by company name if available (e.g., "ubercab" from "com.ubercab.UberClient")
    if (components.count > 1) {
        NSString *companyName = components[1];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM main WHERE bundleid LIKE '%%%@%%';\"", companyName]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM app_usage WHERE bundleid LIKE '%%%@%%';\"", companyName]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM usage_contexts WHERE data LIKE '%%%@%%';\"", companyName]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"DELETE FROM analytics WHERE data LIKE '%%%@%%';\"", companyName]];
    }
    
    // Force data flush by running VACUUM
    [self runCommandWithPrivileges:@"sqlite3 '/var/mobile/Library/Assistant/SiriAnalytics.db' \"VACUUM;\""];
    
    // For verification purposes, ensure the database can't be flagged during verification
    [self runCommandWithPrivileges:@"touch -r /var/mobile/Library/Assistant/SiriAnalytics.db /System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices"];
}

// NEW: Method to clean LaunchServices database
- (void)cleanLaunchServicesDatabase:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Cleaning LaunchServices database for %@", bundleID);
    
    // Remove SBAppTagsFileManager which stores app categorization
    [self runCommandWithPrivileges:@"rm -rf /var/mobile/Library/CoreServices/SpringBoard.app/SBAppTagsFileManager"];
    [self runCommandWithPrivileges:@"rm -rf /var/mobile/Library/CoreServices/SpringBoard.app/SBIconModelCache.plist"];
    
    // Find and remove LaunchServices caches
    NSArray *lsCachePaths = [self findPathsMatchingPattern:@"/var/mobile/Library/Caches/com.apple.LaunchServices-*"];
    for (NSString *path in lsCachePaths) {
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", path]];
    }
    
}

// NEW: Method to refresh system services to apply changes
- (void)refreshSystemServices {
    NSLog(@"[AppDataCleaner] Refreshing system services to ensure changes take effect");
    
    // Send HUP signal to SpringBoard to refresh IconState
    [self runCommandWithPrivileges:@"killall -HUP SpringBoard 2>/dev/null || true"];
    
    // Enhanced: Force system caches to be cleared
    [self runCommandWithPrivileges:@"sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true"];
    
    // Enhanced: Clear application launch cache
    [self runCommandWithPrivileges:@"killall -TERM cfprefsd 2>/dev/null || true"];
    
    // Enhanced: Clear system connectivity caches
    [self runCommandWithPrivileges:@"killall -TERM nsurlsessiond 2>/dev/null || true"];
    
    // Enhanced: Force cache regen in filesystem
    [self runCommandWithPrivileges:@"rm -rf /var/mobile/Library/Caches/com.apple.LaunchServices-* 2>/dev/null || true"];
    
    // Enhanced: Force database vacuum on key databases to remove deleted data
    NSArray *dbsToVacuum = @[
        @"/var/mobile/Library/SpringBoard/IconState.plist",
        @"/var/mobile/Library/SpringBoard/ApplicationState.db"
    ];
    
    for (NSString *dbPath in dbsToVacuum) {
        if ([dbPath hasSuffix:@".db"]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"VACUUM;\" 2>/dev/null || true", dbPath]];
        }
    }
}

#pragma mark - Container Discovery Methods

- (BOOL)hasKeychainItemsForBundleID:(NSString *)bundleID {
#if 0
    // This will require Security.framework access
    // For now we'll use a simple check to see if there are any keychain items for this app
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = bundleID;
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    
    if (status == errSecSuccess) {
        NSArray *items = (__bridge_transfer NSArray *)result;
        return items.count > 0;
    }
    
    // Try again with a different approach - check for access groups
    query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrAccessGroup] = bundleID;
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    
    result = NULL;
    status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    
    if (status == errSecSuccess) {
        NSArray *items = (__bridge_transfer NSArray *)result;
        return items.count > 0;
    }
    
    return NO;
#endif
    (void)bundleID;
    return NO;
}

// Support methods (aliases for backwards compatibility)
- (NSString *)findDataContainerUUIDForBundleID:(NSString *)bundleID {
    return [self findDataContainerUUID:bundleID];
}

- (NSString *)findBundleContainerUUIDForBundleID:(NSString *)bundleID {
    return [self findBundleContainerUUID:bundleID];
}

- (NSArray *)findGroupContainerUUIDsForBundleID:(NSString *)bundleID {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *containersPath = PXRootFSPath(@"/var/mobile/Containers/Shared/AppGroup");
    NSMutableArray *groupUUIDs = [NSMutableArray array];
    NSError *error = nil;
    
    if (![fileManager fileExistsAtPath:containersPath]) {
        NSLog(@"[AppDataCleaner] Directory does not exist: %@", containersPath);
        return groupUUIDs;
    }
    
    NSArray *containers = [fileManager contentsOfDirectoryAtPath:containersPath error:&error];
    if (error) {
        NSLog(@"[AppDataCleaner] Error listing group containers: %@", error);
        return groupUUIDs;
    }
    
    for (NSString *container in containers) {
        if ([container hasPrefix:@"."]) continue;
        
        NSString *containerPath = [containersPath stringByAppendingPathComponent:container];
        NSString *metadataPath = [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        
        if ([fileManager fileExistsAtPath:metadataPath]) {
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            if (PXMetadataValueOwnsBundleIdentifier(metadata, bundleID)) {
                NSLog(@"[AppDataCleaner] Found app group container UUID: %@", container);
                [groupUUIDs addObject:container];
            }
        }
    }
    
    return groupUUIDs;
}

- (NSArray *)findExtensionDataContainersForBundleID:(NSString *)bundleID {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *containersPath = PXRootFSPath(@"/var/mobile/Containers/Data/Application");
    NSMutableArray *extensionContainers = [NSMutableArray array];
    NSError *error = nil;
    
    if (![fileManager fileExistsAtPath:containersPath]) {
        NSLog(@"[AppDataCleaner] Directory does not exist: %@", containersPath);
        return extensionContainers;
    }
    
    NSArray *containers = [fileManager contentsOfDirectoryAtPath:containersPath error:&error];
    if (error) {
        NSLog(@"[AppDataCleaner] Error listing data containers: %@", error);
        return extensionContainers;
    }
    
    for (NSString *container in containers) {
        if ([container hasPrefix:@"."]) continue;
        
        NSString *containerPath = [containersPath stringByAppendingPathComponent:container];
        NSString *metadataPath = [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        
        if ([fileManager fileExistsAtPath:metadataPath]) {
                NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
                NSString *containerBundleID = metadata[@"MCMMetadataIdentifier"];
                
            // Extensions must descend from the exact selected bundle identifier.
            if (containerBundleID && ![containerBundleID isEqualToString:bundleID] &&
                [containerBundleID hasPrefix:[bundleID stringByAppendingString:@"."]]) {
                
                NSLog(@"[AppDataCleaner] Found extension container UUID: %@ for %@", container, containerBundleID);
                [extensionContainers addObject:container];
            }
        }
    }
    
    NSLog(@"[AppDataCleaner] Found %lu extension containers for %@", (unsigned long)extensionContainers.count, bundleID);
    return extensionContainers;
}

- (void)cleanAppGroupContainers:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Cleaning app group containers for %@", bundleID);
    
    // First, check if the app has its own app groups
    NSArray *groupUUIDs = [self findGroupContainerUUIDsForBundleID:bundleID];
    
    // Get the app's base identifier components for searching
    NSString *appName = [bundleID componentsSeparatedByString:@"."].lastObject;
    NSString *companyName = [bundleID componentsSeparatedByString:@"."].count > 1 ? [bundleID componentsSeparatedByString:@"."][1] : nil;
    NSString *firstComponent = [bundleID componentsSeparatedByString:@"."].firstObject;
    
    // Handle real iOS app group containers.
    for (NSString *uuid in groupUUIDs) {
        NSString *containerPath = PXRootFSPath(
            [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/%@", uuid]);
        NSLog(@"[AppDataCleaner] Cleaning app group container: %@", containerPath);
        
        // Get and log the group identifier before wiping
        NSString *metadataPath = [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", containerPath];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *groupIdentifier = metadata[@"MCMMetadataIdentifier"];
        NSLog(@"[AppDataCleaner] Cleaning group with identifier: %@", groupIdentifier);
        
        if ([groupIdentifier hasPrefix:[NSString stringWithFormat:@"group.%@", firstComponent]] || 
            [groupIdentifier hasPrefix:[NSString stringWithFormat:@"group.%@", companyName]]) {
            // This is definitely owned by our app - completely wipe it
            NSLog(@"[AppDataCleaner] This group belongs to the app - wiping completely");
            [self completelyWipeContainer:containerPath];
        } else {
            // This is a system group or shared with other apps - clean selectively
            [self cleanAppSpecificFilesInSharedContainer:containerPath bundleID:bundleID appName:appName companyName:companyName];
        }
    }
    // Explicitly handle all system app group containers that might store app data
    // Get a comprehensive list of all app group containers
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *containersPath = PXRootFSPath(@"/var/mobile/Containers/Shared/AppGroup");
    NSError *error = nil;
    NSArray *allContainers = [fileManager contentsOfDirectoryAtPath:containersPath error:&error];
    
    if (!error) {
        // Process all group containers, including system containers that weren't directly associated with the app
        for (NSString *uuid in allContainers) {
            if ([uuid hasPrefix:@"."]) continue; // Skip hidden files
            
            // Skip containers we've already processed
            if ([groupUUIDs containsObject:uuid]) continue;
            
            NSString *containerPath = [NSString stringWithFormat:@"%@/%@", containersPath, uuid];
            
            // Check if this is one of the known problematic containers from logs
            BOOL isKnownProblemContainer = NO;
            NSArray *knownProblemContainers = @[
                @"1E1577AF-3EC2-4748-ADE9-937471B52738", // File Provider Storage
                @"1E17A582-F7DC-429D-BE50-4A69226EC3FA", // Maps
                @"0DCF64D5-9838-4EFF-8D0E-8CCB197B65C1", // Lyft group
                @"1BAD61E3-6E9A-4B83-8D11-36DFD4324F32", // Notes
                @"FFCEFC09-C545-43EA-ADDA-5D676A620612", // DocumentManager
                @"102B7263-7A4F-469E-AFBF-B220538A41E5", // VPN groups
                @"101EFFE4-1A84-480A-B865-EDE04D8B9923", // File Provider LocalStorage
                @"F04D144A-7AC2-4F37-AA9D-C76596123ECA"  // Health
            ];
            
            if ([knownProblemContainers containsObject:uuid]) {
                isKnownProblemContainer = YES;
                NSLog(@"[AppDataCleaner] Processing known problematic system app group: %@", uuid);
            }
            
            // Additional check: peek inside to see if there might be app-related content
            BOOL mayContainAppData = NO;
            NSArray *contents = [fileManager contentsOfDirectoryAtPath:containerPath error:nil];
            for (NSString *item in contents) {
                if ([item containsString:appName] || 
                    [item containsString:companyName] || 
                    [item containsString:firstComponent] ||
                    [item containsString:bundleID]) {
                    mayContainAppData = YES;
                    break;
                }
            }
            
            // Process this container if it's known problematic or might contain app data
            if (isKnownProblemContainer || mayContainAppData) {
                NSLog(@"[AppDataCleaner] Cleaning app data from system group container: %@", containerPath);
                [self cleanAppSpecificFilesInSharedContainer:containerPath bundleID:bundleID appName:appName companyName:companyName];
                
                // For known problem containers, perform additional deep cleaning
                if (isKnownProblemContainer) {
                    [self deepCleanSystemSharedContainer:containerPath bundleID:bundleID appName:appName companyName:companyName];
                }
            }
        }
    }
    
    NSLog(@"[AppDataCleaner] Completed app group container cleaning for %@", bundleID);
}

- (void)cleanAppSpecificFilesInSharedContainer:(NSString *)containerPath bundleID:(NSString *)bundleID appName:(NSString *)appName companyName:(NSString *)companyName {
    NSFileManager *fileManager = [NSFileManager defaultManager];
                            NSError *error = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:containerPath error:&error];
    
    if (error) {
        NSLog(@"[AppDataCleaner] Error accessing container %@: %@", containerPath, error);
        return;
    }
    
    // First pass: identify items that are definitely related to our app
    for (NSString *item in contents) {
        if ([item hasPrefix:@".com.apple"]) continue; // Skip system files
        
        BOOL isAppRelated = NO;
        
        // Very likely related to our app
        if ([item containsString:bundleID] || 
            (appName.length > 3 && [item containsString:appName]) || 
            (companyName.length > 3 && [item containsString:companyName])) {
            isAppRelated = YES;
        }
        
        // Check additional app-specific patterns
        NSArray *appSpecificPatterns = @[@"auth", @"credentials", @"token", @"session", appName.lowercaseString];
        for (NSString *pattern in appSpecificPatterns) {
            if ([item.lowercaseString containsString:pattern]) {
                isAppRelated = YES;
                break;
            }
        }
        
        if (isAppRelated) {
            NSString *itemPath = [containerPath stringByAppendingPathComponent:item];
            NSLog(@"[AppDataCleaner] Removing app-specific item from shared group: %@", itemPath);
            [self fixPermissionsAndRemovePath:itemPath];
        }
    }
    
    // Second pass: handle database files that might contain app data
    NSString *findDbCommand = [NSString stringWithFormat:@"find '%@' -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite-*'", containerPath];
    NSString *output = [self runCommandAndGetOutput:findDbCommand];
    if (output.length > 0) {
        NSArray *dbFiles = [output componentsSeparatedByString:@"\n"];
        
        for (NSString *dbFile in dbFiles) {
            if (dbFile.length > 0 && [fileManager fileExistsAtPath:dbFile]) {
                NSLog(@"[AppDataCleaner] Cleaning app data from database: %@", dbFile);
                [self cleanDatabaseFile:dbFile bundleID:bundleID appName:appName companyName:companyName];
            }
        }
    }
}

- (void)deepCleanSystemSharedContainer:(NSString *)containerPath bundleID:(NSString *)bundleID appName:(NSString *)appName companyName:(NSString *)companyName {
    // Get the container UUID from the path
    NSString *uuid = [containerPath lastPathComponent];
    
    // Handle specific known problematic containers differently based on their content types
    if ([uuid isEqualToString:@"1E1577AF-3EC2-4748-ADE9-937471B52738"] || // File Provider Storage
        [uuid isEqualToString:@"101EFFE4-1A84-480A-B865-EDE04D8B9923"]) { // File Provider LocalStorage
        NSLog(@"[AppDataCleaner] Deep cleaning File Provider container: %@", containerPath);
        
        // Clean File Provider Storage directories that might reference our app
        NSString *command = [NSString stringWithFormat:@"find '%@' -type d -name '*%@*' -exec rm -rf {} \\; 2>/dev/null || true", 
                           containerPath, appName];
        [self runCommandWithPrivileges:command];
        
        // Also search for company names in the directory names
        if (companyName.length > 0) {
            command = [NSString stringWithFormat:@"find '%@' -type d -name '*%@*' -exec rm -rf {} \\; 2>/dev/null || true", 
                      containerPath, companyName];
            [self runCommandWithPrivileges:command];
        }
    } 
    else if ([uuid isEqualToString:@"1E17A582-F7DC-429D-BE50-4A69226EC3FA"]) { // Maps
        NSLog(@"[AppDataCleaner] Deep cleaning Maps container: %@", containerPath);
        
        // Clean map data entries related to our app
        NSString *mapsDbPath = [containerPath stringByAppendingPathComponent:@"Maps/Maps.sqlite"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:mapsDbPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM location_bookmarks WHERE title LIKE '%%%@%%' OR subtitle LIKE '%%%@%%';\" 2>/dev/null || true", mapsDbPath, appName, appName]];
            
            // Add specific cleaning for Lyft and Zimride names
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM location_bookmarks WHERE title LIKE '%%lyft%%' OR subtitle LIKE '%%lyft%%';\" 2>/dev/null || true", mapsDbPath]];
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM location_bookmarks WHERE title LIKE '%%zimride%%' OR subtitle LIKE '%%zimride%%';\" 2>/dev/null || true", mapsDbPath]];
            
            if (companyName.length > 0) {
                [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM location_bookmarks WHERE title LIKE '%%%@%%' OR subtitle LIKE '%%%@%%';\" 2>/dev/null || true", mapsDbPath, companyName, companyName]];
            }
            
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"VACUUM;\" 2>/dev/null || true", mapsDbPath]];
        }
    }
    else if ([uuid isEqualToString:@"0DCF64D5-9838-4EFF-8D0E-8CCB197B65C1"]) { // Lyft group
        NSLog(@"[AppDataCleaner] Deep cleaning Lyft container: %@", containerPath);
        
        // If our app is a transportation app, we should clean cross-app references
        NSString *lyftStoragePath = [containerPath stringByAppendingPathComponent:@"com.zimride.instant.storage"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:lyftStoragePath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", lyftStoragePath]];
        }
        
        // Check com.lyft.ios storage path
        NSString *lyftIosStoragePath = [containerPath stringByAppendingPathComponent:@"com.lyft.ios.storage"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:lyftIosStoragePath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", lyftIosStoragePath]];
        }
        
        // Also check old Lyft storage path
        NSString *oldLyftStoragePath = [containerPath stringByAppendingPathComponent:@"com.lyft.ios.storage"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:oldLyftStoragePath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", oldLyftStoragePath]];
        }
        
        // Check for com.lyft.ios directory
        NSString *lyftIosPath = [containerPath stringByAppendingPathComponent:@"com.lyft.ios"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:lyftIosPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", lyftIosPath]];
        }
        
        // Check for alternate storage paths too
        NSString *alternateLyftPath = [containerPath stringByAppendingPathComponent:@"com.zimride.instant"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:alternateLyftPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", alternateLyftPath]];
        }
        
        // Check old Lyft path
        NSString *alternateOldLyftPath = [containerPath stringByAppendingPathComponent:@"com.lyft.me"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:alternateOldLyftPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", alternateOldLyftPath]];
        }
        
        // Clean credentials
        NSString *credentialsPath = [containerPath stringByAppendingPathComponent:@"Credentials"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:credentialsPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", credentialsPath]];
        }
        
        // Clean tokens
        NSString *tokensPath = [containerPath stringByAppendingPathComponent:@"Tokens"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tokensPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", tokensPath]];
        }
        
        // Clean ride history
        NSString *ridesPath = [containerPath stringByAppendingPathComponent:@"RideHistory"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:ridesPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", ridesPath]];
        }
        
        // Clean saved locations
        NSString *locationsPath = [containerPath stringByAppendingPathComponent:@"SavedLocations"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:locationsPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", locationsPath]];
        }
        
        // Clean databases
        NSString *dbsPath = [containerPath stringByAppendingPathComponent:@"Databases"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dbsPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -name '*.db' -o -name '*.sqlite' -exec rm -f {} \\; 2>/dev/null || true", dbsPath]];
        }
        
        // Find and clean any files/folders containing "lyft" in the name
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type d -name '*lyft*' -exec rm -rf {} \\; 2>/dev/null || true", containerPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type f -name '*lyft*' -exec rm -f {} \\; 2>/dev/null || true", containerPath]];
        
        // Find and clean any files/folders containing "zimride" in the name
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type d -name '*zimride*' -exec rm -rf {} \\; 2>/dev/null || true", containerPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -type f -name '*zimride*' -exec rm -f {} \\; 2>/dev/null || true", containerPath]];
    }
    else if ([uuid isEqualToString:@"F7DD9815-AC23-47C4-A316-59779EDAB38D"]) { // Uber group
        NSLog(@"[AppDataCleaner] Deep cleaning Uber container: %@", containerPath);
        
        // Clean Uber files - target both storage and credentials paths
        NSString *uberStoragePath = [containerPath stringByAppendingPathComponent:@"com.uber.ios.storage"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:uberStoragePath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", uberStoragePath]];
        }
        
        // Check for Helix (alternative Uber name)
        NSString *helixStoragePath = [containerPath stringByAppendingPathComponent:@"com.helix.ios.storage"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:helixStoragePath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", helixStoragePath]];
        }
        
        // Clean credentials storage specifically
        // Clean credentials storage specifically
        NSString *credentialsPath = [containerPath stringByAppendingPathComponent:@"Credentials"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:credentialsPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", credentialsPath]];
        }
        
        // Clean tokens directory
        NSString *tokensPath = [containerPath stringByAppendingPathComponent:@"Tokens"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tokensPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", tokensPath]];
        }
        
        // Clean location history and trip data
        NSString *tripsPath = [containerPath stringByAppendingPathComponent:@"Trips"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tripsPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", tripsPath]];
        }
        
        // Clean location history
        NSString *locHistoryPath = [containerPath stringByAppendingPathComponent:@"LocationHistory"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:locHistoryPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", locHistoryPath]];
        }
        
        // Clean saved places
        NSString *savedPlacesPath = [containerPath stringByAppendingPathComponent:@"SavedPlaces"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:savedPlacesPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", savedPlacesPath]];
        }
        
        // Clean ride history
        NSString *rideHistoryPath = [containerPath stringByAppendingPathComponent:@"RideHistory"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:rideHistoryPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", rideHistoryPath]];
        }
        
        // Clean payment data
        NSString *paymentsPath = [containerPath stringByAppendingPathComponent:@"Payments"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:paymentsPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", paymentsPath]];
        }
        
        // Clean cached data
        NSString *cachePath = [containerPath stringByAppendingPathComponent:@"Cache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -rf '%@'", cachePath]];
        }
        
        // Clean databases
        NSString *dbsPath = [containerPath stringByAppendingPathComponent:@"Databases"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dbsPath]) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -name '*.db' -o -name '*.sqlite' -exec rm -f {} \\; 2>/dev/null || true", dbsPath]];
        } else {
            // Clean all SQLite databases
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"find '%@' -name '*.db' -o -name '*.sqlite' -exec rm -f {} \\; 2>/dev/null || true", containerPath]];
        }
    }
}

- (void)cleanDatabaseFile:(NSString *)dbPath bundleID:(NSString *)bundleID appName:(NSString *)appName companyName:(NSString *)companyName {
    // Check if this is an SQLite database
    if ([dbPath hasSuffix:@".sqlite"] || [dbPath hasSuffix:@".db"]) {
        NSLog(@"[AppDataCleaner] Cleaning SQLite database: %@", dbPath);
        
        // Try common table and column names that might contain app-specific data
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE bundleid = '%@';\" 2>/dev/null || true", dbPath, bundleID]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE bundleid = '%@';\" 2>/dev/null || true", dbPath, bundleID]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE bundleid = '%@';\" 2>/dev/null || true", dbPath, bundleID]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE bundleid = '%@';\" 2>/dev/null || true", dbPath, bundleID]];
        
        // Add specific cleaning for Lyft and Zimride names in tables
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE data LIKE '%%lyft%%' OR bundleid LIKE '%%lyft%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE data LIKE '%%lyft%%' OR bundleid LIKE '%%lyft%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE data LIKE '%%lyft%%' OR bundleid LIKE '%%lyft%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE data LIKE '%%lyft%%' OR bundleid LIKE '%%lyft%%';\" 2>/dev/null || true", dbPath]];
        
        // Specific case for com.lyft.ios bundle ID
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE bundleid = 'com.lyft.ios' OR data LIKE '%%com.lyft.ios%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE bundleid = 'com.lyft.ios' OR data LIKE '%%com.lyft.ios%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE bundleid = 'com.lyft.ios' OR data LIKE '%%com.lyft.ios%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE bundleid = 'com.lyft.ios' OR data LIKE '%%com.lyft.ios%%';\" 2>/dev/null || true", dbPath]];
        
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE data LIKE '%%zimride%%' OR bundleid LIKE '%%zimride%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE data LIKE '%%zimride%%' OR bundleid LIKE '%%zimride%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE data LIKE '%%zimride%%' OR bundleid LIKE '%%zimride%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE data LIKE '%%zimride%%' OR bundleid LIKE '%%zimride%%';\" 2>/dev/null || true", dbPath]];
        // Add specific cleaning for Uber and Helix names in tables
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE data LIKE '%%uber%%' OR bundleid LIKE '%%uber%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE data LIKE '%%uber%%' OR bundleid LIKE '%%uber%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE data LIKE '%%uber%%' OR bundleid LIKE '%%uber%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE data LIKE '%%uber%%' OR bundleid LIKE '%%uber%%';\" 2>/dev/null || true", dbPath]];
        
        // Specific case for com.ubercab.UberClient bundle ID
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE bundleid = 'com.ubercab.UberClient' OR data LIKE '%%com.ubercab.UberClient%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE bundleid = 'com.ubercab.UberClient' OR data LIKE '%%com.ubercab.UberClient%%';\" 2>/dev/null || true", dbPath]];
//         [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' "DELETE FROM main WHERE bundleid = 'com.ubercab.UberClient' OR data LIKE '%%com.ubercab.UberClient%%';\" 2>/dev/null || true", dbPath]];
//         [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' "DELETE FROM apps WHERE bundleid = 'com.ubercab.UberClient' OR data LIKE '%%com.ubercab.UberClient%%';\" 2>/dev/null || true", dbPath]];
//         [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' "DELETE FROM data WHERE bundleid = 'com.ubercab.UberClient' OR data LIKE '%%com.ubercab.UberClient%%';\" 2>/dev/null || true", dbPath]];
//         [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' "DELETE FROM items WHERE bundleid = 'com.ubercab.UberClient' OR data LIKE '%%com.ubercab.UberClient%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE data LIKE '%%helix%%' OR bundleid LIKE '%%helix%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE data LIKE '%%helix%%' OR bundleid LIKE '%%helix%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE data LIKE '%%helix%%' OR bundleid LIKE '%%helix%%';\" 2>/dev/null || true", dbPath]];
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE data LIKE '%%helix%%' OR bundleid LIKE '%%helix%%';\" 2>/dev/null || true", dbPath]];         
        // Also try to delete data based on app name and company name
        if (appName.length > 0) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, appName]];
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, appName]];
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, appName]];
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, appName]];
        }
        
        if (companyName.length > 0) {
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM main WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, companyName]];
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM apps WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, companyName]];
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM data WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, companyName]];
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"DELETE FROM items WHERE data LIKE '%%%@%%';\" 2>/dev/null || true", dbPath, companyName]];
        }
        
        // Try to vacuum the database
        [self runCommandWithPrivileges:[NSString stringWithFormat:@"sqlite3 '%@' \"VACUUM;\" 2>/dev/null || true", dbPath]];
    } else if ([dbPath hasSuffix:@".sqlite-shm"] || [dbPath hasSuffix:@".sqlite-wal"] || 
               [dbPath hasSuffix:@".db-shm"] || [dbPath hasSuffix:@".db-wal"]) {
        // These are SQLite auxiliary files - clear them if main database also exists
        NSString *mainDbPath = [dbPath stringByReplacingOccurrencesOfString:@"-shm" withString:@""];
        mainDbPath = [mainDbPath stringByReplacingOccurrencesOfString:@"-wal" withString:@""];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:mainDbPath]) {
            // If the main database doesn't exist, we can safely remove these files
            NSLog(@"[AppDataCleaner] Removing SQLite auxiliary file: %@", dbPath);
            [self runCommandWithPrivileges:[NSString stringWithFormat:@"rm -f '%@'", dbPath]];
        }
    }
}

- (void)clearAppIssuesForIOS15:(NSString *)bundleID {
    NSLog(@"[AppDataCleaner] Fixing iOS 15+ specific issues for %@", bundleID);
    
    // Fix location services registration issues
    NSArray *locationPaths = @[
        // Location caches that might contain bad registrations
        [NSString stringWithFormat:@"/var/mobile/Library/Caches/locationd/%@*", bundleID],
        // Special case for Lyft/Zimride
        @"/var/mobile/Library/Caches/locationd/*lyft*",
        @"/var/mobile/Library/Caches/locationd/*zimride*",
        // Extra case for com.lyft.ios specifically
        @"/var/mobile/Library/Caches/locationd/com.lyft.ios*",
        // Special case for Uber/Helix
        @"/var/mobile/Library/Caches/locationd/*uber*",
        @"/var/mobile/Library/Caches/locationd/*helix*",
        // Location client registrations
        [NSString stringWithFormat:@"/var/mobile/Library/locationd/clients.plist"],
        // Extra case for com.ubercab.UberClient specifically
        @"/var/mobile/Library/Caches/locationd/com.ubercab.UberClient*",
        // Special case for Uber/Helix
        @"/var/mobile/Library/Caches/locationd/*uber*",
        @"/var/mobile/Library/Caches/locationd/*helix*",
        // Extra case for com.ubercab.UberClient specifically
        @"/var/mobile/Library/Caches/locationd/com.ubercab.UberClient*",
        // Location client registrations
        [NSString stringWithFormat:@"/var/mobile/Library/locationd/clients.plist"]
    ];
    
    // Clear location cache files
    for (NSString *pattern in locationPaths) {
        if ([pattern hasSuffix:@".plist"]) {
            // For plist files, we need to modify them rather than delete
            if ([_fileManager fileExistsAtPath:pattern]) {
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"clients.plist.temp"];
                [_fileManager copyItemAtPath:pattern toPath:tempPath error:nil];
                
                NSMutableDictionary *clients = [NSMutableDictionary dictionaryWithContentsOfFile:tempPath];
                if (clients) {
                    // Remove any entries for this bundle ID
                    NSMutableArray *keysToRemove = [NSMutableArray arrayWithArray:[clients.allKeys filteredArrayUsingPredicate:
                                           [NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", bundleID]]];
                    
                    // Also remove Lyft and Zimride entries
                    [keysToRemove addObjectsFromArray:[clients.allKeys filteredArrayUsingPredicate:
                                           [NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", @"lyft"]]];
                    [keysToRemove addObjectsFromArray:[clients.allKeys filteredArrayUsingPredicate:
                                           [NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", @"zimride"]]];
                    
                    // Also remove Uber and Helix entries
                    [keysToRemove addObjectsFromArray:[clients.allKeys filteredArrayUsingPredicate:
                                           [NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", @"uber"]]];
                    [keysToRemove addObjectsFromArray:[clients.allKeys filteredArrayUsingPredicate:
                                           [NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", @"helix"]]];
                    
                    if (keysToRemove.count > 0) {
                        NSLog(@"[AppDataCleaner] Found %lu location client registrations to remove", (unsigned long)keysToRemove.count);
                        [keysToRemove enumerateObjectsUsingBlock:^(id key, NSUInteger idx, BOOL *stop) {
                            [clients removeObjectForKey:key];
                        }];
                        
                        [clients writeToFile:tempPath atomically:YES];
                        [self runCommandWithPrivileges:[NSString stringWithFormat:@"cp '%@' '%@'", tempPath, pattern]];
                    }
                }
                
                [_fileManager removeItemAtPath:tempPath error:nil];
            }
        } else {
            // Pattern-based file deletion
            NSArray *matches = [self findPathsMatchingPattern:pattern];
            for (NSString *path in matches) {
                NSLog(@"[AppDataCleaner] Wiping location cache file: %@", path);
                [self securelyWipeFile:path];
            }
        }
    }
    
    // Fix UI state issues specific to iOS 15+
    NSArray *uiStatePaths = @[
        // UISplitViewController state
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/com.apple.UIKit.plist"],
        // App-specific UI state 
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@-UI-State.plist", bundleID],
        // Special case for Lyft/Zimride
        @"/var/mobile/Library/Preferences/*lyft*-UI-State.plist",
        @"/var/mobile/Library/Preferences/*zimride*-UI-State.plist",
        // Extra case for com.lyft.ios specifically
        @"/var/mobile/Library/Preferences/com.lyft.ios-UI-State.plist",
        // Special case for Uber/Helix
        @"/var/mobile/Library/Preferences/*uber*-UI-State.plist",
        @"/var/mobile/Library/Preferences/*helix*-UI-State.plist",
        // Extra case for com.ubercab.UberClient specifically
        @"/var/mobile/Library/Preferences/com.ubercab.UberClient-UI-State.plist",
        // SplitView controller state
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/com.apple.UIKit.SplitView.%@.plist", bundleID],
        @"/var/mobile/Library/Preferences/com.apple.UIKit.SplitView.*lyft*.plist",
        @"/var/mobile/Library/Preferences/com.apple.UIKit.SplitView.*zimride*.plist",
        @"/var/mobile/Library/Preferences/com.apple.UIKit.SplitView.*uber*.plist",
        @"/var/mobile/Library/Preferences/com.apple.UIKit.SplitView.*helix*.plist"
    ];
    
    for (NSString *path in uiStatePaths) {
        // For patterns with wildcards, use findPathsMatchingPattern
        if ([path containsString:@"*"]) {
            NSArray *matches = [self findPathsMatchingPattern:path];
            for (NSString *matchPath in matches) {
                NSLog(@"[AppDataCleaner] Wiping UI state file: %@", matchPath);
                [self securelyWipeFile:matchPath];
            }
        } else if ([_fileManager fileExistsAtPath:path]) {
            NSLog(@"[AppDataCleaner] Wiping UI state file: %@", path);
            [self securelyWipeFile:path];
        }
    }
    
    // Fix snapshot denylisting for iOS 15+
    NSArray *snapshotPaths = @[
        [NSString stringWithFormat:@"/var/mobile/Library/SplashBoard/Snapshots/%@*", bundleID],
        [NSString stringWithFormat:@"/var/mobile/Library/Caches/Snapshots/%@*", bundleID],
        // Special case for Lyft/Zimride
        @"/var/mobile/Library/SplashBoard/Snapshots/*lyft*",
        @"/var/mobile/Library/Caches/Snapshots/*lyft*",
        @"/var/mobile/Library/SplashBoard/Snapshots/*zimride*",
        @"/var/mobile/Library/Caches/Snapshots/*zimride*",
        // Extra case for com.lyft.ios specifically
        @"/var/mobile/Library/SplashBoard/Snapshots/com.lyft.ios*",
        @"/var/mobile/Library/Caches/Snapshots/com.lyft.ios*",
        // Special case for Uber/Helix
        @"/var/mobile/Library/SplashBoard/Snapshots/*uber*",
        @"/var/mobile/Library/Caches/Snapshots/*uber*",
        @"/var/mobile/Library/SplashBoard/Snapshots/*helix*",
        // Extra case for com.ubercab.UberClient specifically
        @"/var/mobile/Library/SplashBoard/Snapshots/com.ubercab.UberClient*",
        @"/var/mobile/Library/Caches/Snapshots/com.ubercab.UberClient*",
        @"/var/mobile/Library/Caches/Snapshots/*helix*",
        // Snapshot deny list
        @"/var/mobile/Library/SpringBoard/ApplicationDenyList.plist"
    ];
    
    for (NSString *pattern in snapshotPaths) {
        if ([pattern hasSuffix:@"DenyList.plist"]) {
            // For deny list, we need to modify it rather than delete
            if ([_fileManager fileExistsAtPath:pattern]) {
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"denylist.plist.temp"];
                [_fileManager copyItemAtPath:pattern toPath:tempPath error:nil];
                
                NSMutableDictionary *denyList = [NSMutableDictionary dictionaryWithContentsOfFile:tempPath];
                if (denyList) {
                    // Create list of keys to remove
                    NSMutableArray *keysToRemove = [NSMutableArray array];
                    
                    // Remove this app from the deny list
                    if ([denyList objectForKey:bundleID]) {
                        [keysToRemove addObject:bundleID];
                    }
                    
                    // Check for Lyft and Zimride entries
                    for (NSString *key in denyList.allKeys) {
                        if ([key containsString:@"lyft"] || [key containsString:@"zimride"]) {
                            [keysToRemove addObject:key];
                        }
                    }
                    
                    // Also remove Uber and Helix entries
                    for (NSString *key in denyList.allKeys) {
                        if ([key containsString:@"uber"] || [key containsString:@"helix"]) {
                            [keysToRemove addObject:key];
                        }
                    }
                    
                    if (keysToRemove.count > 0) {
                        NSLog(@"[AppDataCleaner] Removing %lu entries from snapshot deny list", (unsigned long)keysToRemove.count);
                        for (NSString *key in keysToRemove) {
                            [denyList removeObjectForKey:key];
                        }
                        [denyList writeToFile:tempPath atomically:YES];
                        [self runCommandWithPrivileges:[NSString stringWithFormat:@"cp '%@' '%@'", tempPath, pattern]];
                    }
                }
                
                [_fileManager removeItemAtPath:tempPath error:nil];
            }
        } else {
            // Pattern-based file deletion
            NSArray *matches = [self findPathsMatchingPattern:pattern];
            for (NSString *path in matches) {
                NSLog(@"[AppDataCleaner] Wiping snapshot file: %@", path);
                [self securelyWipeFile:path];
            }
        }
    }
}

// Helper method to check if directory exists and has any content at all, ignoring system files
- (BOOL)directoryExistsAndHasAnyContent:(NSString *)path {
    if (![_fileManager fileExistsAtPath:path]) {
        NSLog(@"[AppDataCleaner] Directory does not exist: %@", path);
        return NO;
    }
    
    // Use a more permissive find command to check for ANY files (including hidden)
    NSString *command = [NSString stringWithFormat:@"find '%@' -type f -not -path '*/\\.*' -maxdepth 3 | head -n 1", path];
    NSString *result = [self runCommandAndGetOutput:command];
    
    // If we found at least one file, return true
    if (result.length > 0 && ![result isEqualToString:@"error"]) {
        NSLog(@"[AppDataCleaner] Found at least one file in directory: %@", path);
        return YES;
    }
    
    // As a backup, check for any directories that might contain data
    command = [NSString stringWithFormat:@"find '%@' -type d -not -path '*/\\.*' -mindepth 1 -maxdepth 2 | grep -v '\\.com\\.apple'", path];
    result = [self runCommandAndGetOutput:command];
    if (result.length > 0 && ![result isEqualToString:@"error"]) {
        NSLog(@"[AppDataCleaner] Found subdirectories in: %@", path);
        return YES;
    }
    
    return NO;
}

// Helper method to check if the app has any references in system databases
- (BOOL)hasSystemDatabaseReferencesForBundleID:(NSString *)bundleID {
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *appName = parts.lastObject;
    NSString *company = parts.count > 1 ? parts[1] : @"";
    
    // Check for entry in launch services database
    NSArray *dbPaths = @[
        @"/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist"
    ];
    
    for (NSString *dbPath in dbPaths) {
        if ([_fileManager fileExistsAtPath:dbPath]) {
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:dbPath];
            if (plist[@"System"] && [plist[@"System"] objectForKey:bundleID]) {
                NSLog(@"[AppDataCleaner] Found reference in LaunchServices database: %@", bundleID);
                return YES;
            }
            
            if (plist[@"User"] && [plist[@"User"] objectForKey:bundleID]) {
                NSLog(@"[AppDataCleaner] Found reference in LaunchServices database: %@", bundleID);
                return YES;
            }
        }
    }
    
    // Check for entries in IconState.plist
    NSArray *iconStatePaths = @[
        @"/var/mobile/Library/SpringBoard/IconState.plist"
    ];
    
    for (NSString *iconPath in iconStatePaths) {
        if ([_fileManager fileExistsAtPath:iconPath]) {
            NSString *command = [NSString stringWithFormat:@"cat '%@' | grep -q '%@' && echo 'found' || echo 'not found'", iconPath, bundleID];
            NSString *result = [self runCommandAndGetOutput:command];
            if ([result containsString:@"found"]) {
                NSLog(@"[AppDataCleaner] Found reference in IconState.plist: %@", bundleID);
                return YES;
            }
        }
    }
    
    // Check for app in notification settings
    NSArray *notifPaths = @[
        @"/var/mobile/Library/Preferences/com.apple.notifyd.plist"
    ];
    
    for (NSString *notifPath in notifPaths) {
        if ([_fileManager fileExistsAtPath:notifPath]) {
            NSString *command = [NSString stringWithFormat:@"cat '%@' | grep -q '%@' && echo 'found' || echo 'not found'", notifPath, bundleID];
            NSString *result = [self runCommandAndGetOutput:command];
            if ([result containsString:@"found"]) {
                NSLog(@"[AppDataCleaner] Found reference in notification settings: %@", bundleID);
                return YES;
            }
        }
    }
    
    // Check for any references in SQLite databases
    NSArray *sqlitePaths = @[
        @"/var/mobile/Library/SpringBoard/ApplicationHistory.sqlite",
        @"/var/mobile/Library/Assistant/SiriAnalytics.db"
    ];
    
    for (NSString *sqlitePath in sqlitePaths) {
        if ([_fileManager fileExistsAtPath:sqlitePath]) {
            // Check for bundle ID
            NSString *command = [NSString stringWithFormat:@"sqlite3 '%@' \"SELECT count(*) FROM sqlite_master WHERE type='table' AND sql LIKE '%%%@%%';\" 2>/dev/null || echo '0'", sqlitePath, bundleID];
            NSString *result = [self runCommandAndGetOutput:command];
            if (![result isEqualToString:@"0"] && ![result isEqualToString:@"error"]) {
                NSLog(@"[AppDataCleaner] Found reference in database: %@", sqlitePath);
                return YES;
            }
            
            // Also check for app name or company if bundle ID not found
            if (appName.length > 3) {
                command = [NSString stringWithFormat:@"sqlite3 '%@' \"SELECT count(*) FROM sqlite_master WHERE type='table' AND sql LIKE '%%%@%%';\" 2>/dev/null || echo '0'", sqlitePath, appName];
                result = [self runCommandAndGetOutput:command];
                if (![result isEqualToString:@"0"] && ![result isEqualToString:@"error"]) {
                    NSLog(@"[AppDataCleaner] Found reference to app name in database: %@", sqlitePath);
                    return YES;
                }
            }
            
            if (company.length > 3) {
                command = [NSString stringWithFormat:@"sqlite3 '%@' \"SELECT count(*) FROM sqlite_master WHERE type='table' AND sql LIKE '%%%@%%';\" 2>/dev/null || echo '0'", sqlitePath, company];
                result = [self runCommandAndGetOutput:command];
                if (![result isEqualToString:@"0"] && ![result isEqualToString:@"error"]) {
                    NSLog(@"[AppDataCleaner] Found reference to company name in database: %@", sqlitePath);
                    return YES;
                }
            }
        }
    }
    
    // If we didn't find anything in system databases, return false
    return NO;
}

// NEW: Method to check if there are keychain items for a bundle ID
@end

#endif
