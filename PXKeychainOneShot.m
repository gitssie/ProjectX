#import "PXKeychainOneShot.h"

NSString *const PXKeychainOneShotErrorDomain = @"com.hydra.projectx.keychain-one-shot";

typedef NS_ENUM(NSInteger, PXKeychainOneShotErrorCode) {
    PXKeychainOneShotErrorInvalidEntitlements = 1,
    PXKeychainOneShotErrorUnsafeRequest = 2,
    PXKeychainOneShotErrorInvalidWorkerResponse = 3
};

static BOOL PXKeychainOneShotFail(NSError * _Nullable * _Nullable error,
                                  PXKeychainOneShotErrorCode code,
                                  NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:PXKeychainOneShotErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

static BOOL PXKeychainOneShotGroupIsSafeForTeam(NSString *accessGroup,
                                                 NSString *teamPrefix) {
    if (accessGroup.length <= teamPrefix.length + 1 ||
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

static BOOL PXKeychainOneShotResponseMatchesPlan(PXKeychainCommandResponse *response,
                                                 PXKeychainCommandRequest *request,
                                                 PXKeychainOneShotEntitlementPlan *plan,
                                                 NSError * _Nullable * _Nullable error) {
    if (![response.requestID isEqualToString:request.requestID] ||
        ![response.targetBundleID isEqualToString:request.targetBundleID] ||
        response.results.count != plan.deletionPlan.scopes.count ||
        response.protectedSharedAccessGroupCount != 0) {
        return PXKeychainOneShotFail(error,
                                     PXKeychainOneShotErrorInvalidWorkerResponse,
                                     @"One-shot worker returned an incomplete or mismatched response");
    }
    NSMutableDictionary<NSString *, PXKeychainDeletionScope *> *remainingScopes =
        [NSMutableDictionary dictionary];
    for (PXKeychainDeletionScope *scope in plan.deletionPlan.scopes) {
        NSString *scopeKey = [NSString stringWithFormat:@"%@\n%@",
            scope.accessGroup,
            scope.keychainClass];
        if (remainingScopes[scopeKey]) {
            return PXKeychainOneShotFail(error,
                                         PXKeychainOneShotErrorInvalidWorkerResponse,
                                         @"One-shot plan contains a duplicate Keychain scope");
        }
        remainingScopes[scopeKey] = scope;
    }
    for (PXKeychainScopeResult *result in response.results) {
        NSString *scopeKey = [NSString stringWithFormat:@"%@\n%@",
            result.accessGroup,
            result.keychainClass];
        PXKeychainDeletionScope *scope = remainingScopes[scopeKey];
        if (!scope || result.isSharedAccessGroup != scope.isSharedAccessGroup ||
            !result.skippedSynchronizable) {
            return PXKeychainOneShotFail(error,
                                         PXKeychainOneShotErrorInvalidWorkerResponse,
                                         @"One-shot worker returned a result outside the signed target groups");
        }
        [remainingScopes removeObjectForKey:scopeKey];
    }
    if (remainingScopes.count > 0) {
        return PXKeychainOneShotFail(error,
                                     PXKeychainOneShotErrorInvalidWorkerResponse,
                                     @"One-shot worker omitted an expected Keychain scope result");
    }
    return YES;
}

@interface PXKeychainOneShotEntitlementPlan ()

@property (nonatomic, copy, readwrite) NSString *applicationIdentifier;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *workerEntitlements;
@property (nonatomic, strong, readwrite) PXKeychainDeletionPlan *deletionPlan;
@property (nonatomic, assign, readwrite) NSUInteger skippedSharedAccessGroupCount;

@end

@interface PXKeychainOneShotController ()

@property (nonatomic, strong) id<PXKeychainOneShotExecuting> execution;
@property (nonatomic, strong) PXKeychainCommandValidator *validator;

@end


@implementation PXKeychainOneShotController

- (instancetype)initWithExecution:(id<PXKeychainOneShotExecuting>)execution {
    self = [super init];
    if (self) {
        _execution = execution;
        _validator = [[PXKeychainCommandValidator alloc] init];
    }
    return self;
}

- (PXKeychainOneShotResponse *)executeRequest:(PXKeychainCommandRequest *)request
                                      context:(PXKeychainCommandContext *)context
                                          now:(NSDate *)now
                                        error:(NSError * _Nullable * _Nullable)error {
    if (request.includesSynchronizableItems) {
        PXKeychainOneShotFail(error,
                              PXKeychainOneShotErrorUnsafeRequest,
                              @"Automatic Keychain cleanup cannot include synchronizable items");
        return nil;
    }
    if (![self.validator claimRequest:request context:context now:now error:error]) {
        return nil;
    }
    NSDictionary<NSString *, id> *signedEntitlements = [self.execution
        signedEntitlementsForTargetBundleIdentifier:request.targetBundleID
        error:error];
    if (!signedEntitlements) {
        return nil;
    }
    PXKeychainOneShotEntitlementPlan *plan = [PXKeychainOneShotEntitlementPlan
        planForBundleIdentifier:request.targetBundleID
        signedEntitlements:signedEntitlements
        includeSharedAccessGroups:request.includesSharedAccessGroups
        error:error];
    if (!plan) {
        return nil;
    }
    PXKeychainCommandResponse *response = [self.execution
        executeRequest:request
        workerEntitlements:plan.workerEntitlements
        error:error];
    if (!response || !PXKeychainOneShotResponseMatchesPlan(response, request, plan, error)) {
        return nil;
    }
    return [response responseByRecordingProtectedSharedAccessGroupCount:
        plan.skippedSharedAccessGroupCount];
}

@end

@implementation PXKeychainOneShotEntitlementPlan

+ (instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                      signedEntitlements:(NSDictionary<NSString *, id> *)signedEntitlements
                                   error:(NSError * _Nullable * _Nullable)error {
    return [self planForBundleIdentifier:bundleIdentifier
                      signedEntitlements:signedEntitlements
               includeSharedAccessGroups:NO
                                   error:error];
}

+ (instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                      signedEntitlements:(NSDictionary<NSString *, id> *)signedEntitlements
               includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
                                   error:(NSError * _Nullable * _Nullable)error {
    PXKeychainDeletionPlan *deletionPlan = [PXKeychainDeletionPlan
        planForBundleIdentifier:bundleIdentifier
        entitlements:signedEntitlements
        includeSharedAccessGroups:includeSharedAccessGroups
        includeSynchronizableItems:NO
        error:error];
    if (!deletionPlan) {
        return nil;
    }

    NSString *expectedSuffix = [@"." stringByAppendingString:bundleIdentifier];
    NSString *teamPrefix = [deletionPlan.applicationIdentifier substringToIndex:
        deletionPlan.applicationIdentifier.length - expectedSuffix.length];
    NSArray *accessGroups = [signedEntitlements[@"keychain-access-groups"] isKindOfClass:[NSArray class]]
        ? signedEntitlements[@"keychain-access-groups"]
        : @[];
    NSMutableOrderedSet<NSString *> *workerAccessGroups =
        [NSMutableOrderedSet orderedSetWithObject:deletionPlan.applicationIdentifier];
    NSMutableSet<NSString *> *seenSignedAccessGroups = [NSMutableSet set];
    NSUInteger skippedSharedAccessGroupCount = 0;
    for (id candidate in accessGroups) {
        if (![candidate isKindOfClass:[NSString class]] ||
            !PXKeychainOneShotGroupIsSafeForTeam(candidate, teamPrefix)) {
            PXKeychainOneShotFail(error,
                                  PXKeychainOneShotErrorInvalidEntitlements,
                                  @"Target Keychain entitlements contain an unsafe access group");
            return nil;
        }
        if ([seenSignedAccessGroups containsObject:candidate]) {
            PXKeychainOneShotFail(error,
                                  PXKeychainOneShotErrorInvalidEntitlements,
                                  @"Target Keychain entitlements contain a duplicate access group");
            return nil;
        }
        [seenSignedAccessGroups addObject:candidate];
        if (![(NSString *)candidate isEqualToString:deletionPlan.applicationIdentifier]) {
            if (includeSharedAccessGroups) {
                [workerAccessGroups addObject:(NSString *)candidate];
            } else {
                skippedSharedAccessGroupCount++;
            }
        }
    }

    PXKeychainOneShotEntitlementPlan *plan = [[self alloc] init];
    plan.applicationIdentifier = deletionPlan.applicationIdentifier;
    plan.deletionPlan = deletionPlan;
    plan.skippedSharedAccessGroupCount = skippedSharedAccessGroupCount;
    plan.workerEntitlements = @{
        @"application-identifier": deletionPlan.applicationIdentifier,
        @"com.apple.application-identifier": deletionPlan.applicationIdentifier,
        @"keychain-access-groups": workerAccessGroups.array,
        @"platform-application": @YES,
        @"com.apple.private.security.container-required": @NO,
        @"com.apple.private.security.no-container": @YES,
        @"com.apple.private.security.no-sandbox": @YES
    };
    return plan;
}

@end
