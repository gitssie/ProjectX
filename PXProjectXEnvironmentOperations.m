#import "PXProjectXEnvironmentOperations.h"

#import "AppDataCleaner.h"
#import "IdentifierManager.h"
#import "KeychainCommand.h"
#import "ProjectXLogging.h"
#import "PXRootHidePath.h"

@implementation PXProjectXEnvironmentOperations

+ (instancetype)sharedOperations {
    static PXProjectXEnvironmentOperations *operations = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        operations = [[self alloc] init];
    });
    return operations;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetBundleIdentifiers = [NSSet set];
    }
    return self;
}

- (BOOL)isServiceReady {
    NSString *identityDirectory = [[IdentifierManager sharedManager] profileIdentityPath];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    return identityDirectory.length > 0 &&
        [fileManager isExecutableFileAtPath:PXWeaponXDaemonPath()] &&
        [fileManager isExecutableFileAtPath:PXKeychainOneShotWorkerTemplatePath()] &&
        [fileManager isExecutableFileAtPath:PXBootstrapCommandPath(@"ldid")];
}

- (BOOL)terminateTargetBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    return [[AppDataCleaner sharedManager]
        terminateTargetBundleIdentifier:bundleIdentifier
        error:error];
}

- (void)clearKeychainForTargetBundleIdentifier:(NSString *)bundleIdentifier
                                     completion:(void (^)(BOOL, NSError *))completion {
    [[AppDataCleaner sharedManager]
        clearKeychainForBundleID:bundleIdentifier
        includeAppFamily:NO
        completion:^(BOOL success,
                     NSArray<PXKeychainCommandResponse *> *responses,
                     NSError *error) {
            NSUInteger protectedSharedAccessGroupCount = 0;
            for (PXKeychainCommandResponse *response in responses) {
                protectedSharedAccessGroupCount += response.protectedSharedAccessGroupCount;
            }
            if (success && protectedSharedAccessGroupCount > 0) {
                NSError *policyError = [NSError
                    errorWithDomain:PXKeychainCommandErrorDomain
                    code:15
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"Keychain cleanup left %lu signed target access group(s) protected",
                        (unsigned long)protectedSharedAccessGroupCount]}];
                PXLog(@"[keychain-policy] target=%@ cleanup incomplete; protectedSharedAccessGroupCount=%lu",
                      bundleIdentifier,
                      (unsigned long)protectedSharedAccessGroupCount);
                completion(NO, policyError);
                return;
            }
            completion(success, error);
        }];
}

- (void)clearTargetBundleIdentifier:(NSString *)bundleIdentifier
                         completion:(void (^)(BOOL, NSError *))completion {
    [[AppDataCleaner sharedManager] clearDataForBundleID:bundleIdentifier completion:completion];
}

- (BOOL)clearPasteboardWithError:(NSError **)error {
    (void)error;
    [[AppDataCleaner sharedManager] clearClipboard];
    return YES;
}

- (BOOL)clearSafariWithError:(NSError **)error {
    if (![self.targetBundleIdentifiers containsObject:@"com.apple.mobilesafari"]) {
        return YES;
    }
    return [[AppDataCleaner sharedManager]
        clearWebDataForBundleID:@"com.apple.mobilesafari"
        error:error];
}

- (BOOL)generateAndActivateEnvironmentWithError:(NSError **)error {
    return [[IdentifierManager sharedManager] regenerateAllEnabledIdentifiersWithError:error];
}

@end
