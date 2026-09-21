#import "PXKeychainOneShotExecution.h"

#import "PXRootHidePath.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

typedef NS_ENUM(NSInteger, PXKeychainOneShotExecutionErrorCode) {
    PXKeychainOneShotExecutionErrorInvalidTarget = 20,
    PXKeychainOneShotExecutionErrorProcess = 21,
    PXKeychainOneShotExecutionErrorTimeout = 22,
    PXKeychainOneShotExecutionErrorInvalidPropertyList = 23,
    PXKeychainOneShotExecutionErrorUnsafeArtifacts = 24,
    PXKeychainOneShotExecutionErrorInvalidSignature = 25,
    PXKeychainOneShotExecutionErrorInvalidResponse = 26
};

static const NSUInteger PXKeychainOneShotMaximumProcessOutput = 1024 * 1024;
static const NSUInteger PXKeychainOneShotMaximumPresentedErrorLength = 512;

static NSString *PXKeychainOneShotBoundedErrorText(NSString *text) {
    NSString *trimmed = [text isKindOfClass:[NSString class]]
        ? [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"";
    if (trimmed.length <= PXKeychainOneShotMaximumPresentedErrorLength) {
        return trimmed;
    }
    return [[trimmed substringToIndex:PXKeychainOneShotMaximumPresentedErrorLength]
        stringByAppendingString:@"…"];
}

static NSError *PXKeychainOneShotErrorWithContext(NSError *underlyingError,
                                                   NSString *stage,
                                                   NSString *reference) {
    NSError *baseError = underlyingError ?: [NSError
        errorWithDomain:PXKeychainOneShotErrorDomain
        code:PXKeychainOneShotExecutionErrorInvalidResponse
        userInfo:@{NSLocalizedDescriptionKey: @"One-shot Keychain cleanup failed"}];
    NSString *safeStage = stage.length > 0 ? stage : @"unknown";
    NSString *safeReference = reference.length > 0 ? reference.lowercaseString : @"unavailable";
    NSString *reason = PXKeychainOneShotBoundedErrorText(baseError.localizedDescription);
    NSMutableDictionary<NSString *, id> *userInfo = [baseError.userInfo mutableCopy]
        ?: [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:
        @"%@ [stage=%@ domain=%@ code=%ld reference=%@]",
        reason.length > 0 ? reason : @"One-shot Keychain cleanup failed",
        safeStage,
        baseError.domain,
        (long)baseError.code,
        safeReference];
    userInfo[@"stage"] = safeStage;
    userInfo[@"reference"] = safeReference;
    return [NSError errorWithDomain:baseError.domain code:baseError.code userInfo:userInfo];
}

static BOOL PXKeychainOneShotExecutionFail(NSError * _Nullable * _Nullable error,
                                           PXKeychainOneShotExecutionErrorCode code,
                                           NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:PXKeychainOneShotErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

static BOOL PXKeychainOneShotExecutionGroupIsSafeForTeam(NSString *accessGroup,
                                                          NSString *teamPrefix) {
    if (![accessGroup isKindOfClass:[NSString class]] ||
        accessGroup.length <= teamPrefix.length + 1 ||
        ![accessGroup hasPrefix:[teamPrefix stringByAppendingString:@"."]] ||
        [accessGroup containsString:@"$"] ||
        [accessGroup containsString:@"/"] ||
        [accessGroup containsString:@"*"]) {
        return NO;
    }
    NSString *suffix = [accessGroup substringFromIndex:teamPrefix.length + 1].lowercaseString;
    return ![suffix isEqualToString:@"com.apple"] &&
        ![suffix hasPrefix:@"com.apple."] &&
        ![suffix isEqualToString:@"group.com.apple"] &&
        ![suffix hasPrefix:@"group.com.apple."];
}

static BOOL PXKeychainOneShotDrainDescriptor(int descriptor,
                                             NSMutableData *data,
                                             NSError * _Nullable * _Nullable error) {
    uint8_t buffer[4096];
    while (YES) {
        ssize_t bytesRead = read(descriptor, buffer, sizeof(buffer));
        if (bytesRead > 0) {
            if (data.length + (NSUInteger)bytesRead > PXKeychainOneShotMaximumProcessOutput) {
                return PXKeychainOneShotExecutionFail(
                    error,
                    PXKeychainOneShotExecutionErrorProcess,
                    @"One-shot helper process produced excessive output");
            }
            [data appendBytes:buffer length:(NSUInteger)bytesRead];
            continue;
        }
        if (bytesRead == 0 || errno == EAGAIN || errno == EWOULDBLOCK) {
            return YES;
        }
        if (errno != EINTR) {
            return PXKeychainOneShotExecutionFail(
                error,
                PXKeychainOneShotExecutionErrorProcess,
                @"One-shot helper process output could not be read");
        }
    }
}

@implementation PXKeychainOneShotProcessRunner

- (BOOL)runExecutable:(NSString *)executablePath
             arguments:(NSArray<NSString *> *)arguments
               timeout:(NSTimeInterval)timeout
        standardOutput:(NSData * _Nullable * _Nullable)standardOutput
                 error:(NSError * _Nullable * _Nullable)error {
    if (executablePath.length == 0 || !executablePath.isAbsolutePath || timeout <= 0 ||
        access(executablePath.fileSystemRepresentation, X_OK) != 0) {
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"Required one-shot helper executable is unavailable");
    }

    int outputPipe[2] = {-1, -1};
    int errorPipe[2] = {-1, -1};
    if (pipe(outputPipe) != 0 || pipe(errorPipe) != 0) {
        if (outputPipe[0] >= 0) close(outputPipe[0]);
        if (outputPipe[1] >= 0) close(outputPipe[1]);
        if (errorPipe[0] >= 0) close(errorPipe[0]);
        if (errorPipe[1] >= 0) close(errorPipe[1]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process pipes could not be created");
    }

    posix_spawn_file_actions_t actions;
    int actionsStatus = posix_spawn_file_actions_init(&actions);
    BOOL actionsInitialized = actionsStatus == 0;
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, errorPipe[0]);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, outputPipe[1]);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, errorPipe[1]);
    if (actionsStatus != 0) {
        if (actionsInitialized) posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[0]);
        close(outputPipe[1]);
        close(errorPipe[0]);
        close(errorPipe[1]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process actions could not be prepared");
    }

    NSUInteger argumentCount = arguments.count;
    char **argv = calloc(argumentCount + 2, sizeof(char *));
    BOOL argumentsReady = argv != NULL;
    if (argumentsReady) {
        argv[0] = strdup(executablePath.fileSystemRepresentation);
        argumentsReady = argv[0] != NULL;
    }
    for (NSUInteger index = 0; argumentsReady && index < argumentCount; index++) {
        NSString *argument = arguments[index];
        if (![argument isKindOfClass:[NSString class]]) {
            argumentsReady = NO;
            break;
        }
        argv[index + 1] = strdup(argument.UTF8String);
        argumentsReady = argv[index + 1] != NULL;
    }
    if (!argumentsReady) {
        if (argv) {
            for (NSUInteger index = 0; index < argumentCount + 1; index++) {
                free(argv[index]);
            }
            free(argv);
        }
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[0]);
        close(outputPipe[1]);
        close(errorPipe[0]);
        close(errorPipe[1]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process arguments could not be prepared");
    }

    pid_t processID = 0;
    int spawnStatus = posix_spawn(&processID,
                                  executablePath.fileSystemRepresentation,
                                  &actions,
                                  NULL,
                                  argv,
                                  environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger index = 0; index < argumentCount + 1; index++) {
        free(argv[index]);
    }
    free(argv);
    close(outputPipe[1]);
    close(errorPipe[1]);
    if (spawnStatus != 0) {
        close(outputPipe[0]);
        close(errorPipe[0]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process could not be started");
    }

    int processStatus = 0;
    int outputFlags = fcntl(outputPipe[0], F_GETFL);
    int errorFlags = fcntl(errorPipe[0], F_GETFL);
    if (outputFlags < 0 || errorFlags < 0 ||
        fcntl(outputPipe[0], F_SETFL, outputFlags | O_NONBLOCK) != 0 ||
        fcntl(errorPipe[0], F_SETFL, errorFlags | O_NONBLOCK) != 0) {
        kill(processID, SIGKILL);
        while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
        close(outputPipe[0]);
        close(errorPipe[0]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process output could not be configured");
    }
    NSMutableData *outputData = [NSMutableData data];
    NSMutableData *errorData = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL processFinished = NO;
    BOOL outputValid = YES;
    while (!processFinished) {
        outputValid = PXKeychainOneShotDrainDescriptor(outputPipe[0], outputData, error) &&
            PXKeychainOneShotDrainDescriptor(errorPipe[0], errorData, error);
        if (!outputValid) {
            kill(processID, SIGKILL);
        }
        pid_t waitResult = waitpid(processID, &processStatus, WNOHANG);
        if (waitResult == processID) {
            processFinished = YES;
            break;
        }
        if (waitResult < 0 && errno != EINTR) {
            kill(processID, SIGKILL);
            while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
            close(outputPipe[0]);
            close(errorPipe[0]);
            return PXKeychainOneShotExecutionFail(error,
                                                  PXKeychainOneShotExecutionErrorProcess,
                                                  @"One-shot helper process could not be observed");
        }
        if (!outputValid) {
            while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
            close(outputPipe[0]);
            close(errorPipe[0]);
            return NO;
        }
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
            kill(processID, SIGKILL);
            while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
            close(outputPipe[0]);
            close(errorPipe[0]);
            return PXKeychainOneShotExecutionFail(error,
                                                  PXKeychainOneShotExecutionErrorTimeout,
                                                  @"One-shot helper process timed out");
        }
        usleep(10 * 1000);
    }
    BOOL finalOutputValid = PXKeychainOneShotDrainDescriptor(outputPipe[0], outputData, error) &&
        PXKeychainOneShotDrainDescriptor(errorPipe[0], errorData, error);
    close(outputPipe[0]);
    close(errorPipe[0]);
    if (!finalOutputValid) {
        return NO;
    }
    if (!WIFEXITED(processStatus) || WEXITSTATUS(processStatus) != 0) {
        NSString *reportedError = [[NSString alloc] initWithData:errorData
                                                        encoding:NSUTF8StringEncoding];
        NSString *boundedError = PXKeychainOneShotBoundedErrorText(reportedError);
        NSString *reason = boundedError.length > 0
            ? [NSString stringWithFormat:@"One-shot helper process failed: %@",
                boundedError]
            : @"One-shot helper process failed";
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              reason);
    }
    if (standardOutput) {
        *standardOutput = [outputData copy];
    }
    return YES;
}

@end

@implementation PXKeychainOneShotTargetResolver

- (NSString *)executablePathForBundleIdentifier:(NSString *)bundleIdentifier
                                           error:(NSError * _Nullable * _Nullable)error {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    SEL bundleURLSelector = NSSelectorFromString(@"bundleURL");
    SEL executableSelector = NSSelectorFromString(@"bundleExecutable");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySelector]) {
        PXKeychainOneShotExecutionFail(error,
                                       PXKeychainOneShotExecutionErrorInvalidTarget,
                                       @"LaunchServices target resolution is unavailable");
        return nil;
    }
    id (*proxyGetter)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))
        [proxyClass methodForSelector:proxySelector];
    id proxy = proxyGetter(proxyClass, proxySelector, bundleIdentifier);
    if (!proxy || ![proxy respondsToSelector:bundleURLSelector] ||
        ![proxy respondsToSelector:executableSelector]) {
        PXKeychainOneShotExecutionFail(error,
                                       PXKeychainOneShotExecutionErrorInvalidTarget,
                                       @"Selected App is not installed or has no executable metadata");
        return nil;
    }
    id (*propertyGetter)(id, SEL) = (id (*)(id, SEL))[proxy methodForSelector:bundleURLSelector];
    NSURL *bundleURL = propertyGetter(proxy, bundleURLSelector);
    propertyGetter = (id (*)(id, SEL))[proxy methodForSelector:executableSelector];
    NSString *executableName = propertyGetter(proxy, executableSelector);
    if (![bundleURL isKindOfClass:[NSURL class]] || !bundleURL.isFileURL ||
        !bundleURL.path.isAbsolutePath || executableName.length == 0 ||
        [executableName rangeOfString:@"/"].location != NSNotFound) {
        PXKeychainOneShotExecutionFail(error,
                                       PXKeychainOneShotExecutionErrorInvalidTarget,
                                       @"Selected App executable could not be resolved");
        return nil;
    }
    NSString *bundlePath = bundleURL.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *executablePath = [[bundlePath stringByAppendingPathComponent:executableName]
        stringByStandardizingPath].stringByResolvingSymlinksInPath;
    if (![executablePath hasPrefix:[bundlePath stringByAppendingString:@"/"]] ||
        ![[NSFileManager defaultManager] isExecutableFileAtPath:executablePath]) {
        PXKeychainOneShotExecutionFail(error,
                                       PXKeychainOneShotExecutionErrorInvalidTarget,
                                       @"Selected App executable path is invalid");
        return nil;
    }
    return executablePath;
}

@end

@interface PXKeychainOneShotExecution ()

@property (nonatomic, strong) NSFileManager *fileManager;
@property (nonatomic, strong) id<PXKeychainOneShotProcessRunning> processRunner;
@property (nonatomic, strong) id<PXKeychainOneShotTargetResolving> targetResolver;
@property (nonatomic, copy) NSString *workerTemplatePath;
@property (nonatomic, copy) NSString *ldidPath;
@property (nonatomic, copy) NSString *operationsRootDirectory;
@property (nonatomic, assign) NSTimeInterval workerTimeout;
@property (nonatomic, strong) dispatch_queue_t executionQueue;

- (nullable PXKeychainCommandResponse *)executePreparedRequest:(PXKeychainCommandRequest *)request
                                             workerEntitlements:(NSDictionary<NSString *, id> *)workerEntitlements
                                                          error:(NSError * _Nullable * _Nullable)error;
- (BOOL)prepareRootHideDependencyAnchorAtOperationDirectory:(NSString *)operationDirectory
                                                      error:(NSError * _Nullable * _Nullable)error;
- (BOOL)validateRootHideDependencyAnchorAtOperationDirectory:(NSString *)operationDirectory
                                                       error:(NSError * _Nullable * _Nullable)error;
- (BOOL)validateTrustedOperationDirectory:(NSString *)operationDirectory
                                     error:(NSError * _Nullable * _Nullable)error;

@end

@implementation PXKeychainOneShotExecution

- (instancetype)init {
    return [self initWithFileManager:[NSFileManager defaultManager]
                       processRunner:[[PXKeychainOneShotProcessRunner alloc] init]
                      targetResolver:[[PXKeychainOneShotTargetResolver alloc] init]
                  workerTemplatePath:PXKeychainOneShotWorkerTemplatePath()
                            ldidPath:PXBootstrapCommandPath(@"ldid")
             operationsRootDirectory:PXKeychainOneShotOperationsPath()
                       workerTimeout:15];
}

- (instancetype)initWithFileManager:(NSFileManager *)fileManager
                       processRunner:(id<PXKeychainOneShotProcessRunning>)processRunner
                      targetResolver:(id<PXKeychainOneShotTargetResolving>)targetResolver
                  workerTemplatePath:(NSString *)workerTemplatePath
                            ldidPath:(NSString *)ldidPath
             operationsRootDirectory:(NSString *)operationsRootDirectory
                       workerTimeout:(NSTimeInterval)workerTimeout {
    self = [super init];
    if (self) {
        NSParameterAssert(fileManager != nil);
        NSParameterAssert(processRunner != nil);
        NSParameterAssert(targetResolver != nil);
        NSParameterAssert(workerTemplatePath.isAbsolutePath);
        NSParameterAssert(ldidPath.isAbsolutePath);
        NSParameterAssert(operationsRootDirectory.isAbsolutePath);
        NSParameterAssert(workerTimeout > 0);
        _fileManager = fileManager;
        _processRunner = processRunner;
        _targetResolver = targetResolver;
        _workerTemplatePath = [workerTemplatePath.stringByStandardizingPath copy];
        _ldidPath = [ldidPath.stringByStandardizingPath copy];
        _operationsRootDirectory = [operationsRootDirectory.stringByStandardizingPath copy];
        _workerTimeout = workerTimeout;
        _executionQueue = dispatch_queue_create("com.hydra.projectx.keychain-one-shot-execution",
                                                DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSDictionary<NSString *, id> *)propertyListDictionaryFromData:(NSData *)data
                                                            error:(NSError * _Nullable * _Nullable)error {
    NSMutableArray<NSData *> *slices = [NSMutableArray array];
    NSString *xml = data.length > 0
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : nil;
    NSString *xmlMarker = @"<?xml";
    NSRange firstMarker = [xml rangeOfString:xmlMarker];
    if (firstMarker.location != NSNotFound) {
        NSString *prefix = [xml substringToIndex:firstMarker.location];
        if ([prefix stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0) {
            PXKeychainOneShotExecutionFail(error,
                                           PXKeychainOneShotExecutionErrorInvalidPropertyList,
                                           @"Signed entitlement data contains an invalid prefix");
            return nil;
        }
        NSUInteger sliceStart = firstMarker.location;
        while (sliceStart < xml.length) {
            NSRange searchRange = NSMakeRange(sliceStart + xmlMarker.length,
                xml.length - sliceStart - xmlMarker.length);
            NSRange nextMarker = [xml rangeOfString:xmlMarker options:0 range:searchRange];
            NSUInteger sliceEnd = nextMarker.location == NSNotFound
                ? xml.length
                : nextMarker.location;
            NSData *slice = [[xml substringWithRange:NSMakeRange(sliceStart,
                sliceEnd - sliceStart)] dataUsingEncoding:NSUTF8StringEncoding];
            if (slice) [slices addObject:slice];
            if (nextMarker.location == NSNotFound) break;
            sliceStart = nextMarker.location;
        }
    } else if (data.length > 0) {
        [slices addObject:data];
    }

    NSDictionary<NSString *, id> *firstEntitlements = nil;
    NSError *serializationError = nil;
    for (NSData *slice in slices) {
        id propertyList = [NSPropertyListSerialization propertyListWithData:slice
                                                                     options:NSPropertyListImmutable
                                                                      format:nil
                                                                       error:&serializationError];
        if (![propertyList isKindOfClass:[NSDictionary class]] ||
            (firstEntitlements && ![firstEntitlements isEqualToDictionary:propertyList])) {
            if (error) {
                *error = serializationError ?: [NSError
                    errorWithDomain:PXKeychainOneShotErrorDomain
                    code:PXKeychainOneShotExecutionErrorInvalidPropertyList
                    userInfo:@{NSLocalizedDescriptionKey:
                        @"Signed entitlement slices are invalid or inconsistent"}];
            }
            return nil;
        }
        firstEntitlements = propertyList;
    }
    if (!firstEntitlements && error) {
        *error = [NSError errorWithDomain:PXKeychainOneShotErrorDomain
                                     code:PXKeychainOneShotExecutionErrorInvalidPropertyList
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     @"Signed entitlement data is missing or invalid"}];
    }
    return firstEntitlements;
}

- (NSDictionary<NSString *, id> *)signedEntitlementsForTargetBundleIdentifier:
    (NSString *)bundleIdentifier
                                                                             error:
    (NSError * _Nullable * _Nullable)error {
    NSString *targetExecutable = [self.targetResolver
        executablePathForBundleIdentifier:bundleIdentifier
        error:error];
    if (!targetExecutable) {
        return nil;
    }
    NSData *entitlementData = nil;
    if (![self.processRunner runExecutable:self.ldidPath
                                 arguments:@[@"-e", targetExecutable]
                                   timeout:self.workerTimeout
                            standardOutput:&entitlementData
                                     error:error]) {
        return nil;
    }
    return [self propertyListDictionaryFromData:entitlementData error:error];
}

- (BOOL)validateWorkerEntitlements:(NSDictionary<NSString *, id> *)workerEntitlements
                           request:(PXKeychainCommandRequest *)request
                             error:(NSError * _Nullable * _Nullable)error {
    NSString *applicationIdentifier = [workerEntitlements[@"application-identifier"]
        isKindOfClass:[NSString class]] ? workerEntitlements[@"application-identifier"] : nil;
    NSString *alternateApplicationIdentifier = [workerEntitlements[@"com.apple.application-identifier"]
        isKindOfClass:[NSString class]] ? workerEntitlements[@"com.apple.application-identifier"] : nil;
    NSArray<NSString *> *accessGroups = [workerEntitlements[@"keychain-access-groups"]
        isKindOfClass:[NSArray class]] ? workerEntitlements[@"keychain-access-groups"] : nil;
    NSString *expectedSuffix = [@"." stringByAppendingString:request.targetBundleID];
    if (request.includesSynchronizableItems ||
        applicationIdentifier.length <= expectedSuffix.length ||
        ![applicationIdentifier hasSuffix:expectedSuffix] ||
        ![alternateApplicationIdentifier isEqualToString:applicationIdentifier] ||
        accessGroups.count == 0 ||
        ![accessGroups.firstObject isKindOfClass:[NSString class]] ||
        ![accessGroups.firstObject isEqualToString:applicationIdentifier] ||
        [applicationIdentifier containsString:@"*"] ||
        [applicationIdentifier containsString:@"$"] ||
        [applicationIdentifier containsString:@"/"]) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorInvalidSignature,
            @"One-shot worker authority is not bound to the exact target application group");
    }
    if (!request.includesSharedAccessGroups && accessGroups.count != 1) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorInvalidSignature,
            @"One-shot worker contains unrequested target Keychain groups");
    }
    NSString *teamPrefix = [applicationIdentifier substringToIndex:
        applicationIdentifier.length - expectedSuffix.length];
    NSMutableSet<NSString *> *uniqueAccessGroups = [NSMutableSet set];
    for (id accessGroup in accessGroups) {
        if (!PXKeychainOneShotExecutionGroupIsSafeForTeam(accessGroup, teamPrefix) ||
            [uniqueAccessGroups containsObject:accessGroup]) {
            return PXKeychainOneShotExecutionFail(
                error,
                PXKeychainOneShotExecutionErrorInvalidSignature,
                @"One-shot worker contains an unsafe or duplicate Keychain group");
        }
        [uniqueAccessGroups addObject:accessGroup];
    }
    return YES;
}

- (BOOL)prepareOperationsRootWithError:(NSError * _Nullable * _Nullable)error {
    struct stat rootInfo;
    if (lstat(self.operationsRootDirectory.fileSystemRepresentation, &rootInfo) == 0 &&
        (!S_ISDIR(rootInfo.st_mode) || S_ISLNK(rootInfo.st_mode))) {
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorUnsafeArtifacts,
                                              @"One-shot operation root is not a safe directory");
    }
    NSError *directoryError = nil;
    if (![self.fileManager createDirectoryAtPath:self.operationsRootDirectory
                      withIntermediateDirectories:YES
                                       attributes:@{NSFilePosixPermissions: @0700}
                                            error:&directoryError]) {
        if (error) *error = directoryError;
        return NO;
    }
    if (lstat(self.operationsRootDirectory.fileSystemRepresentation, &rootInfo) != 0 ||
        !S_ISDIR(rootInfo.st_mode) || S_ISLNK(rootInfo.st_mode) ||
        chmod(self.operationsRootDirectory.fileSystemRepresentation, 0700) != 0) {
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorUnsafeArtifacts,
                                              @"One-shot operation root could not be secured");
    }
    NSError *listingError = nil;
    NSArray<NSString *> *existingOperations = [self.fileManager
        contentsOfDirectoryAtPath:self.operationsRootDirectory
        error:&listingError];
    if (!existingOperations) {
        if (error) *error = listingError;
        return NO;
    }
    for (NSString *leafName in existingOperations) {
        if (![[NSUUID alloc] initWithUUIDString:leafName]) {
            return PXKeychainOneShotExecutionFail(error,
                                                  PXKeychainOneShotExecutionErrorUnsafeArtifacts,
                                                  @"One-shot operation root contains an unknown artifact");
        }
        NSString *stalePath = [self.operationsRootDirectory stringByAppendingPathComponent:leafName];
        struct stat staleInfo;
        if (lstat(stalePath.fileSystemRepresentation, &staleInfo) != 0 ||
            !S_ISDIR(staleInfo.st_mode) || S_ISLNK(staleInfo.st_mode)) {
            return PXKeychainOneShotExecutionFail(error,
                                                  PXKeychainOneShotExecutionErrorUnsafeArtifacts,
                                                  @"One-shot operation root contains an unsafe artifact");
        }
        NSError *removalError = nil;
        if (![self.fileManager removeItemAtPath:stalePath error:&removalError]) {
            if (error) *error = removalError;
            return NO;
        }
    }
    return YES;
}

- (BOOL)validateTrustedOperationDirectory:(NSString *)operationDirectory
                                     error:(NSError * _Nullable * _Nullable)error {
    NSString *standardRoot = self.operationsRootDirectory.stringByStandardizingPath;
    NSString *standardOperation = operationDirectory.stringByStandardizingPath;
    NSString *operationLeaf = standardOperation.lastPathComponent;
    NSUUID *operationIdentifier = [[NSUUID alloc] initWithUUIDString:operationLeaf];
    if (!standardRoot.isAbsolutePath || !standardOperation.isAbsolutePath ||
        ![operationDirectory isEqualToString:standardOperation] ||
        ![standardOperation.stringByDeletingLastPathComponent isEqualToString:standardRoot] ||
        !operationIdentifier ||
        [operationLeaf caseInsensitiveCompare:operationIdentifier.UUIDString] != NSOrderedSame) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"One-shot operation directory is not a direct UUID child of its trusted root");
    }

    struct stat rootInfo;
    struct stat operationInfo;
    if (lstat(standardRoot.fileSystemRepresentation, &rootInfo) != 0 ||
        !S_ISDIR(rootInfo.st_mode) || S_ISLNK(rootInfo.st_mode) ||
        lstat(standardOperation.fileSystemRepresentation, &operationInfo) != 0 ||
        !S_ISDIR(operationInfo.st_mode) || S_ISLNK(operationInfo.st_mode) ||
        (rootInfo.st_mode & 077) != 0 || (operationInfo.st_mode & 077) != 0 ||
        rootInfo.st_uid != operationInfo.st_uid) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"One-shot operation directory ownership or permissions are unsafe");
    }

    char canonicalRootDirectory[PATH_MAX] = {0};
    char canonicalOperationDirectory[PATH_MAX] = {0};
    if (!realpath(standardRoot.fileSystemRepresentation, canonicalRootDirectory) ||
        !realpath(standardOperation.fileSystemRepresentation, canonicalOperationDirectory)) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"One-shot operation directory paths could not be canonicalized");
    }
    NSString *canonicalRoot = [NSString stringWithUTF8String:canonicalRootDirectory];
    NSString *canonicalOperation = [NSString stringWithUTF8String:canonicalOperationDirectory];
    if (![canonicalOperation.stringByDeletingLastPathComponent isEqualToString:canonicalRoot]) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"One-shot operation directory escaped its trusted root");
    }
    return YES;
}

- (BOOL)prepareRootHideDependencyAnchorAtOperationDirectory:(NSString *)operationDirectory
                                                      error:(NSError * _Nullable * _Nullable)error {
    NSString *dependencyRootPath = PXJBRootPath(@"/");
    struct stat dependencyRootInfo;
    if (lstat(dependencyRootPath.fileSystemRepresentation, &dependencyRootInfo) != 0 ||
        !S_ISDIR(dependencyRootInfo.st_mode) || S_ISLNK(dependencyRootInfo.st_mode)) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"RootHide dependency root is unavailable or unsafe");
    }
    if (![self validateTrustedOperationDirectory:operationDirectory error:error]) {
        return NO;
    }

    char canonicalDependencyRoot[PATH_MAX] = {0};
    if (!realpath(dependencyRootPath.fileSystemRepresentation, canonicalDependencyRoot)) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"RootHide dependency root could not be canonicalized");
    }
    NSString *canonicalRoot = [NSString stringWithUTF8String:canonicalDependencyRoot];

    NSString *anchorPath = [operationDirectory stringByAppendingPathComponent:@".jbroot"];
    struct stat anchorInfo;
    if (lstat(anchorPath.fileSystemRepresentation, &anchorInfo) == 0 || errno != ENOENT) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"RootHide dependency anchor path is already occupied or inaccessible");
    }
    NSError *linkError = nil;
    if (![self.fileManager createSymbolicLinkAtPath:anchorPath
                               withDestinationPath:canonicalRoot
                                             error:&linkError]) {
        if (error) {
            *error = linkError;
        }
        return NO;
    }

    return [self validateRootHideDependencyAnchorAtOperationDirectory:operationDirectory
                                                                error:error];
}

- (BOOL)validateRootHideDependencyAnchorAtOperationDirectory:(NSString *)operationDirectory
                                                       error:(NSError * _Nullable * _Nullable)error {
    NSString *dependencyRootPath = PXJBRootPath(@"/");
    struct stat dependencyRootInfo;
    if (lstat(dependencyRootPath.fileSystemRepresentation, &dependencyRootInfo) != 0 ||
        !S_ISDIR(dependencyRootInfo.st_mode) || S_ISLNK(dependencyRootInfo.st_mode)) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"RootHide dependency root is unavailable or unsafe");
    }
    if (![self validateTrustedOperationDirectory:operationDirectory error:error]) {
        return NO;
    }
    char canonicalDependencyRoot[PATH_MAX] = {0};
    if (!realpath(dependencyRootPath.fileSystemRepresentation, canonicalDependencyRoot)) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"RootHide dependency root could not be revalidated");
    }
    NSString *canonicalRoot = [NSString stringWithUTF8String:canonicalDependencyRoot];
    NSString *anchorPath = [operationDirectory stringByAppendingPathComponent:@".jbroot"];
    struct stat anchorLinkInfo;
    struct stat anchorTargetInfo;
    struct stat canonicalRootInfo;
    if (lstat(anchorPath.fileSystemRepresentation, &anchorLinkInfo) != 0 ||
        !S_ISLNK(anchorLinkInfo.st_mode) ||
        stat(anchorPath.fileSystemRepresentation, &anchorTargetInfo) != 0 ||
        stat(canonicalRoot.fileSystemRepresentation, &canonicalRootInfo) != 0 ||
        anchorTargetInfo.st_dev != canonicalRootInfo.st_dev ||
        anchorTargetInfo.st_ino != canonicalRootInfo.st_ino) {
        return PXKeychainOneShotExecutionFail(
            error,
            PXKeychainOneShotExecutionErrorUnsafeArtifacts,
            @"RootHide dependency anchor does not resolve to the active bootstrap");
    }
    return YES;
}

- (BOOL)writePropertyList:(NSDictionary<NSString *, id> *)propertyList
                    toPath:(NSString *)path
                     error:(NSError * _Nullable * _Nullable)error {
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:propertyList
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&serializationError];
    if (!data) {
        if (error) *error = serializationError;
        return NO;
    }
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = writeError;
        return NO;
    }
    if (chmod(path.fileSystemRepresentation, 0600) != 0) {
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorUnsafeArtifacts,
                                              @"One-shot operation file permissions could not be restricted");
    }
    return YES;
}

- (PXKeychainCommandResponse *)executeRequest:(PXKeychainCommandRequest *)request
                           workerEntitlements:(NSDictionary<NSString *, id> *)workerEntitlements
                                        error:(NSError * _Nullable * _Nullable)error {
    __block PXKeychainCommandResponse *response = nil;
    __block NSError *executionError = nil;
    dispatch_sync(self.executionQueue, ^{
        response = [self executePreparedRequest:request
                             workerEntitlements:workerEntitlements
                                          error:&executionError];
    });
    if (!response && error) {
        *error = executionError;
    }
    return response;
}

- (PXKeychainCommandResponse *)executePreparedRequest:(PXKeychainCommandRequest *)request
                                    workerEntitlements:(NSDictionary<NSString *, id> *)workerEntitlements
                                                 error:(NSError * _Nullable * _Nullable)error {
    NSError *preflightError = nil;
    if (![self validateWorkerEntitlements:workerEntitlements request:request error:&preflightError]) {
        if (error) {
            *error = PXKeychainOneShotErrorWithContext(preflightError,
                                                       @"authority-validation",
                                                       request.requestID);
        }
        return nil;
    }
    if (![self prepareOperationsRootWithError:&preflightError]) {
        if (error) {
            *error = PXKeychainOneShotErrorWithContext(preflightError,
                                                       @"operation-root",
                                                       request.requestID);
        }
        return nil;
    }
    struct stat templateInfo;
    if (lstat(self.workerTemplatePath.fileSystemRepresentation, &templateInfo) != 0 ||
        !S_ISREG(templateInfo.st_mode) || S_ISLNK(templateInfo.st_mode)) {
        NSError *templateError = nil;
        PXKeychainOneShotExecutionFail(&templateError,
                                       PXKeychainOneShotExecutionErrorUnsafeArtifacts,
                                       @"One-shot worker template is unavailable or unsafe");
        if (error) {
            *error = PXKeychainOneShotErrorWithContext(templateError,
                                                       @"worker-template",
                                                       request.requestID);
        }
        return nil;
    }

    NSString *operationDirectory = [self.operationsRootDirectory
        stringByAppendingPathComponent:request.requestID.lowercaseString];
    if (mkdir(operationDirectory.fileSystemRepresentation, 0700) != 0) {
        PXKeychainOneShotExecutionFail(error,
                                       PXKeychainOneShotExecutionErrorUnsafeArtifacts,
                                       @"One-shot operation directory could not be created exclusively");
        return nil;
    }

    NSString *workerPath = [operationDirectory stringByAppendingPathComponent:@"worker"];
    NSString *entitlementsPath = [operationDirectory stringByAppendingPathComponent:@"entitlements.plist"];
    NSString *requestPath = [operationDirectory stringByAppendingPathComponent:@"request.plist"];
    NSString *responsePath = [operationDirectory stringByAppendingPathComponent:@"response.plist"];
    PXKeychainCommandResponse *response = nil;
    NSError *operationError = nil;
    NSString *failureStage = @"dependency-anchor";
    BOOL copied = [self prepareRootHideDependencyAnchorAtOperationDirectory:operationDirectory
                                                                      error:&operationError];
    if (copied) {
        failureStage = @"artifact-preparation";
        copied = [self.fileManager copyItemAtPath:self.workerTemplatePath
                                           toPath:workerPath
                                            error:&operationError];
    }
    if (copied && chmod(workerPath.fileSystemRepresentation, 0700) == 0 &&
        [self writePropertyList:workerEntitlements toPath:entitlementsPath error:&operationError] &&
        [self writePropertyList:[request propertyListRepresentation]
                         toPath:requestPath
                           error:&operationError]) {
        failureStage = @"worker-signing";
        NSString *entitlementsArgument = [@"-S" stringByAppendingString:entitlementsPath];
        copied = [self.processRunner runExecutable:self.ldidPath
                                         arguments:@[@"-Cadhoc", entitlementsArgument, workerPath]
                                           timeout:self.workerTimeout
                                    standardOutput:nil
                                             error:&operationError];
    } else {
        copied = NO;
        if (!operationError) {
            operationError = [NSError errorWithDomain:PXKeychainOneShotErrorDomain
                                                 code:PXKeychainOneShotExecutionErrorUnsafeArtifacts
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"One-shot worker artifacts could not be prepared"}];
        }
    }

    NSData *signedEntitlementData = nil;
    NSDictionary<NSString *, id> *actualWorkerEntitlements = nil;
    if (copied) {
        failureStage = @"signature-verification";
    }
    if (copied && [self.processRunner runExecutable:self.ldidPath
                                          arguments:@[@"-e", workerPath]
                                            timeout:self.workerTimeout
                                     standardOutput:&signedEntitlementData
                                              error:&operationError]) {
        actualWorkerEntitlements = [self propertyListDictionaryFromData:signedEntitlementData
                                                                   error:&operationError];
        if (![actualWorkerEntitlements isEqualToDictionary:workerEntitlements]) {
            actualWorkerEntitlements = nil;
            PXKeychainOneShotExecutionFail(&operationError,
                                           PXKeychainOneShotExecutionErrorInvalidSignature,
                                           @"One-shot worker signature does not match the requested exact authority");
        }
    }
    if (actualWorkerEntitlements) {
        failureStage = @"dependency-anchor-validation";
        if (![self validateRootHideDependencyAnchorAtOperationDirectory:operationDirectory
                                                                  error:&operationError]) {
            actualWorkerEntitlements = nil;
        }
    }
    if (actualWorkerEntitlements) {
        failureStage = @"worker-execution";
    }
    if (actualWorkerEntitlements && [self.processRunner runExecutable:workerPath
                                                            arguments:@[requestPath, responsePath]
                                                              timeout:self.workerTimeout
                                                       standardOutput:nil
                                                                error:&operationError]) {
        failureStage = @"response-validation";
        struct stat responseInfo;
        if (lstat(responsePath.fileSystemRepresentation, &responseInfo) == 0 &&
            S_ISREG(responseInfo.st_mode) && !S_ISLNK(responseInfo.st_mode)) {
            NSDictionary<NSString *, id> *responsePropertyList =
                [NSDictionary dictionaryWithContentsOfFile:responsePath];
            response = [PXKeychainCommandResponse responseWithPropertyList:responsePropertyList
                                                                      error:&operationError];
            if (response && (![response.requestID isEqualToString:request.requestID] ||
                ![response.targetBundleID isEqualToString:request.targetBundleID])) {
                response = nil;
                PXKeychainOneShotExecutionFail(&operationError,
                                               PXKeychainOneShotExecutionErrorInvalidResponse,
                                               @"One-shot worker response does not match the request");
            }
        } else {
            PXKeychainOneShotExecutionFail(&operationError,
                                           PXKeychainOneShotExecutionErrorInvalidResponse,
                                           @"One-shot worker did not publish a safe response");
        }
    }

    NSError *cleanupError = nil;
    if (![self.fileManager removeItemAtPath:operationDirectory error:&cleanupError]) {
        response = nil;
        failureStage = @"artifact-cleanup";
        operationError = [NSError errorWithDomain:PXKeychainOneShotErrorDomain
                                             code:PXKeychainOneShotExecutionErrorUnsafeArtifacts
                                         userInfo:@{
                                             NSLocalizedDescriptionKey:
                                                 @"One-shot worker artifacts could not be removed",
                                             NSUnderlyingErrorKey: cleanupError
                                         }];
    }
    if (!response && error) {
        *error = PXKeychainOneShotErrorWithContext(operationError,
                                                   failureStage,
                                                   request.requestID);
    }
    return response;
}

@end
