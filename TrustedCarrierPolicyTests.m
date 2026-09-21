#import "NetworkIdentity.h"
#import "TrustedCarrierPolicy.h"

#include <assert.h>

static NSString *firstCatalogCarrierID(void) {
    return [PXAllCarrierIDs().allObjects sortedArrayUsingSelector:@selector(compare:)].firstObject;
}

static void testMissingPolicyDefaultsToOneDeterministicCarrierAndPersists(void) {
    NSString *profileDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:profileDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    PXTrustedCarrierPolicyStore *store = [[PXTrustedCarrierPolicyStore alloc]
        initWithProfileDirectory:profileDirectory];
    NSError *readError = nil;
    NSSet<NSString *> *trustedCarrierIDs = [store trustedCarrierIDsWithError:&readError];
    assert(readError == nil);
    assert([trustedCarrierIDs isEqualToSet:[NSSet setWithObject:firstCatalogCarrierID()]]);

    NSDictionary *persistedPolicy = [NSDictionary dictionaryWithContentsOfFile:
        [profileDirectory stringByAppendingPathComponent:@"trusted_carriers.plist"]];
    assert([persistedPolicy[@"trustedCarrierIDs"] isEqualToArray:@[firstCatalogCarrierID()]]);
    [[NSFileManager defaultManager] removeItemAtPath:profileDirectory error:nil];
}

static void testExplicitPolicySaveRejectsEmptyAndPersistsOneStableCarrierID(void) {
    NSString *profileDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXTrustedCarrierPolicyStore *store = [[PXTrustedCarrierPolicyStore alloc]
        initWithProfileDirectory:profileDirectory];
    NSError *saveError = nil;
    assert(![store saveTrustedCarrierIDs:[NSSet set] error:&saveError]);
    assert(saveError != nil);

    NSArray<NSString *> *knownCarrierIDs = [PXAllCarrierIDs().allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSString *knownCarrierID = knownCarrierIDs.lastObject;
    NSSet<NSString *> *selectionWithUnknownID = [NSSet setWithObjects:knownCarrierID,
                                                                          knownCarrierIDs.firstObject,
                                                                          @"removed-carrier",
                                                                          nil];
    assert([store saveTrustedCarrierIDs:selectionWithUnknownID error:nil]);
    assert([[store trustedCarrierIDsWithError:nil] isEqualToSet:
        [NSSet setWithObject:knownCarrierIDs.firstObject]]);
    [[NSFileManager defaultManager] removeItemAtPath:profileDirectory error:nil];
}

static void testPolicyEditDoesNotMutateActiveGeneratedIdentity(void) {
    NSString *profileDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *identityDirectory = [profileDirectory stringByAppendingPathComponent:@"identity"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    NSDictionary *activeNetwork = @{
        @"generationID": @"existing-generation",
        @"carrierID": @"fr-orange-208-01",
        @"carrierName": @"Orange"
    };
    NSDictionary *activeManifest = @{
        @"generationID": @"existing-generation",
        @"network": activeNetwork
    };
    NSString *networkPath = [identityDirectory stringByAppendingPathComponent:@"network_settings.plist"];
    NSString *manifestPath = [identityDirectory stringByAppendingPathComponent:@"profile_manifest.plist"];
    assert([activeNetwork writeToFile:networkPath atomically:YES]);
    assert([activeManifest writeToFile:manifestPath atomically:YES]);

    PXTrustedCarrierPolicyStore *store = [[PXTrustedCarrierPolicyStore alloc]
        initWithProfileDirectory:profileDirectory];
    assert([store saveTrustedCarrierIDs:[NSSet setWithObject:@"fr-sfr-208-10"] error:nil]);
    assert([[NSDictionary dictionaryWithContentsOfFile:networkPath] isEqualToDictionary:activeNetwork]);
    assert([[NSDictionary dictionaryWithContentsOfFile:manifestPath] isEqualToDictionary:activeManifest]);
    [[NSFileManager defaultManager] removeItemAtPath:profileDirectory error:nil];
}

static void testLegacyMultipleAndInvalidCarrierIDsMigrateDeterministicallyToOne(void) {
    NSString *profileDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:profileDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    NSString *policyPath = [profileDirectory stringByAppendingPathComponent:@"trusted_carriers.plist"];
    NSDictionary *legacyPolicy = @{
        @"schemaVersion": @1,
        @"trustedCarrierIDs": @[@"fr-sfr-208-10", @"fr-orange-208-01", @"removed-carrier"]
    };
    assert([legacyPolicy writeToFile:policyPath atomically:YES]);
    PXTrustedCarrierPolicyStore *store = [[PXTrustedCarrierPolicyStore alloc]
        initWithProfileDirectory:profileDirectory];
    assert([[store trustedCarrierIDsWithError:nil] isEqualToSet:
        [NSSet setWithObject:@"fr-orange-208-01"]]);
    NSDictionary *repairedPolicy = [NSDictionary dictionaryWithContentsOfFile:policyPath];
    assert([repairedPolicy[@"trustedCarrierIDs"] isEqualToArray:@[@"fr-orange-208-01"]]);
    [[NSFileManager defaultManager] removeItemAtPath:profileDirectory error:nil];
}

int main(void) {
    @autoreleasepool {
        testMissingPolicyDefaultsToOneDeterministicCarrierAndPersists();
        testExplicitPolicySaveRejectsEmptyAndPersistsOneStableCarrierID();
        testPolicyEditDoesNotMutateActiveGeneratedIdentity();
        testLegacyMultipleAndInvalidCarrierIDsMigrateDeterministicallyToOne();
    }
    return 0;
}
