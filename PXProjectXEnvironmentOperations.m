#import "PXProjectXEnvironmentOperations.h"

#import "AppDataCleaner.h"
#import "IdentifierManager.h"
#import "KeychainCommand.h"
#import "ProjectXLogging.h"
#import "PXRootHidePath.h"
#import "PXEnvironmentPolicy.h"

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
    if(![self allowsCleanupWithError:error])return NO;
    return [[AppDataCleaner sharedManager]
        terminateTargetBundleIdentifier:bundleIdentifier
        error:error];
}

- (void)clearKeychainForTargetBundleIdentifier:(NSString *)bundleIdentifier
                                     completion:(void (^)(BOOL, NSError *))completion {
    NSError *modeError=nil;if(![self allowsCleanupWithError:&modeError]){completion(NO,modeError);return;}
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
    NSError *modeError=nil;if(![self allowsCleanupWithError:&modeError]){completion(NO,modeError);return;}
    [[AppDataCleaner sharedManager] clearDataForBundleID:bundleIdentifier completion:completion];
}

- (BOOL)clearPasteboardWithError:(NSError **)error {
    (void)error;
    [[AppDataCleaner sharedManager] clearClipboard];
    return YES;
}

- (BOOL)clearSafariWithError:(NSError **)error {
    if(![self allowsCleanupWithError:error])return NO;
    if (![self.targetBundleIdentifiers containsObject:@"com.apple.mobilesafari"]) {
        return YES;
    }
    return [[AppDataCleaner sharedManager]
        clearWebDataForBundleID:@"com.apple.mobilesafari"
        error:error];
}

- (BOOL)generateAndActivateEnvironmentWithError:(NSError **)error {
    if(![self allowsCleanupWithError:error])return NO;
    return [[IdentifierManager sharedManager] regenerateAllEnabledIdentifiersWithError:error];
}
- (BOOL)allowsCleanupWithError:(NSError **)error {
    NSError *modeError=nil;
    PXApplicationEnvironmentMode mode=[[PXEnvironmentPolicyStore sharedStore] applicationEnvironmentModeWithError:&modeError];
    if(!modeError && mode==PXApplicationEnvironmentModeCleanup)return YES;
    if(error)*error=modeError?:[NSError errorWithDomain:PXEnvironmentPolicyErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey:@"Application cleanup is disabled in backup mode"}];
    return NO;
}

@end
