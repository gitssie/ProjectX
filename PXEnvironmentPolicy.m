#import "PXEnvironmentPolicy.h"

#import "GraphicsIdentity.h"
#import "PXRootHidePath.h"
#import <math.h>

NSString * const PXEnvironmentPolicyErrorDomain = @"com.hydra.projectx.environment-policy";

static NSString *const PXEnvironmentPolicyFileName = @"com.hydra.projectx.pending-environment.plist";
static NSString *const PXEnvironmentPolicyLocationSet = @"set";
static NSString *const PXEnvironmentPolicyLocationCleared = @"cleared";
static NSString *const PXEnvironmentPolicyModelModeCustom = @"custom";
static NSString *const PXEnvironmentPolicyModelModePhysical = @"physical";

NSString *PXEnvironmentNetworkTypeIdentifier(PXEnvironmentNetworkType networkType) {
    switch (networkType) {
        case PXEnvironmentNetworkTypeWiFi: return @"wifi";
        case PXEnvironmentNetworkType5GNR: return @"5g-nr";
        case PXEnvironmentNetworkType4GLTE: return @"4g-lte";
        case PXEnvironmentNetworkType3G: return @"3g";
        case PXEnvironmentNetworkType2G: return @"2g";
        case PXEnvironmentNetworkTypeNone: return @"none";
        case PXEnvironmentNetworkTypeUnspecified: return @"unspecified";
    }
}

PXEnvironmentNetworkType PXEnvironmentNetworkTypeFromIdentifier(NSString *identifier) {
    if ([identifier isEqualToString:@"wifi"]) return PXEnvironmentNetworkTypeWiFi;
    if ([identifier isEqualToString:@"5g-nr"]) return PXEnvironmentNetworkType5GNR;
    if ([identifier isEqualToString:@"4g-lte"]) return PXEnvironmentNetworkType4GLTE;
    if ([identifier isEqualToString:@"3g"]) return PXEnvironmentNetworkType3G;
    if ([identifier isEqualToString:@"2g"]) return PXEnvironmentNetworkType2G;
    if ([identifier isEqualToString:@"none"]) return PXEnvironmentNetworkTypeNone;
    return PXEnvironmentNetworkTypeUnspecified;
}

BOOL PXEnvironmentNetworkTypeIsCompatibleWithModelRecord(
    PXEnvironmentNetworkType networkType,
    NSDictionary<NSString *, id> *modelRecord
) {
    if (networkType < PXEnvironmentNetworkTypeWiFi ||
        networkType > PXEnvironmentNetworkTypeNone) {
        return NO;
    }
    if (networkType != PXEnvironmentNetworkType5GNR) {
        return YES;
    }
    return [modelRecord[@"supports5G"] isKindOfClass:[NSNumber class]] &&
        [modelRecord[@"supports5G"] boolValue];
}

BOOL PXEnvironmentAppliedStateIsReady(
    BOOL hasPendingChanges,
    NSString *lastAppliedGenerationID,
    NSString *activeGenerationID,
    NSSet<NSString *> *selectedTargetBundleIdentifiers,
    NSSet<NSString *> *activeTargetBundleIdentifiers
) {
    if (hasPendingChanges || selectedTargetBundleIdentifiers.count == 0 ||
        ![[NSUUID alloc] initWithUUIDString:lastAppliedGenerationID] ||
        ![[NSUUID alloc] initWithUUIDString:activeGenerationID] ||
        [lastAppliedGenerationID caseInsensitiveCompare:activeGenerationID] != NSOrderedSame) {
        return NO;
    }
    return [selectedTargetBundleIdentifiers isEqualToSet:activeTargetBundleIdentifiers];
}

BOOL PXEnvironmentAllowsApplicationIdentityEnsure(
    NSString *bundleIdentifier,
    BOOL activeIdentityExists,
    NSSet<NSString *> *prunedTargetBundleIdentifiers
) {
    return activeIdentityExists ||
        ![prunedTargetBundleIdentifiers containsObject:bundleIdentifier];
}

@interface PXEnvironmentPolicyStore ()

@property (nonatomic, copy, readwrite) NSString *filePath;

@end

@implementation PXEnvironmentPolicyStore

+ (instancetype)sharedStore {
    static PXEnvironmentPolicyStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[self alloc] initWithFilePath:PXPreferencesFilePath(PXEnvironmentPolicyFileName)];
    });
    return store;
}

- (instancetype)initWithFilePath:(NSString *)filePath {
    self = [super init];
    if (self) {
        _filePath = [filePath.stringByStandardizingPath copy];
    }
    return self;
}

- (NSError *)policyErrorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:PXEnvironmentPolicyErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (nullable NSDictionary<NSString *, id> *)policyWithError:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.filePath]) {
        return @{};
    }
    NSDictionary<NSString *, id> *policy = [NSDictionary dictionaryWithContentsOfFile:self.filePath];
    if (![policy isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [self policyErrorWithCode:1 description:@"Pending environment configuration is invalid"];
        }
        return nil;
    }
    return policy;
}

- (BOOL)writePolicy:(NSDictionary<NSString *, id> *)policy error:(NSError **)error {
    NSString *directory = self.filePath.stringByDeletingLastPathComponent;
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&directoryError]) {
        if (error) *error = directoryError;
        return NO;
    }
    NSArray<NSString *> *allowedKeys = @[
        @"modelIdentifier",
        @"modelSelectionMode",
        @"networkType",
        @"location",
        @"locationState",
        @"pendingChanges",
        @"prunedTargetBundleIdentifiers",
        @"lastAppliedGenerationID",
        @"lastAppliedDate"
    ];
    NSMutableDictionary<NSString *, id> *persisted = [NSMutableDictionary dictionary];
    for (NSString *key in allowedKeys) {
        id value = policy[key];
        if (value) {
            persisted[key] = value;
        }
    }
    NSDictionary<NSString *, id> *legacyModel = [policy[@"modelRecord"]
        isKindOfClass:[NSDictionary class]] ? policy[@"modelRecord"] : nil;
    NSString *legacyModelIdentifier = [legacyModel[@"identifier"]
        isKindOfClass:[NSString class]] ? legacyModel[@"identifier"] : nil;
    NSString *persistedModelIdentifier = [persisted[@"modelIdentifier"]
        isKindOfClass:[NSString class]] ? persisted[@"modelIdentifier"] : nil;
    if (persistedModelIdentifier.length == 0 && legacyModelIdentifier.length > 0) {
        persisted[@"modelIdentifier"] = legacyModelIdentifier;
        persisted[@"modelSelectionMode"] = PXEnvironmentPolicyModelModeCustom;
    }
    persisted[@"schemaVersion"] = @1;
    if (![persisted writeToFile:self.filePath atomically:YES]) {
        if (error) {
            *error = [self policyErrorWithCode:2 description:@"Pending environment configuration could not be saved"];
        }
        return NO;
    }
    return YES;
}

- (nullable NSMutableDictionary<NSString *, id> *)mutablePolicyWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    return policy ? [policy mutableCopy] : nil;
}

- (nullable NSString *)selectedModelIdentifierWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    NSString *identifier = [policy[@"modelIdentifier"] isKindOfClass:[NSString class]]
        ? policy[@"modelIdentifier"]
        : nil;
    if (identifier.length > 0) {
        return identifier;
    }
    NSDictionary<NSString *, id> *legacyModel = [policy[@"modelRecord"]
        isKindOfClass:[NSDictionary class]] ? policy[@"modelRecord"] : nil;
    return [legacyModel[@"identifier"] isKindOfClass:[NSString class]]
        ? legacyModel[@"identifier"]
        : nil;
}

- (PXEnvironmentModelSelectionMode)selectedModelSelectionModeWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    if (!policy) {
        return PXEnvironmentModelSelectionModeMissing;
    }
    if ([policy[@"modelSelectionMode"] isEqualToString:PXEnvironmentPolicyModelModePhysical]) {
        return PXEnvironmentModelSelectionModePhysicalDevice;
    }
    if ([policy[@"modelSelectionMode"] isEqualToString:PXEnvironmentPolicyModelModeCustom]) {
        return PXEnvironmentModelSelectionModeCustom;
    }
    return PXEnvironmentModelSelectionModeMissing;
}

- (PXEnvironmentNetworkType)selectedNetworkTypeWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    NSString *identifier = [policy[@"networkType"] isKindOfClass:[NSString class]]
        ? policy[@"networkType"]
        : nil;
    return PXEnvironmentNetworkTypeFromIdentifier(identifier);
}

- (nullable NSDictionary<NSString *, id> *)configuredLocationWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    if (![policy[@"locationState"] isEqualToString:PXEnvironmentPolicyLocationSet]) {
        return nil;
    }
    id location = policy[@"location"];
    return [location isKindOfClass:[NSDictionary class]] ? location : nil;
}

- (BOOL)locationWasExplicitlyClearedWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    return [policy[@"locationState"] isEqualToString:PXEnvironmentPolicyLocationCleared];
}

- (BOOL)hasPendingChangesWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    return [policy[@"pendingChanges"] boolValue];
}

- (nullable NSDate *)lastAppliedDateWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    id date = policy[@"lastAppliedDate"];
    return [date isKindOfClass:[NSDate class]] ? date : nil;
}

- (nullable NSString *)lastAppliedGenerationIDWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    id generationID = policy[@"lastAppliedGenerationID"];
    return [generationID isKindOfClass:[NSString class]] ? generationID : nil;
}

- (nullable NSSet<NSString *> *)prunedTargetBundleIdentifiersWithError:(NSError **)error {
    NSDictionary<NSString *, id> *policy = [self policyWithError:error];
    if (!policy) {
        return nil;
    }
    id storedBundleIdentifiers = policy[@"prunedTargetBundleIdentifiers"];
    if (!storedBundleIdentifiers) {
        return [NSSet set];
    }
    if (![storedBundleIdentifiers isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [self policyErrorWithCode:7
                                   description:@"Pruned Target identity state is invalid"];
        }
        return nil;
    }
    NSMutableSet<NSString *> *bundleIdentifiers = [NSMutableSet set];
    for (id bundleIdentifier in storedBundleIdentifiers) {
        if (![bundleIdentifier isKindOfClass:[NSString class]] ||
            [(NSString *)bundleIdentifier length] == 0) {
            if (error) {
                *error = [self policyErrorWithCode:7
                                       description:@"Pruned Target identity state is invalid"];
            }
            return nil;
        }
        [bundleIdentifiers addObject:bundleIdentifier];
    }
    return [bundleIdentifiers copy];
}

- (BOOL)saveModelRecord:(NSDictionary<NSString *, id> *)modelRecord
          selectionMode:(NSString *)selectionMode
                  error:(NSError **)error {
    NSString *identifier = [modelRecord[@"identifier"] isKindOfClass:[NSString class]]
        ? modelRecord[@"identifier"]
        : nil;
    NSString *name = [modelRecord[@"name"] isKindOfClass:[NSString class]]
        ? modelRecord[@"name"]
        : nil;
    if (identifier.length == 0 || name.length == 0) {
        if (error) *error = [self policyErrorWithCode:3 description:@"Environment model is invalid"];
        return NO;
    }
    NSMutableDictionary<NSString *, id> *policy = [self mutablePolicyWithError:error];
    if (!policy) return NO;
    policy[@"modelSelectionMode"] = selectionMode;
    [policy removeObjectForKey:@"modelRecord"];
    if ([selectionMode isEqualToString:PXEnvironmentPolicyModelModePhysical]) {
        [policy removeObjectForKey:@"modelIdentifier"];
    } else {
        policy[@"modelIdentifier"] = identifier;
    }
    PXEnvironmentNetworkType networkType = PXEnvironmentNetworkTypeFromIdentifier(policy[@"networkType"]);
    if (networkType != PXEnvironmentNetworkTypeUnspecified &&
        !PXEnvironmentNetworkTypeIsCompatibleWithModelRecord(networkType, modelRecord)) {
        [policy removeObjectForKey:@"networkType"];
    }
    policy[@"pendingChanges"] = @YES;
    return [self writePolicy:policy error:error];
}

- (BOOL)saveSelectedModelRecord:(NSDictionary<NSString *, id> *)modelRecord
            physicalModelRecord:(NSDictionary<NSString *, id> *)physicalModelRecord
        hostGraphicsCapabilities:(NSDictionary<NSString *, id> *)hostGraphicsCapabilities
                            error:(NSError **)error {
    if (!PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        modelRecord,
        physicalModelRecord,
        hostGraphicsCapabilities,
        error)) {
        return NO;
    }
    return [self saveModelRecord:modelRecord
                   selectionMode:PXEnvironmentPolicyModelModeCustom
                           error:error];
}

- (BOOL)savePhysicalDeviceModelRecord:(NSDictionary<NSString *, id> *)modelRecord
                                error:(NSError **)error {
    return [self saveModelRecord:modelRecord
                   selectionMode:PXEnvironmentPolicyModelModePhysical
                           error:error];
}

- (BOOL)saveSelectedNetworkType:(PXEnvironmentNetworkType)networkType
                     modelRecord:(NSDictionary<NSString *, id> *)modelRecord
                           error:(NSError **)error {
    if (!PXEnvironmentNetworkTypeIsCompatibleWithModelRecord(networkType, modelRecord)) {
        if (error) {
            *error = [self policyErrorWithCode:4 description:@"Network type is not supported by the selected model"];
        }
        return NO;
    }
    NSMutableDictionary<NSString *, id> *policy = [self mutablePolicyWithError:error];
    if (!policy) return NO;
    policy[@"networkType"] = PXEnvironmentNetworkTypeIdentifier(networkType);
    policy[@"pendingChanges"] = @YES;
    return [self writePolicy:policy error:error];
}

- (BOOL)saveConfiguredLocation:(NSDictionary<NSString *, id> *)location error:(NSError **)error {
    NSNumber *latitude = [location[@"latitude"] isKindOfClass:[NSNumber class]] ? location[@"latitude"] : nil;
    NSNumber *longitude = [location[@"longitude"] isKindOfClass:[NSNumber class]] ? location[@"longitude"] : nil;
    double latitudeValue = latitude.doubleValue;
    double longitudeValue = longitude.doubleValue;
    if (!latitude || !longitude || !isfinite(latitudeValue) || !isfinite(longitudeValue) ||
        latitudeValue < -90.0 || latitudeValue > 90.0 ||
        longitudeValue < -180.0 || longitudeValue > 180.0) {
        if (error) *error = [self policyErrorWithCode:5 description:@"Smart location is invalid"];
        return NO;
    }
    NSMutableDictionary<NSString *, id> *policy = [self mutablePolicyWithError:error];
    if (!policy) return NO;
    NSMutableDictionary<NSString *, id> *normalizedLocation = [location mutableCopy];
    normalizedLocation[@"pinned"] = @YES;
    policy[@"location"] = [normalizedLocation copy];
    policy[@"locationState"] = PXEnvironmentPolicyLocationSet;
    policy[@"pendingChanges"] = @YES;
    return [self writePolicy:policy error:error];
}

- (BOOL)clearConfiguredLocationWithError:(NSError **)error {
    NSMutableDictionary<NSString *, id> *policy = [self mutablePolicyWithError:error];
    if (!policy) return NO;
    [policy removeObjectForKey:@"location"];
    policy[@"locationState"] = PXEnvironmentPolicyLocationCleared;
    policy[@"pendingChanges"] = @YES;
    return [self writePolicy:policy error:error];
}

- (BOOL)markPendingChangeWithError:(NSError **)error {
    return [self setPendingChanges:YES error:error];
}

- (BOOL)setPendingChanges:(BOOL)pendingChanges error:(NSError **)error {
    NSSet<NSString *> *prunedTargetBundleIdentifiers =
        [self prunedTargetBundleIdentifiersWithError:error];
    if (!prunedTargetBundleIdentifiers) {
        return NO;
    }
    return [self setPendingChanges:pendingChanges
     prunedTargetBundleIdentifiers:prunedTargetBundleIdentifiers
                              error:error];
}

- (BOOL)setPendingChanges:(BOOL)pendingChanges
    prunedTargetBundleIdentifiers:(NSSet<NSString *> *)prunedTargetBundleIdentifiers
                    error:(NSError **)error {
    for (id bundleIdentifier in prunedTargetBundleIdentifiers) {
        if (![bundleIdentifier isKindOfClass:[NSString class]] ||
            [(NSString *)bundleIdentifier length] == 0) {
            if (error) {
                *error = [self policyErrorWithCode:7
                                       description:@"Pruned Target identity state is invalid"];
            }
            return NO;
        }
    }
    NSMutableDictionary<NSString *, id> *policy = [self mutablePolicyWithError:error];
    if (!policy) return NO;
    policy[@"pendingChanges"] = @(pendingChanges);
    if (prunedTargetBundleIdentifiers.count > 0) {
        policy[@"prunedTargetBundleIdentifiers"] =
            [prunedTargetBundleIdentifiers.allObjects sortedArrayUsingSelector:@selector(compare:)];
    } else {
        [policy removeObjectForKey:@"prunedTargetBundleIdentifiers"];
    }
    return [self writePolicy:policy error:error];
}

- (BOOL)markAppliedGenerationID:(NSString *)generationID date:(NSDate *)date error:(NSError **)error {
    if (![[NSUUID alloc] initWithUUIDString:generationID] || !date) {
        if (error) *error = [self policyErrorWithCode:6 description:@"Applied environment state is invalid"];
        return NO;
    }
    NSMutableDictionary<NSString *, id> *policy = [self mutablePolicyWithError:error];
    if (!policy) return NO;
    policy[@"pendingChanges"] = @NO;
    [policy removeObjectForKey:@"prunedTargetBundleIdentifiers"];
    policy[@"lastAppliedGenerationID"] = generationID.lowercaseString;
    policy[@"lastAppliedDate"] = date;
    return [self writePolicy:policy error:error];
}

@end
