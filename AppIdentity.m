#import "AppIdentity.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>

NSString *PXNormalizedInstallIdentifierKey(NSString *key) {
    NSString *lowercaseKey = [key.lowercaseString stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *normalizedKey = [NSMutableString stringWithCapacity:lowercaseKey.length];
    BOOL previousCharacterWasSeparator = NO;
    NSCharacterSet *alphanumericCharacters = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger index = 0; index < lowercaseKey.length; index++) {
        unichar character = [lowercaseKey characterAtIndex:index];
        if ([alphanumericCharacters characterIsMember:character]) {
            [normalizedKey appendFormat:@"%C", character];
            previousCharacterWasSeparator = NO;
        } else if (!previousCharacterWasSeparator && normalizedKey.length > 0) {
            [normalizedKey appendString:@"_"];
            previousCharacterWasSeparator = YES;
        }
    }
    while ([normalizedKey hasSuffix:@"_"]) {
        [normalizedKey deleteCharactersInRange:NSMakeRange(normalizedKey.length - 1, 1)];
    }
    return [normalizedKey copy];
}

BOOL PXInstallIdentifierKeyMatches(NSString *key, NSSet<NSString *> *configuredKeys) {
    NSString *normalizedKey = PXNormalizedInstallIdentifierKey(key);
    static NSSet<NSString *> *builtInKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        builtInKeys = [NSSet setWithArray:@[
            @"installation_id", @"installationid",
            @"install_id", @"installid",
            @"app_instance_id", @"appinstanceid"
        ]];
    });
    if ([builtInKeys containsObject:normalizedKey]) {
        return YES;
    }
    for (NSString *configuredKey in configuredKeys) {
        if ([PXNormalizedInstallIdentifierKey(configuredKey) isEqualToString:normalizedKey]) {
            return YES;
        }
    }
    return NO;
}

static BOOL PXPathHasContainerComponents(NSString *path, NSArray<NSString *> *expectedComponents) {
    if (!path.isAbsolutePath) {
        return NO;
    }
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            return NO;
        }
    }
    NSArray<NSString *> *components = path.stringByStandardizingPath.pathComponents;
    NSArray<NSArray<NSString *> *> *allowedPrefixes = @[
        @[@"/", @"var", @"mobile"],
        @[@"/", @"private", @"var", @"mobile"]
    ];
    for (NSArray<NSString *> *allowedPrefix in allowedPrefixes) {
        NSMutableArray<NSString *> *expectedRoot = [allowedPrefix mutableCopy];
        [expectedRoot addObjectsFromArray:expectedComponents];
        if (components.count != expectedRoot.count + 1 ||
            ![[components subarrayWithRange:NSMakeRange(0, expectedRoot.count)] isEqualToArray:expectedRoot] ||
            ![[NSUUID alloc] initWithUUIDString:components.lastObject]) {
            continue;
        }
        return YES;
    }
    return NO;
}

BOOL PXIsValidRealDataContainerRoot(NSString *path) {
    return PXPathHasContainerComponents(path, @[@"Containers", @"Data", @"Application"]) ||
        PXPathHasContainerComponents(path, @[@"Containers", @"Data", @"PluginKitPlugin"]);
}

BOOL PXIsValidRealAppGroupRoot(NSString *path) {
    return PXPathHasContainerComponents(path, @[@"Containers", @"Shared", @"AppGroup"]);
}

BOOL PXAppIdentityBundleIsEligible(NSString *bundleIdentifier,
                                   BOOL applicationEnabled,
                                   BOOL extensionEnabled) {
    static NSSet<NSString *> *supportedSystemApplications;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportedSystemApplications = [NSSet setWithArray:@[
            @"com.apple.mobilesafari",
            @"com.apple.mobileslideshow"
        ]];
    });
    NSString *normalizedBundleIdentifier = bundleIdentifier.lowercaseString;
    if (normalizedBundleIdentifier.length == 0 ||
        [normalizedBundleIdentifier isEqualToString:@"com.hydra.projectx"] ||
        [normalizedBundleIdentifier hasPrefix:@"com.hydra.projectx."] ||
        [normalizedBundleIdentifier isEqualToString:@"com.apple"]) {
        return NO;
    }
    if ([normalizedBundleIdentifier hasPrefix:@"com.apple."]) {
        return applicationEnabled &&
            [supportedSystemApplications containsObject:normalizedBundleIdentifier];
    }
    return applicationEnabled || extensionEnabled;
}

BOOL PXDeviceIdentifierSpoofingIsAllowedForBundle(NSString *bundleIdentifier,
                                                   BOOL applicationEnabled) {
    return PXAppIdentityBundleIsEligible(bundleIdentifier, applicationEnabled, NO);
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *PXEligibleScopedApplications(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopedApplications
) {
    if (![scopedApplications isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *eligibleApplications =
        [NSMutableDictionary dictionary];
    [(NSDictionary *)scopedApplications enumerateKeysAndObjectsUsingBlock:^(id bundleIdentifier,
                                                                            id application,
                                                                            BOOL *stop) {
        (void)stop;
        if ([bundleIdentifier isKindOfClass:[NSString class]] &&
            [application isKindOfClass:[NSDictionary class]] &&
            PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO)) {
            NSMutableDictionary<NSString *, id> *sanitizedApplication =
                [application mutableCopy];
            if (![sanitizedApplication[@"enabled"] isKindOfClass:[NSNumber class]]) {
                sanitizedApplication[@"enabled"] = @NO;
            }
            if (sanitizedApplication[@"extensionPattern"] &&
                ![sanitizedApplication[@"extensionPattern"] isKindOfClass:[NSString class]]) {
                [sanitizedApplication removeObjectForKey:@"extensionPattern"];
            }
            eligibleApplications[bundleIdentifier] = [sanitizedApplication copy];
        }
    }];
    return [eligibleApplications copy];
}

NSSet<NSString *> *PXEnabledEligibleAppBundleIdentifiers(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopedApplications
) {
    NSMutableSet<NSString *> *bundleIdentifiers = [NSMutableSet set];
    [PXEligibleScopedApplications(scopedApplications)
        enumerateKeysAndObjectsUsingBlock:^(NSString *bundleIdentifier,
                                            NSDictionary<NSString *, id> *application,
                                            BOOL *stop) {
        (void)stop;
        if ([application[@"enabled"] boolValue]) {
            [bundleIdentifiers addObject:bundleIdentifier];
        }
    }];
    return [bundleIdentifiers copy];
}

static uint64_t PXAppIdentityHash(NSData *data, uint64_t seed) {
    const uint8_t *bytes = data.bytes;
    uint64_t hash = seed;
    for (NSUInteger index = 0; index < data.length; index++) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    hash ^= hash >> 33;
    hash *= UINT64_C(0xff51afd7ed558ccd);
    hash ^= hash >> 33;
    hash *= UINT64_C(0xc4ceb9fe1a85ec53);
    return hash ^ (hash >> 33);
}

static NSString *PXAppIdentityUUID(NSString *profileSeed, NSString *namespaceName, NSString *identifier) {
    NSString *material = [NSString stringWithFormat:@"%@\0%@\0%@", profileSeed, namespaceName, identifier];
    NSData *data = [material dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t first = PXAppIdentityHash(data, UINT64_C(1469598103934665603));
    uint64_t second = PXAppIdentityHash(data, UINT64_C(1099511628211));
    uint8_t bytes[16];
    for (NSUInteger index = 0; index < 8; index++) {
        bytes[index] = (uint8_t)(first >> (56 - index * 8));
        bytes[index + 8] = (uint8_t)(second >> (56 - index * 8));
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return [[[NSUUID alloc] initWithUUIDBytes:bytes] UUIDString].lowercaseString;
}

@interface PXAppIdentityRecord ()

@property (nonatomic, copy, readwrite) NSString *installUUID;
@property (nonatomic, copy, readwrite) NSString *containerUUID;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *installIdentifierKeys;

@end

@interface PXAppInstallIdentityPolicy ()

@property (nonatomic, strong) PXAppIdentityRecord *identity;

@end


@implementation PXAppInstallIdentityPolicy

- (instancetype)initWithIdentity:(PXAppIdentityRecord *)identity {
    self = [super init];
    if (self) {
        _identity = identity;
    }
    return self;
}

- (BOOL)matchesKey:(NSString *)key {
    return PXInstallIdentifierKeyMatches(key, self.identity.installIdentifierKeys);
}

- (id)valueForRead:(id)originalValue key:(NSString *)key requestedClass:(Class)requestedClass {
    if (![self matchesKey:key]) {
        return originalValue;
    }
    if ([requestedClass isSubclassOfClass:[NSData class]]) {
        return [self.identity.installUUID dataUsingEncoding:NSUTF8StringEncoding];
    }
    return self.identity.installUUID;
}

- (id)valueForWrite:(id)proposedValue key:(NSString *)key {
    if (![self matchesKey:key]) {
        return proposedValue;
    }
    if ([proposedValue isKindOfClass:[NSData class]]) {
        return [self.identity.installUUID dataUsingEncoding:NSUTF8StringEncoding];
    }
    return self.identity.installUUID;
}

- (NSDictionary *)dictionaryByVirtualizingInstallKeys:(NSDictionary *)dictionary {
    if (dictionary.count == 0) {
        return dictionary;
    }
    NSMutableDictionary *result = [dictionary mutableCopy];
    for (id key in dictionary) {
        if ([key isKindOfClass:[NSString class]] && [self matchesKey:key]) {
            result[key] = self.identity.installUUID;
        }
    }
    return [result copy];
}

@end

@interface PXAppIdentityRuntime ()

@property (nonatomic, strong) PXAppPathMapper *pathMapper;

@end


@implementation PXAppIdentityRuntime

static __thread BOOL PXRuntimePathTranslationInProgress = NO;

+ (instancetype)sharedRuntime {
    static PXAppIdentityRuntime *runtime = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = [[self alloc] init];
    });
    return runtime;
}

- (BOOL)configureRealDataRoot:(NSString *)realDataRoot virtualDataRoot:(NSString *)virtualDataRoot {
    @synchronized(self) {
        if (self.pathMapper) {
            return YES;
        }
        self.pathMapper = [[PXAppPathMapper alloc] initWithRealDataRoot:realDataRoot
                                                       virtualDataRoot:virtualDataRoot];
        return self.pathMapper != nil;
    }
}

- (BOOL)addRealGroupRoot:(NSString *)realGroupRoot virtualGroupRoot:(NSString *)virtualGroupRoot {
    @synchronized(self) {
        if (!self.pathMapper) {
            return NO;
        }
        PXAppPathMapper *updatedMapper = [self.pathMapper mapperByAddingRealGroupRoot:realGroupRoot
                                                                     virtualGroupRoot:virtualGroupRoot];
        if (!updatedMapper) {
            return NO;
        }
        self.pathMapper = updatedMapper;
        return YES;
    }
}

- (NSString *)translatedRealPathForPath:(NSString *)path {
    if (PXRuntimePathTranslationInProgress) {
        return path;
    }
    PXAppPathMapper *mapper = nil;
    @synchronized(self) {
        mapper = self.pathMapper;
    }
    if (!mapper) {
        return path;
    }
    PXRuntimePathTranslationInProgress = YES;
    NSString *translatedPath = nil;
    @try {
        translatedPath = [mapper translatedRealPathForPath:path];
    } @finally {
        PXRuntimePathTranslationInProgress = NO;
    }
    return translatedPath ?: path;
}

- (NSString *)translatedObservablePathForPath:(NSString *)path {
    if (PXRuntimePathTranslationInProgress) {
        return path;
    }
    PXAppPathMapper *mapper = nil;
    @synchronized(self) {
        mapper = self.pathMapper;
    }
    if (!mapper) {
        return path;
    }
    PXRuntimePathTranslationInProgress = YES;
    NSString *translatedPath = nil;
    @try {
        translatedPath = [mapper translatedObservablePathForPath:path];
    } @finally {
        PXRuntimePathTranslationInProgress = NO;
    }
    return translatedPath ?: path;
}

- (NSURL *)translatedRealFileURLForURL:(NSURL *)url {
    if (!url.isFileURL) {
        return url;
    }
    NSString *translatedPath = [self translatedRealPathForPath:url.path];
    return [translatedPath isEqualToString:url.path] ? url : [NSURL fileURLWithPath:translatedPath isDirectory:url.hasDirectoryPath];
}

- (NSURL *)translatedObservableFileURLForURL:(NSURL *)url {
    if (!url.isFileURL) {
        return url;
    }
    NSString *translatedPath = [self translatedObservablePathForPath:url.path];
    return [translatedPath isEqualToString:url.path] ? url : [NSURL fileURLWithPath:translatedPath isDirectory:url.hasDirectoryPath];
}

@end

@interface PXAppPathMapper ()

@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *mappings;

@end


@implementation PXAppPathMapper

static BOOL PXPathContainsTraversal(NSString *path) {
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@".."] || [component isEqualToString:@"."]) {
            return YES;
        }
    }
    return NO;
}

static BOOL PXPathHasExactRoot(NSString *path, NSString *root) {
    return [path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSString *PXResolvedExistingPath(NSString *path) {
    char resolvedPath[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolvedPath)) {
        return nil;
    }
    return [NSString stringWithUTF8String:resolvedPath];
}

static NSString *PXNearestExistingAncestor(NSString *path) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *ancestor = path;
    while (ancestor.length > 1 && ![fileManager fileExistsAtPath:ancestor]) {
        NSString *parent = [ancestor stringByDeletingLastPathComponent];
        if ([parent isEqualToString:ancestor]) {
            return nil;
        }
        ancestor = parent;
    }
    return [fileManager fileExistsAtPath:ancestor] ? ancestor : nil;
}

static BOOL PXPathContainsEscapingOrDanglingSymlink(NSString *path,
                                                    NSString *realRoot,
                                                    NSString *resolvedRealRoot) {
    NSString *suffix = [path substringFromIndex:realRoot.length];
    NSString *candidate = realRoot;
    for (NSString *component in suffix.pathComponents) {
        if ([component isEqualToString:@"/"] || component.length == 0) {
            continue;
        }
        candidate = [candidate stringByAppendingPathComponent:component];
        struct stat pathInfo;
        if (lstat(candidate.fileSystemRepresentation, &pathInfo) != 0) {
            return errno != ENOENT;
        }
        if (!S_ISLNK(pathInfo.st_mode)) {
            continue;
        }
        NSString *resolvedCandidate = PXResolvedExistingPath(candidate);
        if (resolvedCandidate.length == 0 || !PXPathHasExactRoot(resolvedCandidate, resolvedRealRoot)) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString *, NSString *> *PXValidatedPathMapping(NSString *realRoot,
                                                                     NSString *virtualRoot) {
    if (![realRoot isAbsolutePath] || ![virtualRoot isAbsolutePath] ||
        PXPathContainsTraversal(realRoot) || PXPathContainsTraversal(virtualRoot)) {
        return nil;
    }
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:realRoot isDirectory:&isDirectory] || !isDirectory) {
        return nil;
    }
    NSString *resolvedRealRoot = PXResolvedExistingPath(realRoot);
    if (resolvedRealRoot.length == 0) {
        return nil;
    }
    return @{
        @"real": realRoot.stringByStandardizingPath,
        @"resolvedReal": resolvedRealRoot,
        @"virtual": virtualRoot.stringByStandardizingPath
    };
}

- (nullable instancetype)initWithRealDataRoot:(NSString *)realDataRoot
                               virtualDataRoot:(NSString *)virtualDataRoot {
    NSDictionary<NSString *, NSString *> *mapping = PXValidatedPathMapping(realDataRoot, virtualDataRoot);
    if (!mapping) {
        return nil;
    }
    self = [super init];
    if (self) {
        _mappings = @[mapping];
    }
    return self;
}

- (nullable instancetype)initWithMappings:(NSArray<NSDictionary<NSString *, NSString *> *> *)mappings {
    self = [super init];
    if (self) {
        _mappings = [mappings copy];
    }
    return self;
}

- (BOOL)realPathIsSafe:(NSString *)realPath
               mapping:(NSDictionary<NSString *, NSString *> *)mapping {
    NSString *standardPath = realPath.stringByStandardizingPath;
    NSString *realRoot = mapping[@"real"];
    NSString *resolvedRealRoot = mapping[@"resolvedReal"];
    if (!PXPathHasExactRoot(standardPath, realRoot) &&
        !PXPathHasExactRoot(realPath, resolvedRealRoot)) {
        return NO;
    }
    if (PXPathHasExactRoot(standardPath, realRoot) &&
        PXPathContainsEscapingOrDanglingSymlink(standardPath, realRoot, resolvedRealRoot)) {
        return NO;
    }
    NSString *ancestor = PXNearestExistingAncestor(standardPath);
    NSString *resolvedAncestor = ancestor ? PXResolvedExistingPath(ancestor) : nil;
    return resolvedAncestor.length > 0 && PXPathHasExactRoot(resolvedAncestor, resolvedRealRoot);
}

- (NSString *)translatedRealPathForPath:(NSString *)path {
    if (![path isAbsolutePath] || PXPathContainsTraversal(path)) {
        return path;
    }
    for (NSDictionary<NSString *, NSString *> *mapping in self.mappings) {
        NSString *virtualRoot = mapping[@"virtual"];
        if (!PXPathHasExactRoot(path, virtualRoot)) {
            continue;
        }
        NSString *suffix = [path substringFromIndex:virtualRoot.length];
        NSString *realPath = [mapping[@"real"] stringByAppendingString:suffix];
        return [self realPathIsSafe:realPath mapping:mapping] ? realPath : path;
    }
    return path;
}

- (NSString *)translatedObservablePathForPath:(NSString *)path {
    if (![path isAbsolutePath] || PXPathContainsTraversal(path)) {
        return path;
    }
    for (NSDictionary<NSString *, NSString *> *mapping in self.mappings) {
        NSString *realRoot = mapping[@"real"];
        NSString *sourceRoot = nil;
        if (PXPathHasExactRoot(path, realRoot)) {
            sourceRoot = realRoot;
        } else if (PXPathHasExactRoot(path, mapping[@"resolvedReal"])) {
            sourceRoot = mapping[@"resolvedReal"];
        }
        if (!sourceRoot || ![self realPathIsSafe:path mapping:mapping]) {
            continue;
        }
        NSString *suffix = [path substringFromIndex:sourceRoot.length];
        return [mapping[@"virtual"] stringByAppendingString:suffix];
    }
    return path;
}

- (nullable instancetype)mapperByAddingRealGroupRoot:(NSString *)realGroupRoot
                                     virtualGroupRoot:(NSString *)virtualGroupRoot {
    NSDictionary<NSString *, NSString *> *mapping = PXValidatedPathMapping(realGroupRoot, virtualGroupRoot);
    if (!mapping) {
        return nil;
    }
    for (NSDictionary<NSString *, NSString *> *existingMapping in self.mappings) {
        if ([existingMapping[@"real"] isEqualToString:mapping[@"real"]] &&
            [existingMapping[@"virtual"] isEqualToString:mapping[@"virtual"]]) {
            return self;
        }
    }
    return [[PXAppPathMapper alloc] initWithMappings:[self.mappings arrayByAddingObject:mapping]];
}

@end

@interface PXAppGroupIdentityRecord ()

@property (nonatomic, copy, readwrite) NSString *containerUUID;

@end

@implementation PXAppGroupIdentityRecord

+ (instancetype)identityForProfileSeed:(NSString *)profileSeed
                        groupIdentifier:(NSString *)groupIdentifier {
    PXAppGroupIdentityRecord *identity = [[self alloc] init];
    identity.containerUUID = PXAppIdentityUUID(profileSeed, @"app-group", groupIdentifier);
    return identity;
}

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{@"containerUUID": self.containerUUID};
}

+ (nullable instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList {
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *containerUUID = [propertyList[@"containerUUID"] isKindOfClass:[NSString class]]
        ? propertyList[@"containerUUID"]
        : nil;
    if (containerUUID.length == 0 || ![[NSUUID alloc] initWithUUIDString:containerUUID]) {
        return nil;
    }
    PXAppGroupIdentityRecord *identity = [[self alloc] init];
    identity.containerUUID = containerUUID;
    return identity;
}

@end

@implementation PXAppIdentityRecord

+ (instancetype)identityForProfileSeed:(NSString *)profileSeed
                       bundleIdentifier:(NSString *)bundleIdentifier
                   installIdentifierKeys:(NSSet<NSString *> *)installIdentifierKeys {
    PXAppIdentityRecord *identity = [[self alloc] init];
    identity.installUUID = PXAppIdentityUUID(profileSeed, @"install", bundleIdentifier);
    identity.containerUUID = PXAppIdentityUUID(profileSeed, @"container", bundleIdentifier);
    identity.installIdentifierKeys = [installIdentifierKeys copy] ?: [NSSet set];
    return identity;
}

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{
        @"installUUID": self.installUUID,
        @"containerUUID": self.containerUUID,
        @"installIdentifierKeys": [self.installIdentifierKeys.allObjects sortedArrayUsingSelector:@selector(compare:)]
    };
}

+ (nullable instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList {
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *installUUID = [propertyList[@"installUUID"] isKindOfClass:[NSString class]]
        ? propertyList[@"installUUID"]
        : nil;
    NSString *containerUUID = [propertyList[@"containerUUID"] isKindOfClass:[NSString class]]
        ? propertyList[@"containerUUID"]
        : nil;
    NSArray *installIdentifierKeys = [propertyList[@"installIdentifierKeys"] isKindOfClass:[NSArray class]]
        ? propertyList[@"installIdentifierKeys"]
        : @[];
    if (installUUID.length == 0 || containerUUID.length == 0 ||
        ![[NSUUID alloc] initWithUUIDString:installUUID] ||
        ![[NSUUID alloc] initWithUUIDString:containerUUID]) {
        return nil;
    }
    for (id installIdentifierKey in installIdentifierKeys) {
        if (![installIdentifierKey isKindOfClass:[NSString class]]) {
            return nil;
        }
    }
    PXAppIdentityRecord *identity = [[self alloc] init];
    identity.installUUID = installUUID;
    identity.containerUUID = containerUUID;
    identity.installIdentifierKeys = [NSSet setWithArray:installIdentifierKeys];
    return identity;
}

@end
