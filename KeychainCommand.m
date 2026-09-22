#import "KeychainCommand.h"

#import "AppIdentity.h"
#import "PXRootHidePath.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const PXKeychainCommandErrorDomain = @"com.hydra.projectx.keychain-command";
const NSInteger PXKeychainCommandSchemaVersion = 1;
const int32_t PXKeychainStatusSuccess = 0;
const int32_t PXKeychainStatusItemNotFound = -25300;
NSString *const PXKeychainCommandRequestNotification = @"com.hydra.projectx.keychain.request";
NSString *const PXKeychainCommandResponseNotification = @"com.hydra.projectx.keychain.response";
NSString *const PXKeychainCommandReadyNotification = @"com.hydra.projectx.keychain.ready";
NSString *const PXKeychainCommandProbeNotification = @"com.hydra.projectx.keychain.probe";
NSString *const PXKeychainClassGenericPassword = @"generic-password";
NSString *const PXKeychainClassInternetPassword = @"internet-password";
NSString *const PXKeychainClassCertificate = @"certificate";
NSString *const PXKeychainClassKey = @"key";
NSString *const PXKeychainClassIdentity = @"identity";

NSString *PXKeychainCommandDefaultRootDirectory(void) {
    return [PXWeaponXDataPath() stringByAppendingPathComponent:@"KeychainCommands"];
}

BOOL PXKeychainCommandReceiverShouldRegisterForBundleIdentifier(NSString *bundleIdentifier) {
    return PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO);
}

typedef NS_ENUM(NSInteger, PXKeychainCommandErrorCode) {
    PXKeychainCommandErrorInvalidRequest = 1,
    PXKeychainCommandErrorRejected = 2,
    PXKeychainCommandErrorReplay = 3
};

static BOOL PXKeychainCommandFail(NSError * _Nullable * _Nullable error,
                                  PXKeychainCommandErrorCode code,
                                  NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

static BOOL PXKeychainCommandIsUUID(NSString *value) {
    return [value isKindOfClass:[NSString class]] &&
        [[NSUUID alloc] initWithUUIDString:value] != nil;
}

BOOL PXKeychainCommandProfileIdentifierIsValid(NSString *profileIdentifier) {
    if (![profileIdentifier isKindOfClass:[NSString class]] ||
        profileIdentifier.length == 0 || profileIdentifier.length > 128 ||
        [profileIdentifier hasPrefix:@"."]) {
        return NO;
    }
    NSCharacterSet *invalidCharacters = [[NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
    return [profileIdentifier rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

static BOOL PXKeychainStatusAllowsEmptyResult(int32_t status, NSUInteger count) {
    return status == PXKeychainStatusItemNotFound ||
        (status == PXKeychainStatusSuccess && count == 0);
}

@interface PXKeychainCommandRequest ()

@property (nonatomic, copy, readwrite) NSString *requestID;
@property (nonatomic, copy, readwrite) NSString *targetBundleID;
@property (nonatomic, copy, readwrite) NSString *profileID;
@property (nonatomic, copy, readwrite) NSString *generationID;
@property (nonatomic, copy, readwrite) NSString *operation;
@property (nonatomic, strong, readwrite) NSDate *createdAt;
@property (nonatomic, strong, readwrite) NSDate *expiresAt;
@property (nonatomic, assign, readwrite) BOOL includesSharedAccessGroups;
@property (nonatomic, assign, readwrite) BOOL includesSynchronizableItems;

@end

@implementation PXKeychainCommandRequest

+ (instancetype)requestWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                   error:(NSError * _Nullable * _Nullable)error {
    NSSet<NSString *> *allowedKeys = [NSSet setWithArray:@[
        @"schemaVersion", @"requestID", @"targetBundleID", @"profileID",
        @"generationID", @"operation", @"createdAt", @"expiresAt",
        @"synchronizablePolicy", @"includeSharedAccessGroups"
    ]];
    if (![propertyList isKindOfClass:[NSDictionary class]] ||
        ![[NSSet setWithArray:propertyList.allKeys] isSubsetOfSet:allowedKeys]) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorInvalidRequest,
                              @"Request contains unsupported fields");
        return nil;
    }
    NSString *requestID = propertyList[@"requestID"];
    NSString *targetBundleID = propertyList[@"targetBundleID"];
    NSString *profileID = propertyList[@"profileID"];
    NSString *generationID = propertyList[@"generationID"];
    NSString *operation = propertyList[@"operation"];
    NSString *synchronizablePolicy = propertyList[@"synchronizablePolicy"];
    NSDate *createdAt = propertyList[@"createdAt"];
    NSDate *expiresAt = propertyList[@"expiresAt"];
    NSNumber *includeSharedAccessGroups = propertyList[@"includeSharedAccessGroups"];
    if ([propertyList[@"schemaVersion"] integerValue] != PXKeychainCommandSchemaVersion ||
        !PXKeychainCommandIsUUID(requestID) ||
        !PXKeychainCommandProfileIdentifierIsValid(profileID) ||
        !PXKeychainCommandIsUUID(generationID) || targetBundleID.length == 0 ||
        ![operation isEqualToString:@"clear-keychain"] ||
        !([synchronizablePolicy isEqualToString:@"exclude"] ||
          [synchronizablePolicy isEqualToString:@"include"]) ||
        ![createdAt isKindOfClass:[NSDate class]] || ![expiresAt isKindOfClass:[NSDate class]] ||
        ![includeSharedAccessGroups isKindOfClass:[NSNumber class]]) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorInvalidRequest,
                              @"Request fields are incomplete or invalid");
        return nil;
    }
    PXKeychainCommandRequest *request = [[self alloc] init];
    request.requestID = requestID.lowercaseString;
    request.targetBundleID = targetBundleID;
    request.profileID = profileID.lowercaseString;
    request.generationID = generationID.lowercaseString;
    request.operation = operation;
    request.createdAt = createdAt;
    request.expiresAt = expiresAt;
    request.includesSharedAccessGroups = includeSharedAccessGroups.boolValue;
    request.includesSynchronizableItems = [synchronizablePolicy isEqualToString:@"include"];
    return request;
}

+ (instancetype)freshRequestForBundleIdentifier:(NSString *)bundleIdentifier
                                        profileID:(NSString *)profileID
                                     generationID:(NSString *)generationID
                       includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
                       includeSynchronizableItems:(BOOL)includeSynchronizableItems
                                              now:(NSDate *)now
                                             ttl:(NSTimeInterval)ttl
                                           error:(NSError * _Nullable * _Nullable)error {
    if (ttl <= 0 || ttl > 60 || !now) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorInvalidRequest,
                              @"Request lifetime is invalid");
        return nil;
    }
    return [self requestWithPropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": NSUUID.UUID.UUIDString.lowercaseString,
        @"targetBundleID": bundleIdentifier ?: @"",
        @"profileID": profileID ?: @"",
        @"generationID": generationID ?: @"",
        @"operation": @"clear-keychain",
        @"createdAt": now,
        @"expiresAt": [now dateByAddingTimeInterval:ttl],
        @"synchronizablePolicy": includeSynchronizableItems ? @"include" : @"exclude",
        @"includeSharedAccessGroups": @(includeSharedAccessGroups)
    } error:error];
}

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": self.requestID,
        @"targetBundleID": self.targetBundleID,
        @"profileID": self.profileID,
        @"generationID": self.generationID,
        @"operation": self.operation,
        @"createdAt": self.createdAt,
        @"expiresAt": self.expiresAt,
        @"synchronizablePolicy": self.includesSynchronizableItems ? @"include" : @"exclude",
        @"includeSharedAccessGroups": @(self.includesSharedAccessGroups)
    };
}

@end

@interface PXKeychainDeletionScope ()

@property (nonatomic, copy, readwrite) NSString *keychainClass;
@property (nonatomic, copy, readwrite) NSString *accessGroup;
@property (nonatomic, assign, readwrite, getter=isSynchronizable) BOOL synchronizable;
@property (nonatomic, assign, readwrite, getter=isSharedAccessGroup) BOOL sharedAccessGroup;

@end


@implementation PXKeychainDeletionScope
@end

@interface PXKeychainDeletionPlan ()

@property (nonatomic, copy, readwrite) NSArray<PXKeychainDeletionScope *> *scopes;
@property (nonatomic, copy, readwrite) NSString *applicationIdentifier;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *sharedAccessGroups;

@end


@implementation PXKeychainDeletionPlan

static BOOL PXKeychainAccessGroupHasSafeTeamPrefix(NSString *accessGroup,
                                                   NSString *teamPrefix) {
    if (![accessGroup hasPrefix:[teamPrefix stringByAppendingString:@"."]] ||
        [accessGroup containsString:@"$"] || [accessGroup containsString:@"/"] ||
        [accessGroup containsString:@"*"]) {
        return NO;
    }
    NSString *groupSuffix = [accessGroup substringFromIndex:teamPrefix.length + 1].lowercaseString;
    return ![groupSuffix isEqualToString:@"com.apple"] &&
        ![groupSuffix hasPrefix:@"com.apple."] &&
        ![groupSuffix isEqualToString:@"group.com.apple"] &&
        ![groupSuffix hasPrefix:@"group.com.apple."];
}

static NSString *PXKeychainApplicationIdentifier(NSString *bundleIdentifier,
                                                 NSDictionary<NSString *, id> *entitlements,
                                                 NSArray<NSString *> *accessGroups) {
    NSString *applicationIdentifier = [entitlements[@"application-identifier"] isKindOfClass:[NSString class]]
        ? entitlements[@"application-identifier"]
        : nil;
    if (applicationIdentifier.length == 0) {
        applicationIdentifier = [entitlements[@"com.apple.application-identifier"] isKindOfClass:[NSString class]]
            ? entitlements[@"com.apple.application-identifier"]
            : nil;
    }
    NSString *expectedSuffix = [@"." stringByAppendingString:bundleIdentifier];
    if ([applicationIdentifier hasSuffix:expectedSuffix]) {
        return applicationIdentifier;
    }
    NSMutableArray<NSString *> *fallbacks = [NSMutableArray array];
    for (id accessGroup in accessGroups) {
        if ([accessGroup isKindOfClass:[NSString class]] &&
            [accessGroup hasSuffix:expectedSuffix]) {
            [fallbacks addObject:accessGroup];
        }
    }
    return fallbacks.count == 1 ? fallbacks.firstObject : nil;
}

+ (instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                            entitlements:(NSDictionary<NSString *, id> *)entitlements
              includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
                                   error:(NSError * _Nullable * _Nullable)error {
    return [self planForBundleIdentifier:bundleIdentifier
                            entitlements:entitlements
              includeSharedAccessGroups:includeSharedAccessGroups
              includeSynchronizableItems:NO
                                   error:error];
}

+ (instancetype)planForBundleIdentifier:(NSString *)bundleIdentifier
                            entitlements:(NSDictionary<NSString *, id> *)entitlements
              includeSharedAccessGroups:(BOOL)includeSharedAccessGroups
              includeSynchronizableItems:(BOOL)includeSynchronizableItems
                                   error:(NSError * _Nullable * _Nullable)error {
    NSArray<NSString *> *accessGroups = [entitlements[@"keychain-access-groups"] isKindOfClass:[NSArray class]]
        ? entitlements[@"keychain-access-groups"]
        : @[];
    NSString *applicationIdentifier = PXKeychainApplicationIdentifier(bundleIdentifier,
                                                                      entitlements,
                                                                      accessGroups);
    NSString *expectedSuffix = [@"." stringByAppendingString:bundleIdentifier];
    if (!PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO) ||
        applicationIdentifier.length <= expectedSuffix.length ||
        ![applicationIdentifier hasSuffix:expectedSuffix]) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorRejected,
                              @"Process application identifier is unavailable or inconsistent");
        return nil;
    }
    NSString *teamPrefix = [applicationIdentifier substringToIndex:
        applicationIdentifier.length - expectedSuffix.length];
    NSCharacterSet *unsafeTeamCharacters = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    if (teamPrefix.length == 0 ||
        [teamPrefix rangeOfCharacterFromSet:unsafeTeamCharacters].location != NSNotFound) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorRejected,
                              @"Process application identifier has an invalid team prefix");
        return nil;
    }
    NSMutableOrderedSet<NSString *> *approvedGroups = [NSMutableOrderedSet
        orderedSet];
    if ([accessGroups containsObject:applicationIdentifier]) {
        [approvedGroups addObject:applicationIdentifier];
    }
    NSMutableSet<NSString *> *sharedGroups = [NSMutableSet set];
    if (includeSharedAccessGroups) {
        for (id candidate in accessGroups) {
            if (![candidate isKindOfClass:[NSString class]] ||
                [candidate isEqualToString:applicationIdentifier] ||
                !PXKeychainAccessGroupHasSafeTeamPrefix(candidate, teamPrefix)) {
                continue;
            }
            [approvedGroups addObject:candidate];
            [sharedGroups addObject:candidate];
        }
    }
    if (approvedGroups.count == 0) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorRejected,
                              @"No signed Keychain access group is permitted for this request");
        return nil;
    }

    NSArray<NSString *> *keychainClasses = @[
        PXKeychainClassGenericPassword,
        PXKeychainClassInternetPassword,
        PXKeychainClassCertificate,
        PXKeychainClassKey,
        PXKeychainClassIdentity
    ];
    NSArray<NSNumber *> *synchronizableModes = includeSynchronizableItems
        ? @[@NO, @YES]
        : @[@NO];
    NSMutableArray<PXKeychainDeletionScope *> *scopes = [NSMutableArray array];
    for (NSString *accessGroup in approvedGroups) {
        for (NSString *keychainClass in keychainClasses) {
            for (NSNumber *synchronizableMode in synchronizableModes) {
                PXKeychainDeletionScope *scope = [[PXKeychainDeletionScope alloc] init];
                scope.keychainClass = keychainClass;
                scope.accessGroup = accessGroup;
                scope.synchronizable = synchronizableMode.boolValue;
                scope.sharedAccessGroup = [sharedGroups containsObject:accessGroup];
                [scopes addObject:scope];
            }
        }
    }
    PXKeychainDeletionPlan *plan = [[self alloc] init];
    plan.scopes = [scopes copy];
    plan.applicationIdentifier = applicationIdentifier;
    plan.sharedAccessGroups = [sharedGroups copy];
    return plan;
}

@end

@implementation PXKeychainCommandContext

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                profileID:(NSString *)profileID
                             generationID:(NSString *)generationID
                       applicationEnabled:(BOOL)applicationEnabled
                         extensionEnabled:(BOOL)extensionEnabled {
    self = [super init];
    if (self) {
        _bundleIdentifier = [bundleIdentifier copy];
        _profileID = [profileID copy];
        _generationID = [generationID copy];
        _applicationEnabled = applicationEnabled;
        _extensionEnabled = extensionEnabled;
    }
    return self;
}

@end

@interface PXKeychainCommandValidator ()

@property (nonatomic, strong) NSMutableSet<NSString *> *claimedRequestIDs;

@end

@implementation PXKeychainCommandValidator

- (instancetype)init {
    self = [super init];
    if (self) {
        _claimedRequestIDs = [NSMutableSet set];
    }
    return self;
}

- (BOOL)claimRequest:(PXKeychainCommandRequest *)request
             context:(PXKeychainCommandContext *)context
                 now:(NSDate *)now
               error:(NSError * _Nullable * _Nullable)error {
    if (!request || !context || !now ||
        ![request.targetBundleID isEqualToString:context.bundleIdentifier] ||
        [request.profileID caseInsensitiveCompare:context.profileID] != NSOrderedSame ||
        [request.generationID caseInsensitiveCompare:context.generationID] != NSOrderedSame ||
        !PXAppIdentityBundleIsEligible(context.bundleIdentifier,
                                       context.isApplicationEnabled,
                                       context.isExtensionEnabled)) {
        return PXKeychainCommandFail(error, PXKeychainCommandErrorRejected,
                                     @"Request target or active Profile context does not match");
    }
    NSTimeInterval lifetime = [request.expiresAt timeIntervalSinceDate:request.createdAt];
    if (lifetime <= 0 || lifetime > 60 || [now compare:request.createdAt] == NSOrderedAscending ||
        [now compare:request.expiresAt] == NSOrderedDescending) {
        return PXKeychainCommandFail(error, PXKeychainCommandErrorRejected,
                                     @"Request has expired or has an invalid lifetime");
    }
    @synchronized(self) {
        if ([self.claimedRequestIDs containsObject:request.requestID]) {
            return PXKeychainCommandFail(error, PXKeychainCommandErrorReplay,
                                         @"Request nonce was already claimed");
        }
        [self.claimedRequestIDs addObject:request.requestID];
    }
    return YES;
}

@end

@interface PXKeychainScopeResult ()

@property (nonatomic, copy, readwrite) NSString *keychainClass;
@property (nonatomic, copy, readwrite) NSString *accessGroup;
@property (nonatomic, assign, readwrite) NSUInteger beforeCount;
@property (nonatomic, assign, readwrite) NSUInteger deletedCount;
@property (nonatomic, assign, readwrite) NSUInteger remainingCount;
@property (nonatomic, assign, readwrite) int32_t queryStatus;
@property (nonatomic, assign, readwrite) int32_t deleteStatus;
@property (nonatomic, assign, readwrite) int32_t verificationStatus;
@property (nonatomic, assign, readwrite) BOOL skippedSynchronizable;
@property (nonatomic, assign, readwrite, getter=isSharedAccessGroup) BOOL sharedAccessGroup;
@property (nonatomic, assign, readwrite, getter=isSuccessful) BOOL successful;

@end


@implementation PXKeychainScopeResult

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{
        @"class": self.keychainClass,
        @"accessGroup": self.accessGroup,
        @"beforeCount": @(self.beforeCount),
        @"deletedCount": @(self.deletedCount),
        @"remainingCount": @(self.remainingCount),
        @"queryStatus": @(self.queryStatus),
        @"deleteStatus": @(self.deleteStatus),
        @"verificationStatus": @(self.verificationStatus),
        @"skippedSynchronizable": @(self.skippedSynchronizable),
        @"sharedAccessGroup": @(self.isSharedAccessGroup),
        @"success": @(self.isSuccessful)
    };
}

@end

@interface PXKeychainCommandResponse ()

@property (nonatomic, copy, readwrite) NSString *requestID;
@property (nonatomic, copy, readwrite) NSString *targetBundleID;
@property (nonatomic, copy, readwrite) NSArray<PXKeychainScopeResult *> *results;
@property (nonatomic, assign, readwrite, getter=isSuccessful) BOOL successful;
@property (nonatomic, copy, readwrite, nullable) NSString *failureCode;
@property (nonatomic, assign, readwrite) NSUInteger protectedSharedAccessGroupCount;

@end


@implementation PXKeychainCommandResponse

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    NSMutableArray<NSDictionary<NSString *, id> *> *serializedResults = [NSMutableArray array];
    for (PXKeychainScopeResult *result in self.results) {
        [serializedResults addObject:[result propertyListRepresentation]];
    }
    return @{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": self.requestID,
        @"targetBundleID": self.targetBundleID,
        @"success": @(self.isSuccessful),
        @"results": [serializedResults copy],
        @"failureCode": self.failureCode ?: @"",
        @"protectedSharedAccessGroupCount": @(self.protectedSharedAccessGroupCount)
    };
}

- (instancetype)responseByRecordingProtectedSharedAccessGroupCount:(NSUInteger)count {
    PXKeychainCommandResponse *response = [[PXKeychainCommandResponse alloc] init];
    response.requestID = self.requestID;
    response.targetBundleID = self.targetBundleID;
    response.results = self.results;
    response.successful = self.isSuccessful;
    response.failureCode = self.failureCode;
    response.protectedSharedAccessGroupCount = count;
    return response;
}

+ (instancetype)responseWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                    error:(NSError * _Nullable * _Nullable)error {
    NSSet<NSString *> *allowedResponseKeys = [NSSet setWithArray:@[
        @"schemaVersion", @"requestID", @"targetBundleID", @"success", @"results", @"failureCode",
        @"protectedSharedAccessGroupCount"
    ]];
    if (![propertyList isKindOfClass:[NSDictionary class]] ||
        ![[NSSet setWithArray:propertyList.allKeys] isSubsetOfSet:allowedResponseKeys]) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorInvalidRequest,
                              @"Response contains unsupported fields");
        return nil;
    }
    NSArray *storedResults = [propertyList[@"results"] isKindOfClass:[NSArray class]]
        ? propertyList[@"results"]
        : nil;
    NSString *requestID = propertyList[@"requestID"];
    NSString *targetBundleID = propertyList[@"targetBundleID"];
    NSNumber *protectedSharedAccessGroupCount = propertyList[@"protectedSharedAccessGroupCount"];
    if ([propertyList[@"schemaVersion"] integerValue] != PXKeychainCommandSchemaVersion ||
        !PXKeychainCommandIsUUID(requestID) || targetBundleID.length == 0 || !storedResults) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorInvalidRequest,
                              @"Response fields are incomplete or invalid");
        return nil;
    }
    if (protectedSharedAccessGroupCount &&
        (![protectedSharedAccessGroupCount isKindOfClass:[NSNumber class]] ||
         protectedSharedAccessGroupCount.longLongValue < 0 ||
         protectedSharedAccessGroupCount.doubleValue !=
             (double)protectedSharedAccessGroupCount.unsignedLongLongValue)) {
        PXKeychainCommandFail(error, PXKeychainCommandErrorInvalidRequest,
                              @"Response protected-group metadata is invalid");
        return nil;
    }
    NSMutableArray<PXKeychainScopeResult *> *results = [NSMutableArray array];
    NSSet<NSString *> *allowedResultKeys = [NSSet setWithArray:@[
        @"class", @"accessGroup", @"beforeCount", @"deletedCount", @"remainingCount", @"queryStatus",
        @"deleteStatus", @"verificationStatus", @"skippedSynchronizable", @"sharedAccessGroup", @"success"
    ]];
    NSSet<NSString *> *allowedClasses = [NSSet setWithArray:@[
        PXKeychainClassGenericPassword, PXKeychainClassInternetPassword,
        PXKeychainClassCertificate, PXKeychainClassKey, PXKeychainClassIdentity
    ]];
    for (id value in storedResults) {
        if (![value isKindOfClass:[NSDictionary class]] ||
            ![[NSSet setWithArray:[value allKeys]] isSubsetOfSet:allowedResultKeys] ||
            ![value[@"class"] isKindOfClass:[NSString class]] ||
            ![allowedClasses containsObject:value[@"class"]] ||
            ![value[@"accessGroup"] isKindOfClass:[NSString class]] ||
            [value[@"accessGroup"] length] == 0 ||
            ![value[@"beforeCount"] isKindOfClass:[NSNumber class]] ||
            ![value[@"deletedCount"] isKindOfClass:[NSNumber class]] ||
            ![value[@"remainingCount"] isKindOfClass:[NSNumber class]] ||
            ![value[@"queryStatus"] isKindOfClass:[NSNumber class]] ||
            ![value[@"deleteStatus"] isKindOfClass:[NSNumber class]] ||
            ![value[@"verificationStatus"] isKindOfClass:[NSNumber class]] ||
            ![value[@"skippedSynchronizable"] isKindOfClass:[NSNumber class]] ||
            ![value[@"sharedAccessGroup"] isKindOfClass:[NSNumber class]] ||
            ![value[@"success"] isKindOfClass:[NSNumber class]]) {
            PXKeychainCommandFail(error, PXKeychainCommandErrorInvalidRequest,
                                  @"Response contains an invalid scope result");
            return nil;
        }
        PXKeychainScopeResult *result = [[PXKeychainScopeResult alloc] init];
        result.keychainClass = value[@"class"];
        result.accessGroup = value[@"accessGroup"];
        result.beforeCount = [value[@"beforeCount"] unsignedIntegerValue];
        result.deletedCount = [value[@"deletedCount"] unsignedIntegerValue];
        result.remainingCount = [value[@"remainingCount"] unsignedIntegerValue];
        result.queryStatus = [value[@"queryStatus"] intValue];
        result.deleteStatus = [value[@"deleteStatus"] intValue];
        result.verificationStatus = [value[@"verificationStatus"] intValue];
        result.skippedSynchronizable = [value[@"skippedSynchronizable"] boolValue];
        result.sharedAccessGroup = [value[@"sharedAccessGroup"] boolValue];
        BOOL querySucceeded = result.queryStatus == PXKeychainStatusSuccess ||
            result.queryStatus == PXKeychainStatusItemNotFound;
        BOOL deleteSucceeded = result.deleteStatus == PXKeychainStatusSuccess ||
            result.deleteStatus == PXKeychainStatusItemNotFound;
        result.successful = querySucceeded && deleteSucceeded &&
            PXKeychainStatusAllowsEmptyResult(result.verificationStatus, result.remainingCount) &&
            [value[@"success"] boolValue];
        [results addObject:result];
    }
    PXKeychainCommandResponse *response = [[self alloc] init];
    response.requestID = requestID.lowercaseString;
    response.targetBundleID = targetBundleID;
    response.results = [results copy];
    BOOL calculatedSuccess = results.count > 0;
    for (PXKeychainScopeResult *result in results) {
        calculatedSuccess = calculatedSuccess && result.isSuccessful;
    }
    response.successful = calculatedSuccess && [propertyList[@"success"] boolValue];
    NSString *failureCode = propertyList[@"failureCode"];
    response.failureCode = [failureCode isKindOfClass:[NSString class]] && failureCode.length > 0
        ? failureCode
        : nil;
    response.protectedSharedAccessGroupCount =
        protectedSharedAccessGroupCount.unsignedIntegerValue;
    return response;
}

+ (instancetype)failureResponseForRequest:(PXKeychainCommandRequest *)request
                                      code:(NSString *)code {
    return [self failureResponseForRequestID:request.requestID
                              targetBundleID:request.targetBundleID
                                        code:code];
}

+ (instancetype)failureResponseForRequestID:(NSString *)requestID
                             targetBundleID:(NSString *)targetBundleID
                                       code:(NSString *)code {
    PXKeychainCommandResponse *response = [[self alloc] init];
    response.requestID = requestID.lowercaseString;
    response.targetBundleID = targetBundleID;
    response.results = @[];
    response.successful = NO;
    response.failureCode = code.length > 0 ? code : @"rejected";
    return response;
}

@end

@interface PXKeychainCommandExecutor ()

@property (nonatomic, strong) PXKeychainCommandValidator *validator;
@property (nonatomic, strong) id<PXKeychainSecurityAdapter> securityAdapter;

@end


@implementation PXKeychainCommandExecutor

- (instancetype)initWithValidator:(PXKeychainCommandValidator *)validator
                   securityAdapter:(id<PXKeychainSecurityAdapter>)securityAdapter {
    self = [super init];
    if (self) {
        _validator = validator;
        _securityAdapter = securityAdapter;
    }
    return self;
}

- (PXKeychainCommandResponse *)executeRequest:(PXKeychainCommandRequest *)request
                                      context:(PXKeychainCommandContext *)context
                                          now:(NSDate *)now
                                        error:(NSError * _Nullable * _Nullable)error {
    if (![self.validator claimRequest:request context:context now:now error:error]) {
        return nil;
    }
    NSDictionary<NSString *, id> *entitlements = [self.securityAdapter
        entitlementsForBundleIdentifier:context.bundleIdentifier
        error:error];
    if (!entitlements) {
        return nil;
    }
    PXKeychainDeletionPlan *plan = [PXKeychainDeletionPlan
        planForBundleIdentifier:context.bundleIdentifier
                   entitlements:entitlements
     includeSharedAccessGroups:request.includesSharedAccessGroups
     includeSynchronizableItems:request.includesSynchronizableItems
                          error:error];
    if (!plan) {
        return nil;
    }

    BOOL allSuccessful = YES;
    NSMutableArray<PXKeychainScopeResult *> *results = [NSMutableArray array];
    for (PXKeychainDeletionScope *scope in plan.scopes) {
        BOOL synchronizable = scope.isSynchronizable;
        int32_t queryStatus = PXKeychainStatusItemNotFound;
        NSUInteger beforeCount = [self.securityAdapter
            countItemsForClass:scope.keychainClass
            accessGroup:scope.accessGroup
            synchronizable:synchronizable
            status:&queryStatus];
        int32_t deleteStatus = queryStatus;
        if (queryStatus == PXKeychainStatusSuccess || queryStatus == PXKeychainStatusItemNotFound) {
            deleteStatus = [self.securityAdapter deleteItemsForClass:scope.keychainClass
                                                         accessGroup:scope.accessGroup
                                                      synchronizable:synchronizable];
        }
        int32_t verificationStatus = PXKeychainStatusItemNotFound;
        NSUInteger remainingCount = [self.securityAdapter
            countItemsForClass:scope.keychainClass
            accessGroup:scope.accessGroup
            synchronizable:synchronizable
            status:&verificationStatus];
        BOOL querySucceeded = queryStatus == PXKeychainStatusSuccess ||
            queryStatus == PXKeychainStatusItemNotFound;
        BOOL deleteSucceeded = deleteStatus == PXKeychainStatusSuccess ||
            deleteStatus == PXKeychainStatusItemNotFound;
        BOOL successful = querySucceeded && deleteSucceeded &&
            PXKeychainStatusAllowsEmptyResult(verificationStatus, remainingCount);

        PXKeychainScopeResult *result = [[PXKeychainScopeResult alloc] init];
        result.keychainClass = scope.keychainClass;
        result.accessGroup = scope.accessGroup;
        result.beforeCount = beforeCount;
        result.deletedCount = successful && beforeCount >= remainingCount
            ? beforeCount - remainingCount
            : 0;
        result.remainingCount = remainingCount;
        result.queryStatus = queryStatus;
        result.deleteStatus = deleteStatus;
        result.verificationStatus = verificationStatus;
        result.skippedSynchronizable = !synchronizable;
        result.sharedAccessGroup = scope.isSharedAccessGroup;
        result.successful = successful;
        [results addObject:result];
        allSuccessful = allSuccessful && successful;
    }

    PXKeychainCommandResponse *response = [[PXKeychainCommandResponse alloc] init];
    response.requestID = request.requestID;
    response.targetBundleID = request.targetBundleID;
    response.results = [results copy];
    response.successful = allSuccessful && results.count > 0;
    return response;
}

@end

@interface PXKeychainCommandController ()

@property (nonatomic, strong) id<PXKeychainCommandTransport> transport;
@property (nonatomic, strong) id<PXKeychainAppLifecycle> lifecycle;
@property (nonatomic, assign) NSTimeInterval readyTimeout;
@property (nonatomic, assign) NSTimeInterval responseTimeout;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
@property (nonatomic, strong) dispatch_queue_t stateQueue;

@end


@implementation PXKeychainCommandController

- (instancetype)initWithTransport:(id<PXKeychainCommandTransport>)transport
                         lifecycle:(id<PXKeychainAppLifecycle>)lifecycle
                      readyTimeout:(NSTimeInterval)readyTimeout
                   responseTimeout:(NSTimeInterval)responseTimeout
                   completionQueue:(dispatch_queue_t)completionQueue {
    self = [super init];
    if (self) {
        _transport = transport;
        _lifecycle = lifecycle;
        _readyTimeout = readyTimeout;
        _responseTimeout = responseTimeout;
        _completionQueue = completionQueue;
        _stateQueue = dispatch_queue_create("com.hydra.projectx.keychain-command-state",
                                            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSError *)controllerErrorWithReason:(NSString *)reason {
    return [NSError errorWithDomain:PXKeychainCommandErrorDomain
                               code:PXKeychainCommandErrorRejected
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

- (void)finishWithResponse:(PXKeychainCommandResponse *)response
                      error:(NSError *)error
                 completion:(void (^)(PXKeychainCommandResponse *, NSError *))completion {
    dispatch_async(self.completionQueue, ^{
        completion(response, error);
    });
}

- (void)executeRequest:(PXKeychainCommandRequest *)request
             completion:(void (^)(PXKeychainCommandResponse *, NSError *))completion {
    if (!request || !completion || self.readyTimeout <= 0 || self.responseTimeout <= 0) {
        if (completion) {
            [self finishWithResponse:nil
                               error:[self controllerErrorWithReason:@"Controller request or timeout is invalid"]
                          completion:completion];
        }
        return;
    }
    dispatch_async(self.stateQueue, ^{
        [self.lifecycle ensureRunningBundleIdentifier:request.targetBundleID
                                           completion:^(BOOL running, NSError *launchError) {
            dispatch_async(self.stateQueue, ^{
                if (!running || launchError) {
                    [self finishWithResponse:nil
                                       error:launchError ?: [self controllerErrorWithReason:@"Target App launch failed"]
                                  completion:completion];
                    return;
                }
                [self.transport waitForReadyBundleIdentifier:request.targetBundleID
                                                   profileID:request.profileID
                                                generationID:request.generationID
                                                     timeout:self.readyTimeout
                                                  completion:^(BOOL ready, NSError *readyError) {
                    dispatch_async(self.stateQueue, ^{
                        if (!ready || readyError) {
                            [self finishWithResponse:nil
                                               error:readyError ?: [self controllerErrorWithReason:@"Target observer readiness timed out"]
                                          completion:completion];
                            return;
                        }
                        [self.transport sendRequest:request
                                           timeout:self.responseTimeout
                                        completion:^(PXKeychainCommandResponse *response,
                                                     NSError *responseError) {
                            dispatch_async(self.stateQueue, ^{
                                BOOL responseMatches = response &&
                                    [response.requestID caseInsensitiveCompare:request.requestID] == NSOrderedSame &&
                                    [response.targetBundleID isEqualToString:request.targetBundleID];
                                if (!responseMatches || !response.isSuccessful || responseError) {
                                    [self finishWithResponse:response
                                                       error:responseError ?: [self controllerErrorWithReason:
                                                           responseMatches
                                                               ? @"Target reported partial Keychain deletion or verification failure"
                                                               : @"Target response did not match the request"]
                                                  completion:completion];
                                    return;
                                }
                                [self.lifecycle terminateBundleIdentifier:request.targetBundleID
                                                                completion:^(BOOL terminated,
                                                                             NSError *terminationError) {
                                    dispatch_async(self.stateQueue, ^{
                                        if (!terminated || terminationError) {
                                            [self finishWithResponse:nil
                                                               error:terminationError ?: [self controllerErrorWithReason:@"Target App termination failed"]
                                                          completion:completion];
                                            return;
                                        }
                                        [self finishWithResponse:response error:nil completion:completion];
                                    });
                                }];
                            });
                        }];
                    });
                }];
            });
        }];
    });
}

@end

@interface PXKeychainCommandFileStore ()

@property (nonatomic, copy) NSString *rootDirectory;

@end


@implementation PXKeychainCommandFileStore

- (instancetype)initWithRootDirectory:(NSString *)rootDirectory {
    self = [super init];
    if (self) {
        _rootDirectory = [rootDirectory.stringByStandardizingPath copy];
    }
    return self;
}

- (BOOL)failFileOperation:(NSError * _Nullable * _Nullable)error
                     code:(NSInteger)code
                   reason:(NSString *)reason {
    if (error) {
        *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

- (NSArray<NSString *> *)directoryNames {
    return @[@"requests", @"responses", @"claims", @"readiness"];
}

- (NSString *)directoryPath:(NSString *)name {
    return [[self directoryNames] containsObject:name]
        ? [self.rootDirectory stringByAppendingPathComponent:name]
        : nil;
}

- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error {
    if (![self.rootDirectory isAbsolutePath]) {
        return [self failFileOperation:error code:PXKeychainCommandErrorInvalidRequest
                                reason:@"Command root directory is invalid"];
    }
    NSArray<NSString *> *paths = @[
        self.rootDirectory,
        [self directoryPath:@"requests"],
        [self directoryPath:@"responses"],
        [self directoryPath:@"claims"],
        [self directoryPath:@"readiness"]
    ];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        struct stat pathInfo;
        if (lstat(path.fileSystemRepresentation, &pathInfo) == 0 &&
            (!S_ISDIR(pathInfo.st_mode) || S_ISLNK(pathInfo.st_mode))) {
            return [self failFileOperation:error code:PXKeychainCommandErrorRejected
                                    reason:@"Command directory cannot be a symbolic link"];
        }
        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory) {
            return [self failFileOperation:error code:PXKeychainCommandErrorRejected
                                    reason:@"Command path is not a directory"];
        }
        NSError *directoryError = nil;
        if (![fileManager createDirectoryAtPath:path
                    withIntermediateDirectories:YES
                                     attributes:@{NSFilePosixPermissions: @0700}
                                          error:&directoryError]) {
            if (error) *error = directoryError;
            return NO;
        }
        if (lstat(path.fileSystemRepresentation, &pathInfo) != 0 ||
            !S_ISDIR(pathInfo.st_mode) || S_ISLNK(pathInfo.st_mode)) {
            return [self failFileOperation:error code:PXKeychainCommandErrorRejected
                                    reason:@"Command directory validation failed"];
        }
        if (chmod(path.fileSystemRepresentation, 0700) != 0) {
            return [self failFileOperation:error code:errno
                                    reason:@"Unable to restrict command directory permissions"];
        }
    }
    return YES;
}

static BOOL PXKeychainCommandIsSafeBundleIdentifier(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0 || [bundleIdentifier hasPrefix:@"."] ||
        [bundleIdentifier hasSuffix:@"."] || [bundleIdentifier containsString:@".."] ||
        [bundleIdentifier containsString:@"/"]) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    return [bundleIdentifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

- (NSString *)requestLeafName:(NSString *)requestID {
    return PXKeychainCommandIsUUID(requestID)
        ? [requestID.lowercaseString stringByAppendingPathExtension:@"plist"]
        : nil;
}

- (NSString *)readinessLeafName:(NSString *)bundleIdentifier {
    return PXKeychainCommandIsSafeBundleIdentifier(bundleIdentifier)
        ? [bundleIdentifier stringByAppendingPathExtension:@"plist"]
        : nil;
}

- (BOOL)writePropertyList:(NSDictionary<NSString *, id> *)propertyList
                directory:(NSString *)directory
                  leafName:(NSString *)leafName
                     error:(NSError * _Nullable * _Nullable)error {
    if (![self prepareWithError:error] || leafName.length == 0) {
        return NO;
    }
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:propertyList
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&serializationError];
    if (!data) {
        if (error) *error = serializationError;
        return NO;
    }
    NSString *directoryPath = [self directoryPath:directory];
    NSString *destinationPath = [directoryPath stringByAppendingPathComponent:leafName];
    NSString *temporaryPath = [directoryPath stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.tmp", leafName, NSUUID.UUID.UUIDString.lowercaseString]];
    NSError *writeError = nil;
    if (![data writeToFile:temporaryPath options:0 error:&writeError]) {
        if (error) *error = writeError;
        return NO;
    }
    if (chmod(temporaryPath.fileSystemRepresentation, 0600) != 0 ||
        rename(temporaryPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation) != 0) {
        int operationError = errno;
        [[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
        return [self failFileOperation:error code:operationError
                                reason:@"Unable to atomically publish command file"];
    }
    return YES;
}

- (BOOL)writeRequest:(PXKeychainCommandRequest *)request
               error:(NSError * _Nullable * _Nullable)error {
    NSString *leafName = [self requestLeafName:request.requestID];
    if (!leafName) {
        return [self failFileOperation:error code:PXKeychainCommandErrorInvalidRequest
                                reason:@"Request ID is invalid"];
    }
    return [self writePropertyList:[request propertyListRepresentation]
                         directory:@"requests"
                           leafName:leafName
                              error:error];
}

- (NSArray<PXKeychainCommandRequest *> *)pendingRequestsWithError:(NSError * _Nullable * _Nullable)error {
    if (![self prepareWithError:error]) {
        return @[];
    }
    NSString *requestsDirectory = [self directoryPath:@"requests"];
    NSError *listingError = nil;
    NSArray<NSString *> *leafNames = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:requestsDirectory
        error:&listingError];
    if (!leafNames) {
        if (error) *error = listingError;
        return @[];
    }
    NSMutableArray<PXKeychainCommandRequest *> *requests = [NSMutableArray array];
    for (NSString *leafName in [leafNames sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *requestID = leafName.stringByDeletingPathExtension;
        if (![[self requestLeafName:requestID] isEqualToString:leafName]) {
            continue;
        }
        NSString *path = [requestsDirectory stringByAppendingPathComponent:leafName];
        struct stat requestInfo;
        if (lstat(path.fileSystemRepresentation, &requestInfo) != 0 ||
            !S_ISREG(requestInfo.st_mode) || S_ISLNK(requestInfo.st_mode)) {
            continue;
        }
        NSDictionary<NSString *, id> *propertyList = [NSDictionary dictionaryWithContentsOfFile:path];
        PXKeychainCommandRequest *request = [PXKeychainCommandRequest
            requestWithPropertyList:propertyList
            error:nil];
        if (request && [request.requestID isEqualToString:requestID.lowercaseString]) {
            [requests addObject:request];
        }
    }
    return [requests copy];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)rejectedRequestHeadersWithError:(NSError * _Nullable * _Nullable)error {
    if (![self prepareWithError:error]) {
        return @[];
    }
    NSString *requestsDirectory = [self directoryPath:@"requests"];
    NSError *listingError = nil;
    NSArray<NSString *> *leafNames = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:requestsDirectory
        error:&listingError];
    if (!leafNames) {
        if (error) *error = listingError;
        return @[];
    }
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *headers = [NSMutableArray array];
    for (NSString *leafName in leafNames) {
        NSString *requestID = leafName.stringByDeletingPathExtension;
        if (![[self requestLeafName:requestID] isEqualToString:leafName]) {
            continue;
        }
        NSString *path = [requestsDirectory stringByAppendingPathComponent:leafName];
        struct stat requestInfo;
        if (lstat(path.fileSystemRepresentation, &requestInfo) != 0 ||
            !S_ISREG(requestInfo.st_mode) || S_ISLNK(requestInfo.st_mode)) {
            continue;
        }
        NSDictionary<NSString *, id> *propertyList = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([PXKeychainCommandRequest requestWithPropertyList:propertyList error:nil]) {
            continue;
        }
        NSString *storedRequestID = propertyList[@"requestID"];
        NSString *targetBundleID = propertyList[@"targetBundleID"];
        if ([storedRequestID isKindOfClass:[NSString class]] &&
            [storedRequestID caseInsensitiveCompare:requestID] == NSOrderedSame &&
            PXKeychainCommandIsSafeBundleIdentifier(targetBundleID)) {
            [headers addObject:@{
                @"requestID": requestID.lowercaseString,
                @"targetBundleID": targetBundleID
            }];
        }
    }
    return [headers copy];
}

- (BOOL)claimRequestID:(NSString *)requestID
                 error:(NSError * _Nullable * _Nullable)error {
    if (![self prepareWithError:error]) {
        return NO;
    }
    NSString *leafName = [self requestLeafName:requestID];
    if (!leafName) {
        return [self failFileOperation:error code:PXKeychainCommandErrorInvalidRequest
                                reason:@"Request claim ID is invalid"];
    }
    NSString *claimPath = [[self directoryPath:@"claims"] stringByAppendingPathComponent:leafName];
    int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    int descriptor = open(claimPath.fileSystemRepresentation, flags, 0600);
    if (descriptor < 0) {
        return [self failFileOperation:error code:errno
                                reason:errno == EEXIST
                                    ? @"Request was already claimed"
                                    : @"Unable to claim request"];
    }
    close(descriptor);
    return YES;
}

- (BOOL)isRequestIDClaimed:(NSString *)requestID {
    NSString *leafName = [self requestLeafName:requestID];
    if (!leafName) {
        return NO;
    }
    NSString *claimPath = [[self directoryPath:@"claims"] stringByAppendingPathComponent:leafName];
    struct stat claimInfo;
    return lstat(claimPath.fileSystemRepresentation, &claimInfo) == 0 &&
        S_ISREG(claimInfo.st_mode) && !S_ISLNK(claimInfo.st_mode);
}

- (BOOL)markRequestIDCompleted:(NSString *)requestID
                         error:(NSError * _Nullable * _Nullable)error {
    NSString *leafName = [self requestLeafName:requestID];
    if (!leafName || ![self isRequestIDClaimed:requestID]) {
        return [self failFileOperation:error code:PXKeychainCommandErrorRejected
                                reason:@"Only a claimed request can be completed"];
    }
    return [self writePropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"requestID": requestID.lowercaseString,
        @"completed": @YES,
        @"completedAt": [NSDate date]
    } directory:@"claims" leafName:leafName error:error];
}

- (BOOL)isRequestIDCompleted:(NSString *)requestID {
    NSString *leafName = [self requestLeafName:requestID];
    if (!leafName || ![self isRequestIDClaimed:requestID]) {
        return NO;
    }
    NSString *claimPath = [[self directoryPath:@"claims"] stringByAppendingPathComponent:leafName];
    NSDictionary<NSString *, id> *claim = [NSDictionary dictionaryWithContentsOfFile:claimPath];
    return [claim[@"schemaVersion"] integerValue] == PXKeychainCommandSchemaVersion &&
        [claim[@"requestID"] isEqualToString:requestID.lowercaseString] &&
        [claim[@"completed"] boolValue];
}

- (BOOL)writeResponse:(PXKeychainCommandResponse *)response
                 error:(NSError * _Nullable * _Nullable)error {
    NSString *leafName = [self requestLeafName:response.requestID];
    if (!leafName) {
        return [self failFileOperation:error code:PXKeychainCommandErrorInvalidRequest
                                reason:@"Response request ID is invalid"];
    }
    return [self writePropertyList:[response propertyListRepresentation]
                         directory:@"responses"
                           leafName:leafName
                              error:error];
}

- (PXKeychainCommandResponse *)responseForRequestID:(NSString *)requestID
                                               error:(NSError * _Nullable * _Nullable)error {
    NSString *leafName = [self requestLeafName:requestID];
    if (![self prepareWithError:error] || !leafName) {
        return nil;
    }
    NSString *path = [[self directoryPath:@"responses"] stringByAppendingPathComponent:leafName];
    struct stat responseInfo;
    if (lstat(path.fileSystemRepresentation, &responseInfo) != 0 ||
        !S_ISREG(responseInfo.st_mode) || S_ISLNK(responseInfo.st_mode)) {
        return nil;
    }
    NSDictionary<NSString *, id> *propertyList = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!propertyList) {
        return nil;
    }
    PXKeychainCommandResponse *response = [PXKeychainCommandResponse
        responseWithPropertyList:propertyList
        error:error];
    return [response.requestID isEqualToString:requestID.lowercaseString] ? response : nil;
}

- (BOOL)writeReadinessForBundleIdentifier:(NSString *)bundleIdentifier
                                 profileID:(NSString *)profileID
                              generationID:(NSString *)generationID
                                       now:(NSDate *)now
                                     error:(NSError * _Nullable * _Nullable)error {
    NSString *leafName = [self readinessLeafName:bundleIdentifier];
    if (!leafName || !PXKeychainCommandIsUUID(profileID) ||
        !PXKeychainCommandIsUUID(generationID) || !now) {
        return [self failFileOperation:error code:PXKeychainCommandErrorInvalidRequest
                                reason:@"Readiness context is invalid"];
    }
    return [self writePropertyList:@{
        @"schemaVersion": @(PXKeychainCommandSchemaVersion),
        @"bundleIdentifier": bundleIdentifier,
        @"profileID": profileID.lowercaseString,
        @"generationID": generationID.lowercaseString,
        @"readyAt": now
    } directory:@"readiness" leafName:leafName error:error];
}

- (BOOL)isReadyBundleIdentifier:(NSString *)bundleIdentifier
                      profileID:(NSString *)profileID
                   generationID:(NSString *)generationID
                            now:(NSDate *)now
                    maximumAge:(NSTimeInterval)maximumAge {
    NSString *leafName = [self readinessLeafName:bundleIdentifier];
    if (!leafName || maximumAge <= 0 || !now) {
        return NO;
    }
    NSString *path = [[self directoryPath:@"readiness"] stringByAppendingPathComponent:leafName];
    struct stat readinessInfo;
    if (lstat(path.fileSystemRepresentation, &readinessInfo) != 0 ||
        !S_ISREG(readinessInfo.st_mode) || S_ISLNK(readinessInfo.st_mode)) {
        return NO;
    }
    NSDictionary<NSString *, id> *readiness = [NSDictionary dictionaryWithContentsOfFile:path];
    NSDate *readyAt = readiness[@"readyAt"];
    NSTimeInterval age = [readyAt isKindOfClass:[NSDate class]] ? [now timeIntervalSinceDate:readyAt] : -1;
    return [readiness[@"schemaVersion"] integerValue] == PXKeychainCommandSchemaVersion &&
        [readiness[@"bundleIdentifier"] isEqualToString:bundleIdentifier] &&
        [readiness[@"profileID"] caseInsensitiveCompare:profileID] == NSOrderedSame &&
        [readiness[@"generationID"] caseInsensitiveCompare:generationID] == NSOrderedSame &&
        age >= 0 && age <= maximumAge;
}

- (void)removeTransactionForRequestID:(NSString *)requestID {
    NSString *leafName = [self requestLeafName:requestID];
    if (!leafName) {
        return;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *directory in @[@"requests", @"responses"]) {
        NSString *path = [[self directoryPath:directory] stringByAppendingPathComponent:leafName];
        [fileManager removeItemAtPath:path error:nil];
    }
}

@end

@interface PXKeychainFileTransport ()

@property (nonatomic, strong) PXKeychainCommandFileStore *fileStore;
@property (nonatomic, strong) dispatch_queue_t pollingQueue;

@end


@implementation PXKeychainFileTransport

- (instancetype)initWithFileStore:(PXKeychainCommandFileStore *)fileStore
                       pollingQueue:(dispatch_queue_t)pollingQueue {
    self = [super init];
    if (self) {
        _fileStore = fileStore;
        _pollingQueue = pollingQueue;
    }
    return self;
}

- (NSError *)timeoutError:(NSString *)reason {
    return [NSError errorWithDomain:PXKeychainCommandErrorDomain
                               code:PXKeychainCommandErrorRejected
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

- (void)pollReadinessForBundleIdentifier:(NSString *)bundleIdentifier
                                profileID:(NSString *)profileID
                             generationID:(NSString *)generationID
                                 deadline:(NSDate *)deadline
                               completion:(void (^)(BOOL, NSError *))completion {
    if ([self.fileStore isReadyBundleIdentifier:bundleIdentifier
                                      profileID:profileID
                                   generationID:generationID
                                            now:[NSDate date]
                                    maximumAge:60]) {
        completion(YES, nil);
        return;
    }
    if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
        completion(NO, [self timeoutError:@"Target observer readiness timed out"]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   self.pollingQueue, ^{
        [self pollReadinessForBundleIdentifier:bundleIdentifier
                                     profileID:profileID
                                  generationID:generationID
                                      deadline:deadline
                                    completion:completion];
    });
}

- (void)waitForReadyBundleIdentifier:(NSString *)bundleIdentifier
                            profileID:(NSString *)profileID
                         generationID:(NSString *)generationID
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(self.pollingQueue, ^{
        NSError *prepareError = nil;
        if (![self.fileStore prepareWithError:&prepareError]) {
            completion(NO, prepareError);
            return;
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)PXKeychainCommandProbeNotification,
                                             NULL,
                                             NULL,
                                             YES);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        [self pollReadinessForBundleIdentifier:bundleIdentifier
                                     profileID:profileID
                                  generationID:generationID
                                      deadline:deadline
                                    completion:completion];
    });
}

- (void)pollResponseForRequest:(PXKeychainCommandRequest *)request
                       deadline:(NSDate *)deadline
                     completion:(void (^)(PXKeychainCommandResponse *, NSError *))completion {
    NSError *readError = nil;
    PXKeychainCommandResponse *response = [self.fileStore
        responseForRequestID:request.requestID
        error:&readError];
    if (response || readError) {
        [self.fileStore removeTransactionForRequestID:request.requestID];
        completion(response, readError);
        return;
    }
    if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
        [self.fileStore removeTransactionForRequestID:request.requestID];
        completion(nil, [self timeoutError:@"Target Keychain response timed out"]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   self.pollingQueue, ^{
        [self pollResponseForRequest:request deadline:deadline completion:completion];
    });
}

- (void)sendRequest:(PXKeychainCommandRequest *)request
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(PXKeychainCommandResponse *, NSError *))completion {
    dispatch_async(self.pollingQueue, ^{
        NSError *writeError = nil;
        if ([self.fileStore isRequestIDClaimed:request.requestID]) {
            completion(nil, [self timeoutError:@"Request nonce was already claimed"]);
            return;
        }
        if (![self.fileStore writeRequest:request error:&writeError]) {
            completion(nil, writeError);
            return;
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)PXKeychainCommandRequestNotification,
                                             NULL,
                                             NULL,
                                             YES);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        [self pollResponseForRequest:request deadline:deadline completion:completion];
    });
}

@end
