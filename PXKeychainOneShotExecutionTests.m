#import <Foundation/Foundation.h>

#include <assert.h>
#include <sys/stat.h>

#import "KeychainCommand.h"
#import "PXKeychainOneShotExecution.h"
#import "PXRootHidePath.h"

@interface PXKeychainOneShotExecution (PXTesting)
- (BOOL)validateTrustedOperationDirectory:(NSString *)operationDirectory
                                     error:(NSError **)error;
@end

static NSString *PXTestRootHideRoot;
static NSString *PXTestRootHideSecondaryRoot;

static NSString *PXTestJBRootPath(NSString *logicalPath) {
    if ([logicalPath isEqualToString:@"/"]) {
        return PXTestRootHideRoot;
    }
    if (PXTestRootHideSecondaryRoot.length > 0 &&
        ([logicalPath isEqualToString:@"/var"] || [logicalPath hasPrefix:@"/var/"])) {
        return [PXTestRootHideSecondaryRoot stringByAppendingString:logicalPath];
    }
    return [PXTestRootHideRoot stringByAppendingString:logicalPath];
}

static NSString *PXTestRootFSPath(NSString *logicalPath) {
    return logicalPath;
}

static NSString *PXTestStagedWorkerPath(void) {
    const char *path = getenv("PROJECTX_STAGED_KEYCHAIN_WORKER");
    assert(path != NULL);
    NSString *workerPath = [NSString stringWithUTF8String:path];
    assert(workerPath.isAbsolutePath);
    assert([[NSFileManager defaultManager] isExecutableFileAtPath:workerPath]);
    return workerPath;
}

@interface PXTestKeychainTargetResolver : NSObject <PXKeychainOneShotTargetResolving>
@property (nonatomic, copy) NSString *targetExecutablePath;
@end

@implementation PXTestKeychainTargetResolver

- (NSString *)executablePathForBundleIdentifier:(NSString *)bundleIdentifier
                                           error:(NSError **)error {
    (void)error;
    assert([bundleIdentifier isEqualToString:@"com.example.target"]);
    return self.targetExecutablePath;
}

@end

@interface PXTestKeychainProcessRunner : NSObject <PXKeychainOneShotProcessRunning>
@property (nonatomic, copy) NSString *ldidPath;
@property (nonatomic, copy) NSString *targetExecutablePath;
@property (nonatomic, copy) NSDictionary<NSString *, id> *targetEntitlements;
@property (nonatomic, copy) NSDictionary<NSString *, id> *workerEntitlements;
@property (nonatomic, copy) NSArray<NSString *> *expectedWorkerAccessGroups;
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, assign) BOOL failSigning;
@property (nonatomic, assign) BOOL duplicateEntitlementSlices;
@property (nonatomic, copy) NSDictionary<NSString *, id> *secondSliceEntitlements;
@property (nonatomic, copy) NSString *rootHideDependencyRootPath;
@property (nonatomic, assign) NSTimeInterval workerExecutionDelay;
@property (nonatomic, assign) NSUInteger activeWorkerExecutionCount;
@property (nonatomic, assign) NSUInteger maximumWorkerExecutionCount;
@property (nonatomic, assign) BOOL substituteRootHideDependencyAnchor;
@property (nonatomic, copy) NSString *substituteRootHideDependencyPath;
@end

@implementation PXTestKeychainProcessRunner

- (void)assertRootHideDependencyAnchorForWorkerPath:(NSString *)workerPath {
    NSString *anchorPath = [workerPath.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@".jbroot"];
    struct stat anchorLinkInfo;
    struct stat anchorTargetInfo;
    struct stat dependencyRootInfo;
    assert(lstat(anchorPath.fileSystemRepresentation, &anchorLinkInfo) == 0);
    assert(S_ISLNK(anchorLinkInfo.st_mode));
    assert(stat(anchorPath.fileSystemRepresentation, &anchorTargetInfo) == 0);
    assert(stat(self.rootHideDependencyRootPath.fileSystemRepresentation,
                &dependencyRootInfo) == 0);
    assert(anchorTargetInfo.st_dev == dependencyRootInfo.st_dev);
    assert(anchorTargetInfo.st_ino == dependencyRootInfo.st_ino);
}

- (NSData *)propertyListData:(NSDictionary<NSString *, id> *)propertyList {
    NSData *slice = [NSPropertyListSerialization dataWithPropertyList:propertyList
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:nil];
    if (!self.duplicateEntitlementSlices) {
        return slice;
    }
    NSMutableData *combined = [slice mutableCopy];
    NSData *secondSlice = self.secondSliceEntitlements
        ? [NSPropertyListSerialization dataWithPropertyList:self.secondSliceEntitlements
                                                     format:NSPropertyListXMLFormat_v1_0
                                                    options:0
                                                      error:nil]
        : slice;
    [combined appendData:secondSlice];
    return [combined copy];
}

- (BOOL)runExecutable:(NSString *)executablePath
             arguments:(NSArray<NSString *> *)arguments
               timeout:(NSTimeInterval)timeout
        standardOutput:(NSData **)standardOutput
                 error:(NSError **)error {
    assert(timeout > 0);
    if ([executablePath isEqualToString:self.ldidPath] &&
        arguments.count == 2 && [arguments.firstObject isEqualToString:@"-e"]) {
        if ([arguments.lastObject isEqualToString:self.targetExecutablePath]) {
            [self.events addObject:@"read-target-entitlements"];
            if (standardOutput) {
                *standardOutput = [self propertyListData:self.targetEntitlements];
            }
            return YES;
        }
        [self.events addObject:@"verify-worker-entitlements"];
        if (standardOutput) {
            *standardOutput = [self propertyListData:self.workerEntitlements];
        }
        if (self.substituteRootHideDependencyAnchor) {
            NSString *anchorPath = [arguments.lastObject.stringByDeletingLastPathComponent
                stringByAppendingPathComponent:@".jbroot"];
            assert([[NSFileManager defaultManager] removeItemAtPath:anchorPath error:nil]);
            assert([[NSFileManager defaultManager]
                createSymbolicLinkAtPath:anchorPath
                withDestinationPath:self.substituteRootHideDependencyPath
                error:nil]);
        }
        return YES;
    }
    if ([executablePath isEqualToString:self.ldidPath] && arguments.count == 3) {
        [self.events addObject:@"sign-worker"];
        [self assertRootHideDependencyAnchorForWorkerPath:arguments.lastObject];
        NSString *entitlementsArgument = arguments[1];
        assert([arguments.firstObject isEqualToString:@"-Cadhoc"]);
        assert([entitlementsArgument hasPrefix:@"-S"]);
        self.workerEntitlements = [NSDictionary dictionaryWithContentsOfFile:
            [entitlementsArgument substringFromIndex:2]];
        NSArray<NSString *> *expectedAccessGroups = self.expectedWorkerAccessGroups
            ?: @[@"TEAM123.com.example.target"];
        assert([self.workerEntitlements[@"keychain-access-groups"] isEqualToArray:
            expectedAccessGroups]);
        if (self.failSigning) {
            if (error) {
                *error = [NSError errorWithDomain:@"PXTest" code:1 userInfo:nil];
            }
            return NO;
        }
        return YES;
    }

    [self.events addObject:@"execute-worker"];
    assert(arguments.count == 2);
    @synchronized (self) {
        self.activeWorkerExecutionCount++;
        self.maximumWorkerExecutionCount = MAX(self.maximumWorkerExecutionCount,
                                                self.activeWorkerExecutionCount);
    }
    if (self.workerExecutionDelay > 0) {
        [NSThread sleepForTimeInterval:self.workerExecutionDelay];
    }
    NSDictionary<NSString *, id> *requestPropertyList =
        [NSDictionary dictionaryWithContentsOfFile:arguments[0]];
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:requestPropertyList
        error:nil];
    assert(request != nil);
    assert(!request.includesSynchronizableItems);
    NSString *applicationIdentifier = self.workerEntitlements[@"application-identifier"];
    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (NSString *accessGroup in self.workerEntitlements[@"keychain-access-groups"]) {
        for (NSString *keychainClass in @[
            PXKeychainClassGenericPassword,
            PXKeychainClassInternetPassword,
            PXKeychainClassCertificate,
            PXKeychainClassKey,
            PXKeychainClassIdentity
        ]) {
            [results addObject:@{
                @"class": keychainClass,
                @"accessGroup": accessGroup,
                @"beforeCount": @1,
                @"deletedCount": @1,
                @"remainingCount": @0,
                @"queryStatus": @(PXKeychainStatusSuccess),
                @"deleteStatus": @(PXKeychainStatusSuccess),
                @"verificationStatus": @(PXKeychainStatusItemNotFound),
                @"skippedSynchronizable": @YES,
                @"sharedAccessGroup": @(![accessGroup isEqualToString:applicationIdentifier]),
                @"success": @YES
            }];
        }
    }
    NSDictionary<NSString *, id> *response = @{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": request.requestID,
        @"targetBundleID": request.targetBundleID,
        @"success": @YES,
        @"results": results,
        @"failureCode": @""
    };
    assert([response writeToFile:arguments[1] atomically:YES]);
    @synchronized (self) {
        assert(self.activeWorkerExecutionCount > 0);
        self.activeWorkerExecutionCount--;
    }
    return YES;
}

@end

static PXKeychainCommandRequest *PXTestFreshOneShotRequestIncludingSharedGroups(
    BOOL includeSharedAccessGroups
) {
    NSDate *now = [NSDate date];
    return [PXKeychainCommandRequest
        freshRequestForBundleIdentifier:@"com.example.target"
        profileID:NSUUID.UUID.UUIDString
        generationID:NSUUID.UUID.UUIDString
        includeSharedAccessGroups:includeSharedAccessGroups
        includeSynchronizableItems:NO
        now:now
        ttl:30
        error:nil];
}

static PXKeychainCommandRequest *PXTestFreshOneShotRequest(void) {
    return PXTestFreshOneShotRequestIncludingSharedGroups(NO);
}

static PXKeychainCommandContext *PXTestContextForRequest(PXKeychainCommandRequest *request) {
    return [[PXKeychainCommandContext alloc]
        initWithBundleIdentifier:request.targetBundleID
        profileID:request.profileID
        generationID:request.generationID
        applicationEnabled:YES
        extensionEnabled:NO];
}

static void PXTestProductionExecutionSignsRunsAndCleansSignedTargetGroups(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *operationsRoot = [root stringByAppendingPathComponent:@"operations"];
    NSString *templatePath = PXTestStagedWorkerPath();
    PXTestRootHideRoot = root;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:root
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);
    NSString *staleOperation = [operationsRoot stringByAppendingPathComponent:
        @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:staleOperation
                                     withIntermediateDirectories:YES
                                                      attributes:@{NSFilePosixPermissions: @0700}
                                                           error:nil]);
    assert([[@"stale-worker" dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:[staleOperation stringByAppendingPathComponent:@"worker"] atomically:YES]);

    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.rootHideDependencyRootPath = root;
    runner.targetEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[
            @"TEAM123.com.example.target",
            @"TEAM123.group.shared"
        ]
    };
    runner.expectedWorkerAccessGroups = @[
        @"TEAM123.com.example.target",
        @"TEAM123.group.shared"
    ];
    runner.events = [NSMutableArray array];
    runner.duplicateEntitlementSlices = YES;
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:templatePath
        ldidPath:runner.ldidPath
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    PXKeychainCommandRequest *request =
        PXTestFreshOneShotRequestIncludingSharedGroups(YES);
    NSError *executionWarning = nil;
    PXKeychainCommandResponse *response = [[[PXKeychainOneShotController alloc]
        initWithExecution:execution]
        executeRequest:request
        context:PXTestContextForRequest(request)
        now:[NSDate date]
        error:&executionWarning];
    assert(response.isSuccessful);
    assert(executionWarning == nil);
    assert(response.protectedSharedAccessGroupCount == 0);
    assert([response.propertyListRepresentation[@"protectedSharedAccessGroupCount"]
        unsignedIntegerValue] == 0);
    NSArray<NSString *> *expectedEvents = @[
        @"read-target-entitlements",
        @"sign-worker",
        @"verify-worker-entitlements",
        @"execute-worker"
    ];
    assert([runner.events isEqualToArray:expectedEvents]);
    NSArray<NSString *> *remainingArtifacts = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:operationsRoot
        error:nil] ?: @[];
    assert(remainingArtifacts.count == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:root error:nil]);
}

static void PXTestProductionExecutionProtectsSharedGroupsForExclusiveCleanup(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-exclusive-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *operationsRoot = [root stringByAppendingPathComponent:@"operations"];
    PXTestRootHideRoot = root;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:root
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);

    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.rootHideDependencyRootPath = root;
    runner.targetEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[
            @"TEAM123.com.example.target",
            @"TEAM123.group.shared"
        ]
    };
    runner.expectedWorkerAccessGroups = @[@"TEAM123.com.example.target"];
    runner.events = [NSMutableArray array];
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:PXTestStagedWorkerPath()
        ldidPath:runner.ldidPath
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    PXKeychainCommandRequest *request = PXTestFreshOneShotRequest();
    NSError *error = nil;
    PXKeychainCommandResponse *response = [[[PXKeychainOneShotController alloc]
        initWithExecution:execution]
        executeRequest:request
        context:PXTestContextForRequest(request)
        now:[NSDate date]
        error:&error];
    assert(response.isSuccessful);
    assert(error == nil);
    assert(response.protectedSharedAccessGroupCount == 1);
    assert([response.propertyListRepresentation[@"protectedSharedAccessGroupCount"]
        unsignedIntegerValue] == 1);
    NSArray<NSString *> *expectedEvents = @[
        @"read-target-entitlements",
        @"sign-worker",
        @"verify-worker-entitlements",
        @"execute-worker"
    ];
    assert([runner.events isEqualToArray:expectedEvents]);
    NSArray<NSString *> *remainingArtifacts = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:operationsRoot
        error:nil] ?: @[];
    assert(remainingArtifacts.count == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:root error:nil]);
}

static void PXTestProductionExecutionCleansArtifactsAfterSigningFailure(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-failure-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *operationsRoot = [root stringByAppendingPathComponent:@"operations"];
    NSString *templatePath = [root stringByAppendingPathComponent:@"worker-template"];
    PXTestRootHideRoot = root;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:root
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);
    assert([[@"template" dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:templatePath atomically:YES]);
    assert(chmod(templatePath.fileSystemRepresentation, 0700) == 0);

    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.rootHideDependencyRootPath = root;
    runner.targetEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[@"TEAM123.com.example.target"]
    };
    runner.events = [NSMutableArray array];
    runner.failSigning = YES;
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:templatePath
        ldidPath:runner.ldidPath
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    PXKeychainCommandRequest *request = PXTestFreshOneShotRequest();
    NSError *error = nil;
    assert([[[PXKeychainOneShotController alloc] initWithExecution:execution]
        executeRequest:request
        context:PXTestContextForRequest(request)
        now:[NSDate date]
        error:&error] == nil);
    assert(error != nil);
    assert([error.userInfo[@"stage"] isEqualToString:@"worker-signing"]);
    assert([error.userInfo[@"reference"] isEqualToString:request.requestID.lowercaseString]);
    assert([error.localizedDescription containsString:@"domain=PXTest code=1"]);
    assert([error.localizedDescription containsString:request.requestID.lowercaseString]);
    NSArray<NSString *> *remainingArtifacts = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:operationsRoot
        error:nil] ?: @[];
    assert(remainingArtifacts.count == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:root error:nil]);
}

static void PXTestProductionExecutionReportsMissingWorkerTemplate(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-missing-worker-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *operationsRoot = [root stringByAppendingPathComponent:@"operations"];
    NSString *missingTemplatePath = [root stringByAppendingPathComponent:@"missing-worker-template"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:root
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);

    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.targetEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[@"TEAM123.com.example.target"]
    };
    runner.events = [NSMutableArray array];
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:missingTemplatePath
        ldidPath:runner.ldidPath
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    PXKeychainCommandRequest *request = PXTestFreshOneShotRequest();
    NSError *error = nil;
    assert([[[PXKeychainOneShotController alloc] initWithExecution:execution]
        executeRequest:request
        context:PXTestContextForRequest(request)
        now:[NSDate date]
        error:&error] == nil);
    assert([error.domain isEqualToString:PXKeychainOneShotErrorDomain]);
    assert([error.localizedDescription containsString:@"worker template"]);
    assert([runner.events isEqualToArray:@[@"read-target-entitlements"]]);
    NSArray<NSString *> *remainingArtifacts = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:operationsRoot
        error:nil] ?: @[];
    assert(remainingArtifacts.count == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:root error:nil]);
}

static void PXTestProcessRunnerEnforcesTimeout(void) {
    NSDate *start = [NSDate date];
    NSError *error = nil;
    assert(![[[PXKeychainOneShotProcessRunner alloc] init]
        runExecutable:@"/bin/sleep"
        arguments:@[@"2"]
        timeout:0.05
        standardOutput:nil
        error:&error]);
    assert(error != nil);
    assert([[NSDate date] timeIntervalSinceDate:start] < 1);
}

static void PXTestProcessRunnerBoundsDyldFailureDiagnostics(void) {
    NSMutableString *failureText = [NSMutableString stringWithString:@"dyld: Library not loaded: "];
    while (failureText.length < 4096) {
        [failureText appendString:@"missing-root-hide-anchor "];
    }
    NSString *command = [NSString stringWithFormat:@"printf '%%s' '%@' >&2; exit 1",
        failureText];
    NSError *error = nil;
    BOOL succeeded = [[[PXKeychainOneShotProcessRunner alloc] init]
        runExecutable:@"/bin/sh"
        arguments:@[@"-c", command]
        timeout:2
        standardOutput:nil
        error:&error];
    assert(!succeeded);
    assert([error.domain isEqualToString:PXKeychainOneShotErrorDomain]);
    assert(error.localizedDescription.length < 1024);
    assert([error.localizedDescription containsString:@"dyld: Library not loaded"]);
}

static void PXTestConcurrentRequestsRemainSerializedAndCleanTheirAnchors(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-concurrency-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *operationsRoot = [root stringByAppendingPathComponent:@"operations"];
    NSString *templatePath = PXTestStagedWorkerPath();
    PXTestRootHideRoot = root;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:root
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);

    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.rootHideDependencyRootPath = root;
    runner.events = [NSMutableArray array];
    runner.workerExecutionDelay = 0.05;
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:templatePath
        ldidPath:runner.ldidPath
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    NSDictionary<NSString *, id> *workerEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"com.apple.application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[@"TEAM123.com.example.target"],
        @"platform-application": @YES,
        @"com.apple.private.security.container-required": @NO,
        @"com.apple.private.security.no-container": @YES,
        @"com.apple.private.security.no-sandbox": @YES
    };
    dispatch_group_t group = dispatch_group_create();
    __block NSUInteger successCount = 0;
    for (NSUInteger index = 0; index < 2; index++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            PXKeychainCommandRequest *request = PXTestFreshOneShotRequest();
            PXKeychainCommandResponse *response = [execution executeRequest:request
                                                         workerEntitlements:workerEntitlements
                                                                      error:nil];
            if (response.isSuccessful) {
                @synchronized (execution) {
                    successCount++;
                }
            }
        });
    }
    assert(dispatch_group_wait(group,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))) == 0);
    assert(successCount == 2);
    assert(runner.maximumWorkerExecutionCount == 1);
    NSArray<NSString *> *remainingArtifacts = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:operationsRoot
        error:nil] ?: @[];
    assert(remainingArtifacts.count == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:root error:nil]);
}

static void PXTestProductionExecutionRejectsSubstitutedRootHideDependencyAnchor(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-anchor-substitution-tests-"
            stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *operationsRoot = [root stringByAppendingPathComponent:@"operations"];
    NSString *templatePath = [root stringByAppendingPathComponent:@"worker-template"];
    NSString *substituteRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-substitute-root-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    PXTestRootHideRoot = root;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:root
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);
    assert([[NSFileManager defaultManager] createDirectoryAtPath:substituteRoot
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);
    assert([[@"template" dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:templatePath atomically:YES]);
    assert(chmod(templatePath.fileSystemRepresentation, 0700) == 0);

    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.rootHideDependencyRootPath = root;
    runner.targetEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[@"TEAM123.com.example.target"]
    };
    runner.events = [NSMutableArray array];
    runner.substituteRootHideDependencyAnchor = YES;
    runner.substituteRootHideDependencyPath = substituteRoot;
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:templatePath
        ldidPath:runner.ldidPath
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    PXKeychainCommandRequest *request = PXTestFreshOneShotRequest();
    NSError *error = nil;
    PXKeychainCommandResponse *response = [[[PXKeychainOneShotController alloc]
        initWithExecution:execution]
        executeRequest:request
        context:PXTestContextForRequest(request)
        now:[NSDate date]
        error:&error];
    assert(response == nil);
    assert([error.domain isEqualToString:PXKeychainOneShotErrorDomain]);
    assert([error.userInfo[@"stage"] isEqualToString:@"dependency-anchor-validation"]);
    NSArray<NSString *> *expectedEvents = @[
        @"read-target-entitlements",
        @"sign-worker",
        @"verify-worker-entitlements"
    ];
    assert([runner.events isEqualToArray:expectedEvents]);
    NSArray<NSString *> *remainingArtifacts = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:operationsRoot
        error:nil] ?: @[];
    assert(remainingArtifacts.count == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:root error:nil]);
    assert([[NSFileManager defaultManager] removeItemAtPath:substituteRoot error:nil]);
}

static void PXTestProductionExecutionSupportsRootHideSplitVarTopology(void) {
    NSString *fixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-split-topology-tests-"
            stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *primaryRoot = [fixtureRoot stringByAppendingPathComponent:@"primary"];
    NSString *secondaryRoot = [fixtureRoot stringByAppendingPathComponent:@"secondary"];
    PXTestRootHideRoot = primaryRoot;
    PXTestRootHideSecondaryRoot = secondaryRoot;
    NSString *operationsRoot = PXKeychainOneShotOperationsPath();
    assert(![operationsRoot hasPrefix:[primaryRoot stringByAppendingString:@"/"]]);
    assert([[NSFileManager defaultManager] createDirectoryAtPath:primaryRoot
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);
    assert([[NSFileManager defaultManager] createDirectoryAtPath:secondaryRoot
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil]);

    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.rootHideDependencyRootPath = primaryRoot;
    runner.targetEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[@"TEAM123.com.example.target"]
    };
    runner.events = [NSMutableArray array];
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:PXTestStagedWorkerPath()
        ldidPath:runner.ldidPath
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    PXKeychainCommandRequest *request = PXTestFreshOneShotRequest();
    NSError *error = nil;
    PXKeychainCommandResponse *response = [[[PXKeychainOneShotController alloc]
        initWithExecution:execution]
        executeRequest:request
        context:PXTestContextForRequest(request)
        now:[NSDate date]
        error:&error];
    assert(response.isSuccessful);
    assert(error == nil);
    NSArray<NSString *> *remainingArtifacts = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:operationsRoot
        error:nil] ?: @[];
    assert(remainingArtifacts.count == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:fixtureRoot error:nil]);
    PXTestRootHideSecondaryRoot = nil;
}

static void PXTestTrustedOperationDirectoryRejectsTraversalSiblingsAndSymlinks(void) {
    NSString *fixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"projectx-one-shot-operation-root-tests-"
            stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *operationsRoot = [fixtureRoot stringByAppendingPathComponent:@"operations"];
    NSString *outsideRoot = [fixtureRoot stringByAppendingPathComponent:@"outside"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:operationsRoot
                                     withIntermediateDirectories:YES
                                                      attributes:@{NSFilePosixPermissions: @0700}
                                                           error:nil]);
    assert([[NSFileManager defaultManager] createDirectoryAtPath:outsideRoot
                                     withIntermediateDirectories:YES
                                                      attributes:@{NSFilePosixPermissions: @0700}
                                                           error:nil]);
    assert(chmod(operationsRoot.fileSystemRepresentation, 0700) == 0);
    assert(chmod(outsideRoot.fileSystemRepresentation, 0700) == 0);

    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:[[PXTestKeychainProcessRunner alloc] init]
        targetResolver:[[PXTestKeychainTargetResolver alloc] init]
        workerTemplatePath:PXTestStagedWorkerPath()
        ldidPath:@"/bootstrap/usr/bin/ldid"
        operationsRootDirectory:operationsRoot
        workerTimeout:2];
    NSString *validLeaf = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *validOperation = [operationsRoot stringByAppendingPathComponent:validLeaf];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:validOperation
                                     withIntermediateDirectories:NO
                                                      attributes:@{NSFilePosixPermissions: @0700}
                                                           error:nil]);
    assert(chmod(validOperation.fileSystemRepresentation, 0700) == 0);
    assert([execution validateTrustedOperationDirectory:validOperation error:nil]);
    assert([[NSFileManager defaultManager] removeItemAtPath:validOperation error:nil]);

    NSString *nonUUIDOperation = [operationsRoot stringByAppendingPathComponent:@"not-a-uuid"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:nonUUIDOperation
                                     withIntermediateDirectories:NO
                                                      attributes:@{NSFilePosixPermissions: @0700}
                                                           error:nil]);
    assert(![execution validateTrustedOperationDirectory:nonUUIDOperation error:nil]);

    NSString *siblingRoot = [operationsRoot stringByAppendingString:@"-sibling"];
    NSString *siblingOperation = [siblingRoot stringByAppendingPathComponent:validLeaf];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:siblingOperation
                                     withIntermediateDirectories:YES
                                                      attributes:@{NSFilePosixPermissions: @0700}
                                                           error:nil]);
    assert(chmod(siblingRoot.fileSystemRepresentation, 0700) == 0);
    assert(chmod(siblingOperation.fileSystemRepresentation, 0700) == 0);
    assert(![execution validateTrustedOperationDirectory:siblingOperation error:nil]);

    NSString *traversalOperation = [operationsRoot stringByAppendingPathComponent:
        [@"intermediate/../" stringByAppendingString:validLeaf]];
    assert(![execution validateTrustedOperationDirectory:traversalOperation error:nil]);

    NSString *symlinkLeaf = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *symlinkOperation = [operationsRoot stringByAppendingPathComponent:symlinkLeaf];
    assert([[NSFileManager defaultManager] createSymbolicLinkAtPath:symlinkOperation
                                                withDestinationPath:outsideRoot
                                                              error:nil]);
    assert(![execution validateTrustedOperationDirectory:symlinkOperation error:nil]);
    assert([[NSFileManager defaultManager] removeItemAtPath:fixtureRoot error:nil]);
}

static void PXTestProductionExecutionRejectsMismatchedEntitlementSlices(void) {
    PXTestKeychainTargetResolver *resolver = [[PXTestKeychainTargetResolver alloc] init];
    resolver.targetExecutablePath = @"/target/application";
    PXTestKeychainProcessRunner *runner = [[PXTestKeychainProcessRunner alloc] init];
    runner.ldidPath = @"/bootstrap/usr/bin/ldid";
    runner.targetExecutablePath = resolver.targetExecutablePath;
    runner.targetEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[@"TEAM123.com.example.target"]
    };
    runner.duplicateEntitlementSlices = YES;
    runner.secondSliceEntitlements = @{
        @"application-identifier": @"OTHER99.com.example.target",
        @"keychain-access-groups": @[@"OTHER99.com.example.target"]
    };
    runner.events = [NSMutableArray array];
    PXKeychainOneShotExecution *execution = [[PXKeychainOneShotExecution alloc]
        initWithFileManager:[NSFileManager defaultManager]
        processRunner:runner
        targetResolver:resolver
        workerTemplatePath:@"/worker-template"
        ldidPath:runner.ldidPath
        operationsRootDirectory:@"/operations"
        workerTimeout:2];
    NSError *error = nil;
    assert([execution signedEntitlementsForTargetBundleIdentifier:@"com.example.target"
                                                            error:&error] == nil);
    assert(error != nil);
}

int main(void) {
    @autoreleasepool {
        PXSetRootHidePathConvertersForTesting(PXTestJBRootPath, PXTestRootFSPath);
        PXTestProductionExecutionSignsRunsAndCleansSignedTargetGroups();
        PXTestProductionExecutionProtectsSharedGroupsForExclusiveCleanup();
        PXTestProductionExecutionCleansArtifactsAfterSigningFailure();
        PXTestProductionExecutionReportsMissingWorkerTemplate();
        PXTestProcessRunnerEnforcesTimeout();
        PXTestProcessRunnerBoundsDyldFailureDiagnostics();
        PXTestConcurrentRequestsRemainSerializedAndCleanTheirAnchors();
        PXTestProductionExecutionRejectsSubstitutedRootHideDependencyAnchor();
        PXTestProductionExecutionSupportsRootHideSplitVarTopology();
        PXTestTrustedOperationDirectoryRejectsTraversalSiblingsAndSymlinks();
        PXTestProductionExecutionRejectsMismatchedEntitlementSlices();
    }
    return 0;
}
