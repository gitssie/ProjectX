#import "PXRootHidePath.h"
#import "PXScopedAppStore.h"

@interface PXScopedAppStore ()
@property (nonatomic, copy, readwrite) NSString *filePath;
@end

@implementation PXScopedAppStore

- (instancetype)initWithFilePath:(NSString *)filePath {
    self = [super init];
    if (self) {
        _filePath = [filePath.stringByStandardizingPath copy];
    }
    return self;
}

- (NSError *)storeErrorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:@"com.hydra.projectx"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApplicationsWithError:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.filePath]) {
        return @{};
    }
    NSDictionary<NSString *, id> *propertyList =
        PXProfileReadDictionary(self.filePath);
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopedApplications =
        [propertyList[@"ScopedApps"] isKindOfClass:[NSDictionary class]]
            ? propertyList[@"ScopedApps"]
            : nil;
    if (!scopedApplications) {
        if (error) {
            *error = [self storeErrorWithCode:4007
                                  description:@"Global scoped app state is invalid"];
        }
        return nil;
    }
    for (id bundleIdentifier in scopedApplications) {
        if (![bundleIdentifier isKindOfClass:[NSString class]] ||
            ![scopedApplications[bundleIdentifier] isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = [self storeErrorWithCode:4007
                                      description:@"Global scoped app records are invalid"];
            }
            return nil;
        }
    }
    return [scopedApplications copy];
}

- (BOOL)replaceScopedApplications:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)scopedApplications
                            error:(NSError **)error {
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager]
        createDirectoryAtPath:self.filePath.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES
        attributes:nil
        error:&directoryError]) {
        if (error) *error = directoryError;
        return NO;
    }
    NSDictionary<NSString *, id> *propertyList = @{
        @"ScopedApps": scopedApplications ?: @{}
    };
    if (![propertyList writeToFile:self.filePath atomically:YES]) {
        if (error) {
            *error = [self storeErrorWithCode:4006
                                  description:@"Failed to save global scoped apps"];
        }
        return NO;
    }
    return YES;
}

@end
