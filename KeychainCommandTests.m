#import <Foundation/Foundation.h>
#include <assert.h>

#import "KeychainCommand.h"
#import "PXKeychainOneShot.h"

static NSDictionary<NSString *, id> *freshRequestPropertyList(NSString *targetBundleID) {
    NSDate *createdAt = [NSDate dateWithTimeIntervalSince1970:1000];
    return @{
        @"schemaVersion": @1,
        @"requestID": @"11111111-1111-4111-8111-111111111111",
        @"targetBundleID": targetBundleID,
        @"profileID": @"22222222-2222-4222-8222-222222222222",
        @"generationID": @"33333333-3333-4333-8333-333333333333",
        @"operation": @"clear-keychain",
        @"createdAt": createdAt,
        @"expiresAt": [createdAt dateByAddingTimeInterval:30],
        @"synchronizablePolicy": @"exclude",
        @"includeSharedAccessGroups": @YES
    };
}

static PXKeychainCommandContext *context(NSString *bundleID,
                                         BOOL applicationEnabled,
                                         BOOL extensionEnabled) {
    return [[PXKeychainCommandContext alloc]
        initWithBundleIdentifier:bundleID
                       profileID:@"22222222-2222-4222-8222-222222222222"
                    generationID:@"33333333-3333-4333-8333-333333333333"
              applicationEnabled:applicationEnabled
                extensionEnabled:extensionEnabled];
}

static void testOnlyExactEnabledScopedBundleAcceptsFreshRequest(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    assert(request != nil);

    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1010];
    assert([[[PXKeychainCommandValidator alloc] init]
        claimRequest:request
             context:context(@"com.example.target", YES, NO)
                 now:now
               error:nil]);
    assert(![[[PXKeychainCommandValidator alloc] init]
        claimRequest:request
             context:context(@"com.example.other", YES, NO)
                 now:now
               error:nil]);
    assert(![[[PXKeychainCommandValidator alloc] init]
        claimRequest:request
             context:context(@"com.example.target", NO, NO)
                 now:now
               error:nil]);

    PXKeychainCommandRequest *projectXRequest = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.hydra.projectx")
        error:nil];
    assert(![[[PXKeychainCommandValidator alloc] init]
        claimRequest:projectXRequest
             context:context(@"com.hydra.projectx", YES, NO)
                 now:now
               error:nil]);

    PXKeychainCommandRequest *systemRequest = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.apple.Preferences")
        error:nil];
    assert(![[[PXKeychainCommandValidator alloc] init]
        claimRequest:systemRequest
             context:context(@"com.apple.Preferences", YES, NO)
                 now:now
               error:nil]);
}

static void testLegacyProfileIdentifierRemainsBoundAndPathSafe(void) {
    NSMutableDictionary<NSString *, id> *propertyList =
        [freshRequestPropertyList(@"com.example.target") mutableCopy];
    propertyList[@"profileID"] = @"0";
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:propertyList
        error:nil];
    assert(request != nil);
    PXKeychainCommandContext *legacyContext = [[PXKeychainCommandContext alloc]
        initWithBundleIdentifier:@"com.example.target"
                       profileID:@"0"
                    generationID:request.generationID
              applicationEnabled:YES
                extensionEnabled:NO];
    assert([[[PXKeychainCommandValidator alloc] init]
        claimRequest:request
             context:legacyContext
                 now:[NSDate dateWithTimeIntervalSince1970:1010]
               error:nil]);

    for (NSString *unsafeProfileID in @[@"", @".", @"..", @".hidden", @"../0", @"0/child", @"0\\child"]) {
        propertyList[@"profileID"] = unsafeProfileID;
        assert([PXKeychainCommandRequest requestWithPropertyList:propertyList error:nil] == nil);
    }
}

static void testReceiverRegistersBeforeSelectionButNeverInProtectedProcesses(void) {
    assert(PXKeychainCommandReceiverShouldRegisterForBundleIdentifier(@"com.example.target"));
    assert(!PXKeychainCommandReceiverShouldRegisterForBundleIdentifier(@"com.hydra.projectx"));
    assert(!PXKeychainCommandReceiverShouldRegisterForBundleIdentifier(@"com.apple.Preferences"));
    assert(!PXKeychainCommandReceiverShouldRegisterForBundleIdentifier(@""));
}

static void testExpiredReplayAndWrongProfileRequestsNeverExecute(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    PXKeychainCommandValidator *validator = [[PXKeychainCommandValidator alloc] init];
    PXKeychainCommandContext *validContext = context(@"com.example.target", YES, NO);
    assert(![validator claimRequest:request
                         context:validContext
                             now:[NSDate dateWithTimeIntervalSince1970:1031]
                           error:nil]);

    PXKeychainCommandContext *wrongProfile = [[PXKeychainCommandContext alloc]
        initWithBundleIdentifier:@"com.example.target"
                       profileID:@"44444444-4444-4444-8444-444444444444"
                    generationID:request.generationID
              applicationEnabled:YES
                extensionEnabled:NO];
    assert(![[[PXKeychainCommandValidator alloc] init]
        claimRequest:request
             context:wrongProfile
                 now:[NSDate dateWithTimeIntervalSince1970:1010]
               error:nil]);

    PXKeychainCommandContext *wrongGeneration = [[PXKeychainCommandContext alloc]
        initWithBundleIdentifier:@"com.example.target"
                       profileID:request.profileID
                    generationID:@"55555555-5555-4555-8555-555555555555"
              applicationEnabled:YES
                extensionEnabled:NO];
    assert(![[[PXKeychainCommandValidator alloc] init]
        claimRequest:request
             context:wrongGeneration
                 now:[NSDate dateWithTimeIntervalSince1970:1010]
               error:nil]);

    validator = [[PXKeychainCommandValidator alloc] init];
    assert([validator claimRequest:request
                          context:validContext
                              now:[NSDate dateWithTimeIntervalSince1970:1010]
                            error:nil]);
    assert(![validator claimRequest:request
                           context:validContext
                               now:[NSDate dateWithTimeIntervalSince1970:1010]
                             error:nil]);
}

static void testRequestCannotSupplyAccessGroupsOrQueries(void) {
    NSMutableDictionary<NSString *, id> *propertyList =
        [freshRequestPropertyList(@"com.example.target") mutableCopy];
    propertyList[@"accessGroups"] = @[@"TEAM123.unrelated"];
    assert([PXKeychainCommandRequest requestWithPropertyList:propertyList error:nil] == nil);
    [propertyList removeObjectForKey:@"accessGroups"];
    propertyList[@"query"] = @{@"service": @"secret"};
    assert([PXKeychainCommandRequest requestWithPropertyList:propertyList error:nil] == nil);
}

static void testDeletionPlanUsesOnlyApprovedClassesAndDerivedApplicationGroups(void) {
    NSDictionary<NSString *, id> *entitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[
            @"TEAM123.com.example.target",
            @"TEAM123.group.example.shared",
            @"OTHER99.group.unrelated",
            @"com.apple.system-group",
            @"$(AppIdentifierPrefix)unresolved"
        ]
    };
    PXKeychainDeletionPlan *plan = [PXKeychainDeletionPlan
        planForBundleIdentifier:@"com.example.target"
                   entitlements:entitlements
     includeSharedAccessGroups:YES
                          error:nil];
    assert(plan != nil);
    assert([plan.applicationIdentifier isEqualToString:@"TEAM123.com.example.target"]);
    assert([plan.sharedAccessGroups isEqualToSet:
        [NSSet setWithObject:@"TEAM123.group.example.shared"]]);
    assert(plan.scopes.count == 10);

    NSSet<NSString *> *allowedClasses = [NSSet setWithArray:@[
        PXKeychainClassGenericPassword,
        PXKeychainClassInternetPassword,
        PXKeychainClassCertificate,
        PXKeychainClassKey,
        PXKeychainClassIdentity
    ]];
    NSSet<NSString *> *allowedGroups = [NSSet setWithArray:@[
        @"TEAM123.com.example.target",
        @"TEAM123.group.example.shared"
    ]];
    for (PXKeychainDeletionScope *scope in plan.scopes) {
        assert([allowedClasses containsObject:scope.keychainClass]);
        assert([allowedGroups containsObject:scope.accessGroup]);
        assert(!scope.isSynchronizable);
        assert(scope.isSharedAccessGroup ==
            [scope.accessGroup isEqualToString:@"TEAM123.group.example.shared"]);
    }
}

static void testSharedEntitlementGroupsRequireExplicitFamilyPolicy(void) {
    NSDictionary<NSString *, id> *entitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[
            @"TEAM123.com.example.target",
            @"TEAM123.group.example.shared"
        ]
    };
    PXKeychainDeletionPlan *plan = [PXKeychainDeletionPlan
        planForBundleIdentifier:@"com.example.target"
                   entitlements:entitlements
     includeSharedAccessGroups:NO
                          error:nil];
    assert(plan.scopes.count == 5);
    assert(plan.sharedAccessGroups.count == 0);
    for (PXKeychainDeletionScope *scope in plan.scopes) {
        assert([scope.accessGroup isEqualToString:@"TEAM123.com.example.target"]);
    }
}

static void testMalformedEntitlementGroupsFailClosed(void) {
    NSDictionary<NSString *, id> *entitlements = @{
        @"application-identifier": @"wrong.application.identifier",
        @"keychain-access-groups": @[@42]
    };
    assert([PXKeychainDeletionPlan
        planForBundleIdentifier:@"com.example.target"
                   entitlements:entitlements
     includeSharedAccessGroups:YES
                           error:nil] == nil);
}

static void testOneShotEntitlementPlanBindsOnlyTheExactApplicationGroup(void) {
    NSDictionary<NSString *, id> *entitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[
            @"TEAM123.com.example.target",
            @"TEAM123.group.example.shared"
        ]
    };
    PXKeychainOneShotEntitlementPlan *plan = [PXKeychainOneShotEntitlementPlan
        planForBundleIdentifier:@"com.example.target"
        signedEntitlements:entitlements
        error:nil];
    assert(plan != nil);
    assert([plan.applicationIdentifier isEqualToString:@"TEAM123.com.example.target"]);
    assert(plan.skippedSharedAccessGroupCount == 1);
    assert([plan.workerEntitlements[@"keychain-access-groups"] isEqualToArray:
        @[@"TEAM123.com.example.target"]]);
    assert(plan.deletionPlan.scopes.count == 5);
    for (PXKeychainDeletionScope *scope in plan.deletionPlan.scopes) {
        assert([scope.accessGroup isEqualToString:@"TEAM123.com.example.target"]);
        assert(!scope.isSharedAccessGroup);
        assert(!scope.isSynchronizable);
    }

    for (id unsafeGroup in @[
        @"OTHER99.group.unrelated",
        @"TEAM123.*",
        @"TEAM123.com.apple.private"
    ]) {
        NSDictionary<NSString *, id> *unsafeEntitlements = @{
            @"application-identifier": @"TEAM123.com.example.target",
            @"keychain-access-groups": @[@"TEAM123.com.example.target", unsafeGroup]
        };
        assert([PXKeychainOneShotEntitlementPlan
            planForBundleIdentifier:@"com.example.target"
            signedEntitlements:unsafeEntitlements
            error:nil] == nil);
    }
}

@interface RecordingOneShotExecution : NSObject <PXKeychainOneShotExecuting>
@property (nonatomic, assign) NSUInteger invocationCount;
@property (nonatomic, strong) PXKeychainCommandResponse *response;
@property (nonatomic, copy) NSDictionary<NSString *, id> *signedEntitlements;
@property (nonatomic, copy) NSDictionary<NSString *, id> *lastWorkerEntitlements;
@end

@implementation RecordingOneShotExecution

- (NSDictionary<NSString *, id> *)signedEntitlementsForTargetBundleIdentifier:(NSString *)bundleIdentifier
                                                                           error:(NSError **)error {
    (void)error;
    return self.signedEntitlements ?: @{
        @"application-identifier": [@"TEAM123." stringByAppendingString:bundleIdentifier],
        @"keychain-access-groups": @[[@"TEAM123." stringByAppendingString:bundleIdentifier]]
    };
}

- (PXKeychainOneShotResponse *)executeRequest:(PXKeychainCommandRequest *)request
                           workerEntitlements:(NSDictionary<NSString *, id> *)workerEntitlements
                                        error:(NSError **)error {
    (void)request;
    (void)error;
    self.invocationCount++;
    self.lastWorkerEntitlements = workerEntitlements;
    return (PXKeychainOneShotResponse *)self.response;
}

@end

static NSArray<NSDictionary<NSString *, id> *> *successfulOneShotResults(
    NSArray<NSString *> *accessGroups,
    NSString *sharedAccessGroup
) {
    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (NSString *accessGroup in accessGroups) {
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
                @"sharedAccessGroup": @([accessGroup isEqualToString:sharedAccessGroup]),
                @"success": @YES
            }];
        }
    }
    return results;
}

static void testOneShotControllerClearsVintedSignedCustomGroup(void) {
    NSString *bundleIdentifier = @"lt.manodrabuziai.fr";
    NSString *applicationIdentifier = @"4Y2CNF6C99.lt.manodrabuziai.fr";
    NSString *vintedAccessGroup = @"4Y2CNF6C99.com.vinted.keychain-group";
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(bundleIdentifier)
        error:nil];
    assert(request.includesSharedAccessGroups);

    RecordingOneShotExecution *execution = [[RecordingOneShotExecution alloc] init];
    execution.signedEntitlements = @{
        @"application-identifier": applicationIdentifier,
        @"keychain-access-groups": @[vintedAccessGroup]
    };
    execution.response = [PXKeychainCommandResponse responseWithPropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": request.requestID,
        @"targetBundleID": request.targetBundleID,
        @"success": @YES,
        @"results": successfulOneShotResults(@[vintedAccessGroup], vintedAccessGroup),
        @"failureCode": @"",
        @"protectedSharedAccessGroupCount": @0
    } error:nil];

    NSError *error = nil;
    PXKeychainOneShotResponse *response = [[[PXKeychainOneShotController alloc]
        initWithExecution:execution]
        executeRequest:request
               context:context(bundleIdentifier, YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:&error];

    assert(response.isSuccessful);
    assert(error == nil);
    assert(response.protectedSharedAccessGroupCount == 0);
    assert(execution.invocationCount == 1);
    assert(([execution.lastWorkerEntitlements[@"keychain-access-groups"] isEqualToArray:
        @[vintedAccessGroup]]));
    assert(![execution.lastWorkerEntitlements[@"keychain-access-groups"]
        containsObject:applicationIdentifier]);
}

static void testOneShotEntitlementPlanRejectsDuplicateSignedGroups(void) {
    NSDictionary<NSString *, id> *entitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[
            @"TEAM123.com.example.target",
            @"TEAM123.group.target",
            @"TEAM123.group.target"
        ]
    };
    NSError *error = nil;
    assert([PXKeychainOneShotEntitlementPlan
        planForBundleIdentifier:@"com.example.target"
        signedEntitlements:entitlements
        includeSharedAccessGroups:YES
        error:&error] == nil);
    assert(error != nil);
}

static void testOneShotControllerDoesNotLeakGroupsAcrossMultipleSelectedApps(void) {
    NSString *firstBundleIdentifier = @"com.example.alpha";
    NSString *firstApplicationIdentifier = @"TEAM123.com.example.alpha";
    NSString *firstCustomGroup = @"TEAM123.group.alpha";
    PXKeychainCommandRequest *firstRequest = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(firstBundleIdentifier)
        error:nil];

    RecordingOneShotExecution *execution = [[RecordingOneShotExecution alloc] init];
    execution.signedEntitlements = @{
        @"application-identifier": firstApplicationIdentifier,
        @"keychain-access-groups": @[firstApplicationIdentifier, firstCustomGroup]
    };
    execution.response = [PXKeychainCommandResponse responseWithPropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": firstRequest.requestID,
        @"targetBundleID": firstRequest.targetBundleID,
        @"success": @YES,
        @"results": successfulOneShotResults(
            @[firstApplicationIdentifier, firstCustomGroup], firstCustomGroup),
        @"failureCode": @"",
        @"protectedSharedAccessGroupCount": @0
    } error:nil];
    PXKeychainOneShotController *controller = [[PXKeychainOneShotController alloc]
        initWithExecution:execution];

    assert([controller executeRequest:firstRequest
                              context:context(firstBundleIdentifier, YES, NO)
                                  now:[NSDate dateWithTimeIntervalSince1970:1010]
                                error:nil].isSuccessful);
    assert(([execution.lastWorkerEntitlements[@"keychain-access-groups"] isEqualToArray:
        @[firstApplicationIdentifier, firstCustomGroup]]));

    NSString *secondBundleIdentifier = @"org.example.beta";
    NSString *secondApplicationIdentifier = @"TEAM999.org.example.beta";
    NSString *secondCustomGroup = @"TEAM999.group.beta";
    NSMutableDictionary<NSString *, id> *secondPropertyList =
        [freshRequestPropertyList(secondBundleIdentifier) mutableCopy];
    secondPropertyList[@"requestID"] = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    PXKeychainCommandRequest *secondRequest = [PXKeychainCommandRequest
        requestWithPropertyList:secondPropertyList
        error:nil];
    execution.signedEntitlements = @{
        @"application-identifier": secondApplicationIdentifier,
        @"keychain-access-groups": @[secondApplicationIdentifier, secondCustomGroup]
    };
    execution.response = [PXKeychainCommandResponse responseWithPropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": secondRequest.requestID,
        @"targetBundleID": secondRequest.targetBundleID,
        @"success": @YES,
        @"results": successfulOneShotResults(
            @[secondApplicationIdentifier, secondCustomGroup], secondCustomGroup),
        @"failureCode": @"",
        @"protectedSharedAccessGroupCount": @0
    } error:nil];

    assert([controller executeRequest:secondRequest
                              context:context(secondBundleIdentifier, YES, NO)
                                  now:[NSDate dateWithTimeIntervalSince1970:1010]
                                error:nil].isSuccessful);
    assert(execution.invocationCount == 2);
    assert(([execution.lastWorkerEntitlements[@"keychain-access-groups"] isEqualToArray:
        @[secondApplicationIdentifier, secondCustomGroup]]));
    assert(![execution.lastWorkerEntitlements[@"keychain-access-groups"]
        containsObject:firstCustomGroup]);
}

static void testOneShotControllerRejectsSynchronizableCleanupBeforeExecution(void) {
    RecordingOneShotExecution *execution = [[RecordingOneShotExecution alloc] init];
    PXKeychainOneShotController *controller = [[PXKeychainOneShotController alloc]
        initWithExecution:execution];
    NSMutableDictionary<NSString *, id> *synchronizablePropertyList =
        [freshRequestPropertyList(@"com.example.target") mutableCopy];
    synchronizablePropertyList[@"includeSharedAccessGroups"] = @NO;
    synchronizablePropertyList[@"synchronizablePolicy"] = @"include";
    PXKeychainCommandRequest *synchronizableRequest = [PXKeychainCommandRequest
        requestWithPropertyList:synchronizablePropertyList
        error:nil];
    assert([controller executeRequest:synchronizableRequest
                              context:context(@"com.example.target", YES, NO)
                                  now:[NSDate dateWithTimeIntervalSince1970:1010]
                                error:nil] == nil);
    assert(execution.invocationCount == 0);
}

static void testOneShotControllerRejectsWorkerResultsOutsideExactApplicationGroup(void) {
    RecordingOneShotExecution *execution = [[RecordingOneShotExecution alloc] init];
    NSMutableDictionary<NSString *, id> *propertyList =
        [freshRequestPropertyList(@"com.example.target") mutableCopy];
    propertyList[@"includeSharedAccessGroups"] = @NO;
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:propertyList
        error:nil];
    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (NSString *keychainClass in @[
        PXKeychainClassGenericPassword,
        PXKeychainClassInternetPassword,
        PXKeychainClassCertificate,
        PXKeychainClassKey,
        PXKeychainClassIdentity
    ]) {
        [results addObject:@{
            @"class": keychainClass,
            @"accessGroup": @"TEAM123.group.shared",
            @"beforeCount": @0,
            @"deletedCount": @0,
            @"remainingCount": @0,
            @"queryStatus": @(PXKeychainStatusItemNotFound),
            @"deleteStatus": @(PXKeychainStatusItemNotFound),
            @"verificationStatus": @(PXKeychainStatusItemNotFound),
            @"skippedSynchronizable": @YES,
            @"sharedAccessGroup": @NO,
            @"success": @YES
        }];
    }
    execution.response = [PXKeychainCommandResponse responseWithPropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": request.requestID,
        @"targetBundleID": request.targetBundleID,
        @"success": @YES,
        @"results": results,
        @"failureCode": @""
    } error:nil];
    PXKeychainOneShotController *controller = [[PXKeychainOneShotController alloc]
        initWithExecution:execution];
    NSError *error = nil;
    PXKeychainOneShotResponse *response = [controller
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:&error];
    assert(response == nil);
    assert([error.domain isEqualToString:PXKeychainOneShotErrorDomain]);
    assert(execution.invocationCount == 1);
}

@interface SuccessfulSecurityAdapter : NSObject <PXKeychainSecurityAdapter>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *queryCounts;
@end

@implementation SuccessfulSecurityAdapter

- (instancetype)init {
    self = [super init];
    if (self) {
        _queryCounts = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)entitlementsForBundleIdentifier:(NSString *)bundleIdentifier
                                                             error:(NSError **)error {
    (void)error;
    return @{
        @"application-identifier": [@"TEAM123." stringByAppendingString:bundleIdentifier],
        @"keychain-access-groups": @[[@"TEAM123." stringByAppendingString:bundleIdentifier]]
    };
}

- (NSUInteger)countItemsForClass:(NSString *)keychainClass
                     accessGroup:(NSString *)accessGroup
                  synchronizable:(BOOL)synchronizable
                          status:(int32_t *)status {
    assert(!synchronizable);
    NSString *key = [NSString stringWithFormat:@"%@|%@", keychainClass, accessGroup];
    NSUInteger queryCount = [self.queryCounts[key] unsignedIntegerValue];
    self.queryCounts[key] = @(queryCount + 1);
    if (queryCount == 0) {
        *status = PXKeychainStatusSuccess;
        return 2;
    }
    *status = PXKeychainStatusItemNotFound;
    return 0;
}

- (int32_t)deleteItemsForClass:(NSString *)keychainClass
                   accessGroup:(NSString *)accessGroup
                synchronizable:(BOOL)synchronizable {
    assert(keychainClass.length > 0);
    assert(accessGroup.length > 0);
    assert(!synchronizable);
    return PXKeychainStatusSuccess;
}

@end

@interface VintedCustomGroupSecurityAdapter : SuccessfulSecurityAdapter
@property (nonatomic, strong) NSMutableSet<NSString *> *deletedGroups;
@end

@implementation VintedCustomGroupSecurityAdapter

- (instancetype)init {
    self = [super init];
    if (self) _deletedGroups = [NSMutableSet set];
    return self;
}

- (NSDictionary<NSString *, id> *)entitlementsForBundleIdentifier:(NSString *)bundleIdentifier
                                                             error:(NSError **)error {
    (void)error;
    assert([bundleIdentifier isEqualToString:@"lt.manodrabuziai.fr"]);
    return @{
        @"application-identifier": @"4Y2CNF6C99.lt.manodrabuziai.fr",
        @"keychain-access-groups": @[@"4Y2CNF6C99.com.vinted.keychain-group"]
    };
}

- (int32_t)deleteItemsForClass:(NSString *)keychainClass
                   accessGroup:(NSString *)accessGroup
                synchronizable:(BOOL)synchronizable {
    assert([accessGroup isEqualToString:@"4Y2CNF6C99.com.vinted.keychain-group"]);
    [self.deletedGroups addObject:accessGroup];
    return [super deleteItemsForClass:keychainClass
                         accessGroup:accessGroup
                      synchronizable:synchronizable];
}

@end

static void testExecutorClearsOnlyVintedSignedCustomGroup(void) {
    NSString *bundleIdentifier = @"lt.manodrabuziai.fr";
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(bundleIdentifier)
        error:nil];
    VintedCustomGroupSecurityAdapter *adapter = [[VintedCustomGroupSecurityAdapter alloc] init];
    PXKeychainCommandExecutor *executor = [[PXKeychainCommandExecutor alloc]
        initWithValidator:[[PXKeychainCommandValidator alloc] init]
        securityAdapter:adapter];
    NSError *error = nil;
    PXKeychainCommandResponse *response = [executor
        executeRequest:request
               context:context(bundleIdentifier, YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:&error];
    assert(response.isSuccessful);
    assert(error == nil);
    assert(response.results.count == 5);
    assert([adapter.deletedGroups isEqualToSet:
        [NSSet setWithObject:@"4Y2CNF6C99.com.vinted.keychain-group"]]);
}

static void testOneShotControllerReportsProtectedGroupForExclusiveCleanup(void) {
    NSMutableDictionary<NSString *, id> *propertyList =
        [freshRequestPropertyList(@"com.example.target") mutableCopy];
    propertyList[@"includeSharedAccessGroups"] = @NO;
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:propertyList
        error:nil];
    RecordingOneShotExecution *execution = [[RecordingOneShotExecution alloc] init];
    execution.signedEntitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[
            @"TEAM123.com.example.target",
            @"TEAM123.group.example.shared"
        ]
    };
    execution.response = [PXKeychainCommandResponse responseWithPropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": request.requestID,
        @"targetBundleID": request.targetBundleID,
        @"success": @YES,
        @"results": successfulOneShotResults(@[@"TEAM123.com.example.target"], @""),
        @"failureCode": @"",
        @"protectedSharedAccessGroupCount": @0
    } error:nil];
    NSError *error = nil;
    PXKeychainOneShotResponse *response = [[[PXKeychainOneShotController alloc]
        initWithExecution:execution]
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                  error:&error];

    assert(response.isSuccessful);
    assert(error == nil);
    assert(response.protectedSharedAccessGroupCount == 1);
    assert(execution.invocationCount == 1);
    assert([execution.lastWorkerEntitlements[@"keychain-access-groups"] isEqualToArray:
        @[@"TEAM123.com.example.target"]]);
}


static void testFullSuccessRequiresPostDeleteVerificationForEveryScope(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    SuccessfulSecurityAdapter *adapter = [[SuccessfulSecurityAdapter alloc] init];
    PXKeychainCommandExecutor *executor = [[PXKeychainCommandExecutor alloc]
        initWithValidator:[[PXKeychainCommandValidator alloc] init]
        securityAdapter:adapter];
    PXKeychainCommandResponse *response = [executor
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:nil];
    assert(response.isSuccessful);
    assert(response.results.count == 5);
    assert(adapter.queryCounts.count == response.results.count);
    for (PXKeychainScopeResult *result in response.results) {
        assert(result.isSuccessful);
        assert(result.beforeCount == 2);
        assert(result.deletedCount == 2);
        assert(result.remainingCount == 0);
        assert(result.queryStatus == PXKeychainStatusSuccess);
        assert(result.deleteStatus == PXKeychainStatusSuccess);
        assert(result.verificationStatus == PXKeychainStatusItemNotFound);
        assert(result.skippedSynchronizable);
    }
}

@interface PartialFailureSecurityAdapter : SuccessfulSecurityAdapter
@end


@implementation PartialFailureSecurityAdapter

- (int32_t)deleteItemsForClass:(NSString *)keychainClass
                   accessGroup:(NSString *)accessGroup
                synchronizable:(BOOL)synchronizable {
    if ([keychainClass isEqualToString:PXKeychainClassKey]) {
        return -25293;
    }
    return [super deleteItemsForClass:keychainClass
                          accessGroup:accessGroup
                       synchronizable:synchronizable];
}

@end


static void testPartialFailureIsNotSuccessAndResponseContainsNoItemMetadata(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    PXKeychainCommandResponse *response = [[[PXKeychainCommandExecutor alloc]
        initWithValidator:[[PXKeychainCommandValidator alloc] init]
        securityAdapter:[[PartialFailureSecurityAdapter alloc] init]]
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:nil];
    assert(response != nil);
    assert(!response.isSuccessful);
    NSUInteger failureCount = 0;
    for (PXKeychainScopeResult *result in response.results) {
        if (!result.isSuccessful) failureCount++;
    }
    assert(failureCount == 1);

    NSDictionary<NSString *, id> *propertyList = [response propertyListRepresentation];
    NSString *serializedDescription = propertyList.description.lowercaseString;
    assert([serializedDescription rangeOfString:@"account"].location == NSNotFound);
    assert([serializedDescription rangeOfString:@"service"].location == NSNotFound);
    assert([serializedDescription rangeOfString:@"label"].location == NSNotFound);
    assert([serializedDescription rangeOfString:@"persistent"].location == NSNotFound);
    assert([serializedDescription rangeOfString:@"secret"].location == NSNotFound);

    NSMutableDictionary<NSString *, id> *injectedResponse = [propertyList mutableCopy];
    injectedResponse[@"account"] = @"forbidden";
    assert([PXKeychainCommandResponse responseWithPropertyList:injectedResponse error:nil] == nil);
}

@interface VerificationFailureSecurityAdapter : SuccessfulSecurityAdapter
@end


@implementation VerificationFailureSecurityAdapter

- (NSUInteger)countItemsForClass:(NSString *)keychainClass
                     accessGroup:(NSString *)accessGroup
                  synchronizable:(BOOL)synchronizable
                          status:(int32_t *)status {
    if ([keychainClass isEqualToString:PXKeychainClassKey]) {
        (void)accessGroup;
        assert(!synchronizable);
        *status = PXKeychainStatusSuccess;
        return 1;
    }
    return [super countItemsForClass:keychainClass
                         accessGroup:accessGroup
                      synchronizable:synchronizable
                              status:status];
}

@end


static void testVerificationFailureIsNotReportedAsSuccessfulDeletion(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    PXKeychainCommandResponse *response = [[[PXKeychainCommandExecutor alloc]
        initWithValidator:[[PXKeychainCommandValidator alloc] init]
        securityAdapter:[[VerificationFailureSecurityAdapter alloc] init]]
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:nil];
    assert(response != nil);
    assert(!response.isSuccessful);
    for (PXKeychainScopeResult *result in response.results) {
        if ([result.keychainClass isEqualToString:PXKeychainClassKey]) {
            assert(!result.isSuccessful);
            assert(result.remainingCount == 1);
            assert(result.deletedCount == 0);
        }
    }
}

@interface RecordingLifecycle : NSObject <PXKeychainAppLifecycle>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@end


@implementation RecordingLifecycle

- (void)ensureRunningBundleIdentifier:(NSString *)bundleIdentifier
                            completion:(void (^)(BOOL, NSError *))completion {
    assert([bundleIdentifier isEqualToString:@"com.example.target"]);
    [self.events addObject:@"ensure-running"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(YES, nil);
    });
}

- (void)terminateBundleIdentifier:(NSString *)bundleIdentifier
                        completion:(void (^)(BOOL, NSError *))completion {
    assert([bundleIdentifier isEqualToString:@"com.example.target"]);
    [self.events addObject:@"terminate"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(YES, nil);
    });
}

@end

@interface RecordingTransport : NSObject <PXKeychainCommandTransport>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, strong) PXKeychainCommandResponse *response;
@end


@implementation RecordingTransport

- (void)waitForReadyBundleIdentifier:(NSString *)bundleIdentifier
                            profileID:(NSString *)profileID
                         generationID:(NSString *)generationID
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(BOOL, NSError *))completion {
    assert([bundleIdentifier isEqualToString:@"com.example.target"]);
    assert(profileID.length > 0);
    assert(generationID.length > 0);
    assert(timeout > 0);
    [self.events addObject:@"ready"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(YES, nil);
    });
}

- (void)sendRequest:(PXKeychainCommandRequest *)request
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(PXKeychainCommandResponse *, NSError *))completion {
    assert(request != nil);
    assert(timeout > 0);
    [self.events addObject:@"request"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self.events addObject:@"ack"];
        completion(self.response, nil);
    });
}

@end


static void testControllerSequenceIsAsynchronousBoundedAndTerminatesAfterSuccess(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    PXKeychainCommandResponse *successfulResponse = [[[PXKeychainCommandExecutor alloc]
        initWithValidator:[[PXKeychainCommandValidator alloc] init]
        securityAdapter:[[SuccessfulSecurityAdapter alloc] init]]
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:nil];
    NSMutableArray<NSString *> *events = [NSMutableArray array];
    RecordingLifecycle *lifecycle = [[RecordingLifecycle alloc] init];
    lifecycle.events = events;
    RecordingTransport *transport = [[RecordingTransport alloc] init];
    transport.events = events;
    transport.response = successfulResponse;
    dispatch_queue_t completionQueue = dispatch_queue_create("com.hydra.projectx.keychain-tests", DISPATCH_QUEUE_SERIAL);
    PXKeychainCommandController *controller = [[PXKeychainCommandController alloc]
        initWithTransport:transport
        lifecycle:lifecycle
        readyTimeout:2
        responseTimeout:3
        completionQueue:completionQueue];

    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block BOOL methodReturned = NO;
    [controller executeRequest:request completion:^(PXKeychainCommandResponse *response, NSError *error) {
        assert(methodReturned);
        assert(response.isSuccessful);
        assert(error == nil);
        [events addObject:@"complete"];
        dispatch_semaphore_signal(completed);
    }];
    methodReturned = YES;
    assert(dispatch_semaphore_wait(completed,
                                   dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    NSArray<NSString *> *expectedEvents = @[
        @"ensure-running", @"ready", @"request", @"ack", @"terminate", @"complete"
    ];
    assert([events isEqualToArray:expectedEvents]);
}

@interface FailingLifecycle : NSObject <PXKeychainAppLifecycle>
@end


@implementation FailingLifecycle

- (void)ensureRunningBundleIdentifier:(NSString *)bundleIdentifier
                            completion:(void (^)(BOOL, NSError *))completion {
    (void)bundleIdentifier;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(NO, [NSError errorWithDomain:@"test" code:1 userInfo:nil]);
    });
}

- (void)terminateBundleIdentifier:(NSString *)bundleIdentifier
                        completion:(void (^)(BOOL, NSError *))completion {
    (void)bundleIdentifier;
    completion(NO, [NSError errorWithDomain:@"test" code:2 userInfo:nil]);
}

@end


static void testLaunchFailureReturnsFailureWithoutSendingRequest(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    NSMutableArray<NSString *> *events = [NSMutableArray array];
    RecordingTransport *transport = [[RecordingTransport alloc] init];
    transport.events = events;
    PXKeychainCommandController *controller = [[PXKeychainCommandController alloc]
        initWithTransport:transport
        lifecycle:[[FailingLifecycle alloc] init]
        readyTimeout:0.1
        responseTimeout:0.1
        completionQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [controller executeRequest:request completion:^(PXKeychainCommandResponse *response, NSError *error) {
        assert(response == nil);
        assert(error != nil);
        dispatch_semaphore_signal(completed);
    }];
    assert(dispatch_semaphore_wait(completed,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(events.count == 0);
}

static void testFileStoreUsesAtomicExactPathsAndOneShotClaims(void) {
    NSString *rootDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXKeychainCommandFileStore *store = [[PXKeychainCommandFileStore alloc]
        initWithRootDirectory:rootDirectory];
    assert([store prepareWithError:nil]);
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    assert([store writeRequest:request error:nil]);
    NSArray<PXKeychainCommandRequest *> *pending = [store pendingRequestsWithError:nil];
    assert(pending.count == 1);
    assert([pending.firstObject.requestID isEqualToString:request.requestID]);
    assert([store claimRequestID:request.requestID error:nil]);
    assert([store isRequestIDClaimed:request.requestID]);
    assert(![store isRequestIDCompleted:request.requestID]);
    assert([store markRequestIDCompleted:request.requestID error:nil]);
    assert([store isRequestIDCompleted:request.requestID]);
    assert(![store claimRequestID:request.requestID error:nil]);
    assert(![store claimRequestID:@"../../escape" error:nil]);

    assert([store writeReadinessForBundleIdentifier:@"com.example.target"
                                          profileID:request.profileID
                                       generationID:request.generationID
                                                now:[NSDate dateWithTimeIntervalSince1970:1010]
                                              error:nil]);
    assert([store isReadyBundleIdentifier:@"com.example.target"
                                profileID:request.profileID
                             generationID:request.generationID
                                      now:[NSDate dateWithTimeIntervalSince1970:1015]
                              maximumAge:10]);
    assert(![store isReadyBundleIdentifier:@"com.example.other"
                                 profileID:request.profileID
                              generationID:request.generationID
                                       now:[NSDate dateWithTimeIntervalSince1970:1015]
                               maximumAge:10]);
    assert(![store isReadyBundleIdentifier:@"com.example.target"
                                 profileID:request.profileID
                              generationID:request.generationID
                                       now:[NSDate dateWithTimeIntervalSince1970:1030]
                               maximumAge:10]);

    NSArray<NSString *> *rootContents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:rootDirectory
        error:nil];
    NSSet<NSString *> *expectedDirectories = [NSSet setWithArray:@[
        @"requests", @"responses", @"claims", @"readiness"
    ]];
    assert([[NSSet setWithArray:rootContents] isEqualToSet:expectedDirectories]);
    [[NSFileManager defaultManager] removeItemAtPath:rootDirectory error:nil];
}

static void testFileStoreRejectsSymlinkedCommandDirectories(void) {
    NSString *fixtureRoot = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *rootDirectory = [fixtureRoot stringByAppendingPathComponent:@"command-root"];
    NSString *escapeDirectory = [fixtureRoot stringByAppendingPathComponent:@"escape"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    assert([fileManager createDirectoryAtPath:escapeDirectory
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:nil]);
    PXKeychainCommandFileStore *store = [[PXKeychainCommandFileStore alloc]
        initWithRootDirectory:rootDirectory];
    assert([store prepareWithError:nil]);
    NSString *requestsDirectory = [rootDirectory stringByAppendingPathComponent:@"requests"];
    assert([fileManager removeItemAtPath:requestsDirectory error:nil]);
    assert([fileManager createSymbolicLinkAtPath:requestsDirectory
                             withDestinationPath:escapeDirectory
                                          error:nil]);
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    assert(![store writeRequest:request error:nil]);
    assert([fileManager contentsOfDirectoryAtPath:escapeDirectory error:nil].count == 0);
    [fileManager removeItemAtPath:fixtureRoot error:nil];
}

static void testFileStoreSanitizesRejectableInvalidRequestHeaders(void) {
    NSString *rootDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXKeychainCommandFileStore *store = [[PXKeychainCommandFileStore alloc]
        initWithRootDirectory:rootDirectory];
    assert([store prepareWithError:nil]);
    NSString *requestID = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    NSDictionary<NSString *, id> *invalidRequest = @{
        @"schemaVersion": @999,
        @"requestID": requestID,
        @"targetBundleID": @"com.example.target",
        @"account": @"must-not-escape"
    };
    NSString *requestPath = [[[rootDirectory stringByAppendingPathComponent:@"requests"]
        stringByAppendingPathComponent:requestID] stringByAppendingPathExtension:@"plist"];
    assert([invalidRequest writeToFile:requestPath atomically:YES]);
    NSArray<NSDictionary<NSString *, NSString *> *> *headers =
        [store rejectedRequestHeadersWithError:nil];
    assert(headers.count == 1);
    NSDictionary<NSString *, NSString *> *expectedHeader = @{
        @"requestID": requestID,
        @"targetBundleID": @"com.example.target"
    };
    assert([headers.firstObject isEqualToDictionary:expectedHeader]);
    assert([headers.description rangeOfString:@"must-not-escape"].location == NSNotFound);
    [[NSFileManager defaultManager] removeItemAtPath:rootDirectory error:nil];
}

static void testFileTransportReadinessAndAcknowledgementAreAsynchronous(void) {
    NSString *rootDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXKeychainCommandFileStore *store = [[PXKeychainCommandFileStore alloc]
        initWithRootDirectory:rootDirectory];
    assert([store prepareWithError:nil]);
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    assert([store writeReadinessForBundleIdentifier:request.targetBundleID
                                          profileID:request.profileID
                                       generationID:request.generationID
                                                now:[NSDate date]
                                              error:nil]);
    dispatch_queue_t pollingQueue = dispatch_queue_create(
        "com.hydra.projectx.keychain-transport-tests", DISPATCH_QUEUE_SERIAL);
    PXKeychainFileTransport *transport = [[PXKeychainFileTransport alloc]
        initWithFileStore:store pollingQueue:pollingQueue];
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    [transport waitForReadyBundleIdentifier:request.targetBundleID
                                  profileID:request.profileID
                               generationID:request.generationID
                                    timeout:1
                                 completion:^(BOOL isReady, NSError *error) {
        assert(isReady);
        assert(error == nil);
        dispatch_semaphore_signal(ready);
    }];
    assert(dispatch_semaphore_wait(ready,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);

    PXKeychainCommandResponse *targetResponse = [[[PXKeychainCommandExecutor alloc]
        initWithValidator:[[PXKeychainCommandValidator alloc] init]
        securityAdapter:[[SuccessfulSecurityAdapter alloc] init]]
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:nil];
    dispatch_semaphore_t acknowledged = dispatch_semaphore_create(0);
    __block BOOL sendReturned = NO;
    [transport sendRequest:request timeout:1 completion:^(PXKeychainCommandResponse *response,
                                                          NSError *error) {
        assert(sendReturned);
        assert(response.isSuccessful);
        assert(error == nil);
        dispatch_semaphore_signal(acknowledged);
    }];
    sendReturned = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        assert([store pendingRequestsWithError:nil].count == 1);
        assert([store claimRequestID:request.requestID error:nil]);
        assert([store writeResponse:targetResponse error:nil]);
        assert([store markRequestIDCompleted:request.requestID error:nil]);
    });
    assert(dispatch_semaphore_wait(acknowledged,
                                   dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    assert([store pendingRequestsWithError:nil].count == 0);
    assert(![store claimRequestID:request.requestID error:nil]);
    assert([store isRequestIDCompleted:request.requestID]);
    dispatch_semaphore_t replayRejected = dispatch_semaphore_create(0);
    [transport sendRequest:request timeout:1 completion:^(PXKeychainCommandResponse *response,
                                                          NSError *error) {
        assert(response == nil);
        assert(error != nil);
        dispatch_semaphore_signal(replayRejected);
    }];
    assert(dispatch_semaphore_wait(replayRejected,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert([store pendingRequestsWithError:nil].count == 0);
    [[NSFileManager defaultManager] removeItemAtPath:rootDirectory error:nil];
}

static void testFileTransportTimeoutIsFailureAndRemovesPendingRequest(void) {
    NSString *rootDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXKeychainCommandFileStore *store = [[PXKeychainCommandFileStore alloc]
        initWithRootDirectory:rootDirectory];
    PXKeychainFileTransport *transport = [[PXKeychainFileTransport alloc]
        initWithFileStore:store
        pollingQueue:dispatch_queue_create("com.hydra.projectx.keychain-timeout-tests",
                                           DISPATCH_QUEUE_SERIAL)];
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [transport sendRequest:request timeout:0.1 completion:^(PXKeychainCommandResponse *response,
                                                            NSError *error) {
        assert(response == nil);
        assert(error != nil);
        dispatch_semaphore_signal(completed);
    }];
    assert(dispatch_semaphore_wait(completed,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert([store pendingRequestsWithError:nil].count == 0);
    [[NSFileManager defaultManager] removeItemAtPath:rootDirectory error:nil];
}

static void testMissingReceiverReadinessTimesOutBeforeRequestIsQueued(void) {
    NSString *rootDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXKeychainCommandFileStore *store = [[PXKeychainCommandFileStore alloc]
        initWithRootDirectory:rootDirectory];
    PXKeychainFileTransport *transport = [[PXKeychainFileTransport alloc]
        initWithFileStore:store
        pollingQueue:dispatch_queue_create("com.hydra.projectx.keychain-readiness-timeout-tests",
                                           DISPATCH_QUEUE_SERIAL)];
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [transport waitForReadyBundleIdentifier:request.targetBundleID
                                  profileID:request.profileID
                               generationID:request.generationID
                                    timeout:0.1
                                 completion:^(BOOL ready, NSError *error) {
        assert(!ready);
        assert(error != nil);
        assert([error.localizedDescription containsString:@"readiness timed out"]);
        dispatch_semaphore_signal(completed);
    }];
    assert(dispatch_semaphore_wait(completed,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert([store pendingRequestsWithError:nil].count == 0);
    [[NSFileManager defaultManager] removeItemAtPath:rootDirectory error:nil];
}

static NSDictionary<NSString *, id> *synchronizableRequestPropertyList(NSString *targetBundleID) {
    NSMutableDictionary<NSString *, id> *propertyList =
        [freshRequestPropertyList(targetBundleID) mutableCopy];
    propertyList[@"synchronizablePolicy"] = @"include";
    return propertyList;
}

static void testSynchronizablePolicyParsesAndDefaultsToExclude(void) {
    PXKeychainCommandRequest *excludeRequest = [PXKeychainCommandRequest
        requestWithPropertyList:freshRequestPropertyList(@"com.example.target")
        error:nil];
    assert(excludeRequest != nil);
    assert(!excludeRequest.includesSynchronizableItems);

    PXKeychainCommandRequest *includeRequest = [PXKeychainCommandRequest
        requestWithPropertyList:synchronizableRequestPropertyList(@"com.example.target")
        error:nil];
    assert(includeRequest != nil);
    assert(includeRequest.includesSynchronizableItems);

    NSMutableDictionary<NSString *, id> *invalid =
        [freshRequestPropertyList(@"com.example.target") mutableCopy];
    invalid[@"synchronizablePolicy"] = @"everything";
    assert([PXKeychainCommandRequest requestWithPropertyList:invalid error:nil] == nil);
}

static void testFreshRequestRoundTripsSynchronizablePolicy(void) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000];
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        freshRequestForBundleIdentifier:@"com.example.target"
        profileID:@"22222222-2222-4222-8222-222222222222"
        generationID:@"33333333-3333-4333-8333-333333333333"
        includeSharedAccessGroups:NO
        includeSynchronizableItems:YES
        now:now
        ttl:30
        error:nil];
    assert(request != nil);
    assert(request.includesSynchronizableItems);
    assert([request.propertyListRepresentation[@"synchronizablePolicy"] isEqualToString:@"include"]);
}

static void testSynchronizablePlanDoublesScopesAcrossBothModes(void) {
    NSDictionary<NSString *, id> *entitlements = @{
        @"application-identifier": @"TEAM123.com.example.target",
        @"keychain-access-groups": @[@"TEAM123.com.example.target"]
    };
    PXKeychainDeletionPlan *excludePlan = [PXKeychainDeletionPlan
        planForBundleIdentifier:@"com.example.target"
                   entitlements:entitlements
     includeSharedAccessGroups:NO
                          error:nil];
    assert(excludePlan.scopes.count == 5);
    for (PXKeychainDeletionScope *scope in excludePlan.scopes) {
        assert(!scope.isSynchronizable);
    }

    PXKeychainDeletionPlan *includePlan = [PXKeychainDeletionPlan
        planForBundleIdentifier:@"com.example.target"
                   entitlements:entitlements
     includeSharedAccessGroups:NO
     includeSynchronizableItems:YES
                          error:nil];
    assert(includePlan.scopes.count == 10);
    NSUInteger synchronizableScopes = 0;
    for (PXKeychainDeletionScope *scope in includePlan.scopes) {
        if (scope.isSynchronizable) synchronizableScopes++;
    }
    assert(synchronizableScopes == 5);
}

@interface SynchronizableAwareSecurityAdapter : NSObject <PXKeychainSecurityAdapter>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *queryCounts;
@property (nonatomic, assign) NSUInteger synchronizableDeletes;
@end

@implementation SynchronizableAwareSecurityAdapter

- (instancetype)init {
    self = [super init];
    if (self) {
        _queryCounts = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)entitlementsForBundleIdentifier:(NSString *)bundleIdentifier
                                                             error:(NSError **)error {
    (void)error;
    return @{
        @"application-identifier": [@"TEAM123." stringByAppendingString:bundleIdentifier],
        @"keychain-access-groups": @[[@"TEAM123." stringByAppendingString:bundleIdentifier]]
    };
}

- (NSUInteger)countItemsForClass:(NSString *)keychainClass
                     accessGroup:(NSString *)accessGroup
                  synchronizable:(BOOL)synchronizable
                          status:(int32_t *)status {
    NSString *key = [NSString stringWithFormat:@"%@|%@|%d", keychainClass, accessGroup, synchronizable];
    NSUInteger queryCount = [self.queryCounts[key] unsignedIntegerValue];
    self.queryCounts[key] = @(queryCount + 1);
    if (queryCount == 0) {
        *status = PXKeychainStatusSuccess;
        return 1;
    }
    *status = PXKeychainStatusItemNotFound;
    return 0;
}

- (int32_t)deleteItemsForClass:(NSString *)keychainClass
                   accessGroup:(NSString *)accessGroup
                synchronizable:(BOOL)synchronizable {
    (void)keychainClass;
    (void)accessGroup;
    if (synchronizable) self.synchronizableDeletes++;
    return PXKeychainStatusSuccess;
}

@end

static void testExecutorDeletesSynchronizableItemsWhenRequested(void) {
    PXKeychainCommandRequest *request = [PXKeychainCommandRequest
        requestWithPropertyList:synchronizableRequestPropertyList(@"com.example.target")
        error:nil];
    assert(request != nil);
    SynchronizableAwareSecurityAdapter *adapter = [[SynchronizableAwareSecurityAdapter alloc] init];
    PXKeychainCommandResponse *response = [[[PXKeychainCommandExecutor alloc]
        initWithValidator:[[PXKeychainCommandValidator alloc] init]
        securityAdapter:adapter]
        executeRequest:request
               context:context(@"com.example.target", YES, NO)
                   now:[NSDate dateWithTimeIntervalSince1970:1010]
                 error:nil];
    assert(response.isSuccessful);
    assert(response.results.count == 10);
    assert(adapter.synchronizableDeletes == 5);
    NSUInteger sweptSynchronizableResults = 0;
    for (PXKeychainScopeResult *result in response.results) {
        assert(result.isSuccessful);
        if (!result.skippedSynchronizable) sweptSynchronizableResults++;
    }
    assert(sweptSynchronizableResults == 5);
}

int main(void) {
    @autoreleasepool {
        testOnlyExactEnabledScopedBundleAcceptsFreshRequest();
        testLegacyProfileIdentifierRemainsBoundAndPathSafe();
        testReceiverRegistersBeforeSelectionButNeverInProtectedProcesses();
        testExpiredReplayAndWrongProfileRequestsNeverExecute();
        testRequestCannotSupplyAccessGroupsOrQueries();
        testDeletionPlanUsesOnlyApprovedClassesAndDerivedApplicationGroups();
        testSharedEntitlementGroupsRequireExplicitFamilyPolicy();
        testMalformedEntitlementGroupsFailClosed();
        testOneShotEntitlementPlanBindsOnlyTheExactApplicationGroup();
        testOneShotControllerClearsVintedSignedCustomGroup();
        testOneShotEntitlementPlanRejectsDuplicateSignedGroups();
        testOneShotControllerDoesNotLeakGroupsAcrossMultipleSelectedApps();
        testOneShotControllerRejectsSynchronizableCleanupBeforeExecution();
        testOneShotControllerReportsProtectedGroupForExclusiveCleanup();
        testExecutorClearsOnlyVintedSignedCustomGroup();
        testOneShotControllerRejectsWorkerResultsOutsideExactApplicationGroup();
        testFullSuccessRequiresPostDeleteVerificationForEveryScope();
        testPartialFailureIsNotSuccessAndResponseContainsNoItemMetadata();
        testVerificationFailureIsNotReportedAsSuccessfulDeletion();
        testSynchronizablePolicyParsesAndDefaultsToExclude();
        testFreshRequestRoundTripsSynchronizablePolicy();
        testSynchronizablePlanDoublesScopesAcrossBothModes();
        testExecutorDeletesSynchronizableItemsWhenRequested();
        testControllerSequenceIsAsynchronousBoundedAndTerminatesAfterSuccess();
        testLaunchFailureReturnsFailureWithoutSendingRequest();
        testFileStoreUsesAtomicExactPathsAndOneShotClaims();
        testFileStoreRejectsSymlinkedCommandDirectories();
        testFileStoreSanitizesRejectableInvalidRequestHeaders();
        testFileTransportReadinessAndAcknowledgementAreAsynchronous();
        testFileTransportTimeoutIsFailureAndRemovesPendingRequest();
        testMissingReceiverReadinessTimesOutBeforeRequestIsQueued();
    }
    return 0;
}
