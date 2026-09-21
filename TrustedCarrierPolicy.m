#import "TrustedCarrierPolicy.h"

#import "NetworkIdentity.h"

static NSString *const PXTrustedCarrierPolicyErrorDomain = @"com.hydra.projectx.trusted-carrier-policy";

@interface PXTrustedCarrierPolicyStore ()

@property (nonatomic, copy) NSString *profileDirectory;

@end


@implementation PXTrustedCarrierPolicyStore

- (instancetype)initWithProfileDirectory:(NSString *)profileDirectory {
    self = [super init];
    if (self) {
        _profileDirectory = [profileDirectory copy];
    }
    return self;
}

- (NSString *)policyFilePath {
    return [self.profileDirectory stringByAppendingPathComponent:@"trusted_carriers.plist"];
}

- (BOOL)failWithError:(NSError **)error code:(NSInteger)code description:(NSString *)description {
    if (error) {
        *error = [NSError errorWithDomain:PXTrustedCarrierPolicyErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

- (BOOL)writeTrustedCarrierIDs:(NSSet<NSString *> *)trustedCarrierIDs error:(NSError **)error {
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:self.profileDirectory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&directoryError]) {
        if (error) *error = directoryError;
        return NO;
    }
    NSArray<NSString *> *sortedCarrierIDs = [trustedCarrierIDs.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSDictionary<NSString *, id> *policy = @{
        @"schemaVersion": @1,
        @"trustedCarrierIDs": sortedCarrierIDs
    };
    if (![policy writeToFile:[self policyFilePath] atomically:YES]) {
        return [self failWithError:error code:2 description:@"Failed to persist trusted Carrier policy"];
    }
    return YES;
}

- (nullable NSSet<NSString *> *)trustedCarrierIDsWithError:(NSError **)error {
    NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:[self policyFilePath]];
    NSArray *persistedIDs = [policy[@"trustedCarrierIDs"] isKindOfClass:[NSArray class]]
        ? policy[@"trustedCarrierIDs"]
        : nil;
    NSSet<NSString *> *savedCarrierIDs = persistedIDs ? [NSSet setWithArray:persistedIDs] : nil;
    BOOL repaired = NO;
    NSSet<NSString *> *normalizedCarrierIDs = PXNormalizedTrustedCarrierIDs(savedCarrierIDs, &repaired);
    if (repaired && ![self writeTrustedCarrierIDs:normalizedCarrierIDs error:error]) {
        return nil;
    }
    return normalizedCarrierIDs;
}

- (BOOL)saveTrustedCarrierIDs:(NSSet<NSString *> *)trustedCarrierIDs error:(NSError **)error {
    if (trustedCarrierIDs.count == 0) {
        return [self failWithError:error code:1 description:@"Select at least one trusted Carrier"];
    }
    NSSet<NSString *> *allCarrierIDs = PXAllCarrierIDs();
    NSMutableSet<NSString *> *validCarrierIDs = [NSMutableSet set];
    for (id carrierID in trustedCarrierIDs) {
        if ([carrierID isKindOfClass:[NSString class]] && [allCarrierIDs containsObject:carrierID]) {
            [validCarrierIDs addObject:carrierID];
        }
    }
    if (validCarrierIDs.count == 0) {
        return [self failWithError:error code:1 description:@"The selected Carriers are no longer available"];
    }
    NSString *selectedCarrierID = [validCarrierIDs.allObjects
        sortedArrayUsingSelector:@selector(compare:)].firstObject;
    return [self writeTrustedCarrierIDs:[NSSet setWithObject:selectedCarrierID] error:error];
}

- (nullable NSString *)selectedCarrierIDWithError:(NSError **)error {
    return [self trustedCarrierIDsWithError:error].anyObject;
}

- (BOOL)saveSelectedCarrierID:(NSString *)carrierID error:(NSError **)error {
    if (carrierID.length == 0) {
        return [self failWithError:error code:1 description:@"Select a Carrier"];
    }
    return [self saveTrustedCarrierIDs:[NSSet setWithObject:carrierID] error:error];
}

@end
