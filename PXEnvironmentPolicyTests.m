#import <Foundation/Foundation.h>
#include <assert.h>

#import "GraphicsIdentity.h"
#import "PXEnvironmentPolicy.h"

static NSString *CreatePolicyPath(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    return [directory stringByAppendingPathComponent:@"pending_environment.plist"];
}

static NSDictionary<NSString *, id> *ModelRecord(NSString *identifier, BOOL supports5G) {
    return @{
        @"identifier": identifier,
        @"productType": identifier,
        @"name": @"iPhone 7 Plus",
        @"cpuArchitecture": @"Apple A10 Fusion",
        @"cpuCoreCount": @4,
        @"gpuFamily": @"Apple A10 GPU",
        @"metalFeatureSet": @"Metal 2.2",
        @"deviceMemory": @3,
        @"screenResolution": @"1920x1080",
        @"viewportResolution": @"2208x1242",
        @"devicePixelRatio": @3,
        @"screenDensity": @401,
        @"webGLInfo": @{
            @"unmaskedVendor": @"Apple Inc.",
            @"unmaskedRenderer": @"Apple A10 GPU",
            @"webglVendor": @"Apple",
            @"webglRenderer": @"Apple GPU",
            @"webglVersion": @"WebGL 2.0",
            @"maxTextureSize": @16384,
            @"maxRenderBufferSize": @16384
        },
        @"supports5G": @(supports5G)
    };
}

static NSDictionary<NSString *, id> *HardwareModelRecord(
    NSString *identifier,
    NSString *name,
    NSString *cpu,
    NSInteger cpuCores,
    NSString *gpu,
    NSString *metal,
    NSInteger memory,
    NSString *screenResolution,
    NSString *viewportResolution,
    NSNumber *pixelRatio,
    NSInteger density
) {
    return @{
        @"identifier": identifier,
        @"productType": identifier,
        @"name": name,
        @"cpuArchitecture": cpu,
        @"cpuCoreCount": @(cpuCores),
        @"gpuFamily": gpu,
        @"metalFeatureSet": metal,
        @"deviceMemory": @(memory),
        @"screenResolution": screenResolution,
        @"viewportResolution": viewportResolution,
        @"devicePixelRatio": pixelRatio,
        @"screenDensity": @(density),
        @"supports5G": @NO,
        @"webGLInfo": @{
            @"unmaskedVendor": @"Apple Inc.",
            @"unmaskedRenderer": gpu,
            @"webglVendor": @"Apple",
            @"webglRenderer": @"Apple GPU",
            @"webglVersion": @"WebGL 2.0",
            @"maxTextureSize": @16384,
            @"maxRenderBufferSize": @16384
        }
    };
}

static NSDictionary<NSString *, id> *PolicyA10HostCapabilities(void) {
    return @{
        @"metalFamilies": @[@1001, @1002, @1003],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9,
                                @10, @12, @13, @14],
        @"maxTextureSize": @16384,
        @"maxRenderbufferSize": @16384,
        @"supportsOpenGLES3": @YES
    };
}

static void RemovePolicyFixture(NSString *filePath) {
    [[NSFileManager defaultManager] removeItemAtPath:filePath.stringByDeletingLastPathComponent
                                               error:nil];
}

static void testSelectionsPersistAsPendingWithoutLosingCoherentModelRecord(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    NSDictionary<NSString *, id> *model = ModelRecord(@"iPhone9,4", YES);
    assert([store saveSelectedModelRecord:model
                       physicalModelRecord:ModelRecord(@"iPhone9,2", NO)
                   hostGraphicsCapabilities:PolicyA10HostCapabilities()
                                       error:nil]);
    assert([store selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModeCustom);
    assert([store saveSelectedNetworkType:PXEnvironmentNetworkType5GNR modelRecord:model error:nil]);
    NSDictionary<NSString *, id> *location = @{
        @"latitude": @31.2304,
        @"longitude": @121.4737,
        @"address": @"Shanghai",
        @"countryCode": @"CN",
        @"pinned": @YES
    };
    assert([store saveConfiguredLocation:location error:nil]);

    PXEnvironmentPolicyStore *recreated = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    assert([[recreated selectedModelIdentifierWithError:nil] isEqualToString:@"iPhone9,4"]);
    NSDictionary<NSString *, id> *persisted = [NSDictionary dictionaryWithContentsOfFile:filePath];
    assert(persisted[@"modelRecord"] == nil);
    assert([recreated selectedNetworkTypeWithError:nil] == PXEnvironmentNetworkType5GNR);
    assert([[recreated configuredLocationWithError:nil] isEqualToDictionary:location]);
    assert(![recreated locationWasExplicitlyClearedWithError:nil]);
    assert([recreated hasPendingChangesWithError:nil]);
    RemovePolicyFixture(filePath);
}

static void testPhysicalDeviceSelectionModePersistsWithModelSnapshot(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    NSDictionary<NSString *, id> *physicalModel = ModelRecord(@"iPhone9,2", NO);

    assert([store savePhysicalDeviceModelRecord:physicalModel error:nil]);

    PXEnvironmentPolicyStore *recreated = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    assert([recreated selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModePhysicalDevice);
    assert([recreated selectedModelIdentifierWithError:nil] == nil);
    NSDictionary<NSString *, id> *persisted = [NSDictionary dictionaryWithContentsOfFile:filePath];
    assert(persisted[@"modelRecord"] == nil);
    assert([recreated hasPendingChangesWithError:nil]);
    RemovePolicyFixture(filePath);
}

static void testPhysicalSelectionAtomicallyClearsIncompatibleCustomSelection(void) {
    NSString *filePath = CreatePolicyPath();
    NSDictionary<NSString *, id> *staleCustomPolicy = @{
        @"schemaVersion": @1,
        @"modelIdentifier": @"iPhone15,2",
        @"modelSelectionMode": @"custom",
        @"networkType": @"5g-nr",
        @"pendingChanges": @YES
    };
    assert([staleCustomPolicy writeToFile:filePath atomically:YES]);
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:filePath];

    assert([store savePhysicalDeviceModelRecord:ModelRecord(@"iPhone9,2", NO)
                                          error:nil]);

    assert([store selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModePhysicalDevice);
    assert([store selectedModelIdentifierWithError:nil] == nil);
    assert([store selectedNetworkTypeWithError:nil] == PXEnvironmentNetworkTypeUnspecified);
    assert([store hasPendingChangesWithError:nil]);
    RemovePolicyFixture(filePath);
}

static void testNetworkCompatibilityRejectsUnsupported5G(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    NSDictionary<NSString *, id> *legacyModel = ModelRecord(@"iPhone10,3", NO);
    NSError *error = nil;
    assert(!PXEnvironmentNetworkTypeIsCompatibleWithModelRecord(PXEnvironmentNetworkType5GNR,
                                                                 legacyModel));
    assert(![store saveSelectedNetworkType:PXEnvironmentNetworkType5GNR
                                modelRecord:legacyModel
                                      error:&error]);
    assert(error != nil);
    assert(PXEnvironmentNetworkTypeIsCompatibleWithModelRecord(PXEnvironmentNetworkType4GLTE,
                                                                legacyModel));
    assert([store saveSelectedNetworkType:PXEnvironmentNetworkType4GLTE
                               modelRecord:legacyModel
                                     error:nil]);
    RemovePolicyFixture(filePath);
}

static void testAppliedStateClearsPendingButRetainsNextGenerationDefaults(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    NSDictionary<NSString *, id> *model = ModelRecord(@"iPhone9,4", YES);
    assert([store saveSelectedModelRecord:model
                       physicalModelRecord:ModelRecord(@"iPhone9,2", NO)
                   hostGraphicsCapabilities:PolicyA10HostCapabilities()
                                       error:nil]);
    NSDate *appliedDate = [NSDate dateWithTimeIntervalSince1970:1234];
    NSString *generationID = @"11111111-1111-4111-8111-111111111111";
    assert([store markAppliedGenerationID:generationID date:appliedDate error:nil]);
    assert(![store hasPendingChangesWithError:nil]);
    assert([[store selectedModelIdentifierWithError:nil] isEqualToString:@"iPhone9,4"]);
    assert([[store lastAppliedDateWithError:nil] isEqualToDate:appliedDate]);
    assert([[store lastAppliedGenerationIDWithError:nil] isEqualToString:generationID]);
    RemovePolicyFixture(filePath);
}

static void testPendingStateCanBeRestoredWithoutChangingAppliedMetadata(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    NSString *generationID = @"11111111-1111-4111-8111-111111111111";
    NSDate *appliedDate = [NSDate dateWithTimeIntervalSince1970:4321];
    assert([store markAppliedGenerationID:generationID date:appliedDate error:nil]);
    assert([store markPendingChangeWithError:nil]);

    assert([store setPendingChanges:NO error:nil]);

    assert(![store hasPendingChangesWithError:nil]);
    assert([[store lastAppliedGenerationIDWithError:nil] isEqualToString:generationID]);
    assert([[store lastAppliedDateWithError:nil] isEqualToDate:appliedDate]);
    RemovePolicyFixture(filePath);
}

static void testPrunedTargetIdentityCannotBeRecreatedBeforeNewGenerationApplies(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    NSSet<NSString *> *prunedTargets = [NSSet setWithObject:@"com.example.reinstalled"];
    assert([store setPendingChanges:YES
             prunedTargetBundleIdentifiers:prunedTargets
                                      error:nil]);
    assert([[store prunedTargetBundleIdentifiersWithError:nil] isEqualToSet:prunedTargets]);
    assert(!PXEnvironmentAllowsApplicationIdentityEnsure(
        @"com.example.reinstalled", NO, prunedTargets));
    assert(PXEnvironmentAllowsApplicationIdentityEnsure(
        @"com.example.reinstalled", YES, prunedTargets));
    assert(PXEnvironmentAllowsApplicationIdentityEnsure(
        @"com.example.other", NO, prunedTargets));

    assert([store markAppliedGenerationID:@"11111111-1111-4111-8111-111111111111"
                                    date:[NSDate dateWithTimeIntervalSince1970:5432]
                                   error:nil]);
    assert([store prunedTargetBundleIdentifiersWithError:nil].count == 0);
    RemovePolicyFixture(filePath);
}

static void testReadyRequiresMatchingActiveGenerationAndExactTargetScope(void) {
    NSString *generationID = @"11111111-1111-4111-8111-111111111111";
    NSSet<NSString *> *selectedTargets = [NSSet setWithArray:@[
        @"com.example.alpha",
        @"com.example.beta"
    ]];
    assert(PXEnvironmentAppliedStateIsReady(
        NO,
        generationID,
        generationID.uppercaseString,
        selectedTargets,
        [selectedTargets copy]));
    assert(!PXEnvironmentAppliedStateIsReady(
        YES,
        generationID,
        generationID,
        selectedTargets,
        selectedTargets));
    assert(!PXEnvironmentAppliedStateIsReady(
        NO,
        nil,
        generationID,
        selectedTargets,
        selectedTargets));
    assert(!PXEnvironmentAppliedStateIsReady(
        NO,
        generationID,
        @"22222222-2222-4222-8222-222222222222",
        selectedTargets,
        selectedTargets));
    assert(!PXEnvironmentAppliedStateIsReady(
        NO,
        generationID,
        generationID,
        selectedTargets,
        [NSSet setWithObject:@"com.example.alpha"]));
    assert(!PXEnvironmentAppliedStateIsReady(
        NO,
        generationID,
        generationID,
        [NSSet set],
        [NSSet set]));
}

static void testClearLocationIsExplicitAndDoesNotEraseOtherSelections(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc] initWithFilePath:filePath];
    NSDictionary<NSString *, id> *model = ModelRecord(@"iPhone9,4", YES);
    assert([store saveSelectedModelRecord:model
                       physicalModelRecord:ModelRecord(@"iPhone9,2", NO)
                   hostGraphicsCapabilities:PolicyA10HostCapabilities()
                                       error:nil]);
    assert([store clearConfiguredLocationWithError:nil]);
    assert([store configuredLocationWithError:nil] == nil);
    assert([store locationWasExplicitlyClearedWithError:nil]);
    assert([[store selectedModelIdentifierWithError:nil] isEqualToString:@"iPhone9,4"]);
    assert([store hasPendingChangesWithError:nil]);
    RemovePolicyFixture(filePath);
}

static void testPersistingHighLevelPolicyRemovesLegacyDerivedValues(void) {
    NSString *filePath = CreatePolicyPath();
    NSDictionary<NSString *, id> *model = ModelRecord(@"iPhone9,4", YES);
    NSDictionary<NSString *, id> *legacyPolicy = @{
        @"schemaVersion": @1,
        @"modelRecord": model,
        @"networkType": @"4g-lte",
        @"pendingChanges": @YES,
        @"operatingSystem": @{@"version": @"17.5"},
        @"graphics": @{@"gpuName": @"Legacy GPU"},
        @"carrier": @{@"mcc": @"310", @"mnc": @"410"},
        @"region": @{@"countryCode": @"US"},
        @"virtualSession": @{@"bootUUID": NSUUID.UUID.UUIDString},
        @"identifiers": @{@"idfa": NSUUID.UUID.UUIDString},
        @"appIdentities": @{@"com.example.app": @{}}
    };
    assert([legacyPolicy writeToFile:filePath atomically:YES]);
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:filePath];

    assert([store saveSelectedModelRecord:model
                       physicalModelRecord:ModelRecord(@"iPhone9,2", NO)
                   hostGraphicsCapabilities:PolicyA10HostCapabilities()
                                       error:nil]);

    NSDictionary<NSString *, id> *persisted = [NSDictionary
        dictionaryWithContentsOfFile:filePath];
    NSSet<NSString *> *expectedKeys = [NSSet setWithArray:@[
        @"schemaVersion",
        @"modelIdentifier",
        @"modelSelectionMode",
        @"networkType",
        @"pendingChanges"
    ]];
    assert([[NSSet setWithArray:persisted.allKeys] isEqualToSet:expectedKeys]);
    assert([persisted[@"modelIdentifier"] isEqualToString:@"iPhone9,4"]);
    assert([persisted[@"networkType"] isEqualToString:@"4g-lte"]);
    RemovePolicyFixture(filePath);
}

static void testIncompatibleSelectionFailsAtomicallyWithConcreteReason(void) {
    NSString *filePath = CreatePolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:filePath];
    NSDictionary<NSString *, id> *physical = HardwareModelRecord(
        @"iPhone9,2", @"iPhone 7 Plus", @"Apple A10 Fusion", 4,
        @"Apple A10 GPU", @"Metal 2.2", 3, @"1920x1080", @"2208x1242", @3, 401);
    NSDictionary<NSString *, id> *previousSelection = HardwareModelRecord(
        @"iPhone9,4", @"iPhone 7 Plus", @"Apple A10 Fusion", 4,
        @"Apple A10 GPU", @"Metal 2.2", 3, @"1920x1080", @"2208x1242", @3, 401);
    NSDictionary<NSString *, id> *incompatibleSelection = HardwareModelRecord(
        @"iPhone15,2", @"iPhone 14 Pro", @"Apple A16 Bionic", 6,
        @"Apple A16 Pro GPU", @"Metal 3.1", 6, @"2556x1179", @"2556x1179", @3, 460);
    assert([store saveSelectedModelRecord:previousSelection
                       physicalModelRecord:physical
                   hostGraphicsCapabilities:PolicyA10HostCapabilities()
                                       error:nil]);
    NSDictionary<NSString *, id> *before = [NSDictionary dictionaryWithContentsOfFile:filePath];
    NSError *error = nil;

    assert(![store saveSelectedModelRecord:incompatibleSelection
                        physicalModelRecord:physical
                    hostGraphicsCapabilities:PolicyA10HostCapabilities()
                                        error:&error]);

    assert([error.domain isEqualToString:PXModelCompatibilityErrorDomain]);
    assert(error.code == PXModelCompatibilityErrorImmutableHardwareMismatch);
    assert(error.localizedDescription.length > 0);
    assert([error.userInfo[PXModelCompatibilityReasonErrorKey]
        isEqualToString:PXModelCompatibilityReasonImmutableHardwareMismatch]);
    assert([error.userInfo[PXModelCompatibilityMismatchFieldsErrorKey]
        containsObject:PXModelCompatibilityFieldGraphicsClass]);
    NSDictionary<NSString *, id> *after = [NSDictionary dictionaryWithContentsOfFile:filePath];
    assert([after isEqualToDictionary:before]);
    RemovePolicyFixture(filePath);
}

int main(void) {
    @autoreleasepool {
        testSelectionsPersistAsPendingWithoutLosingCoherentModelRecord();
        testPhysicalDeviceSelectionModePersistsWithModelSnapshot();
        testPhysicalSelectionAtomicallyClearsIncompatibleCustomSelection();
        testNetworkCompatibilityRejectsUnsupported5G();
        testAppliedStateClearsPendingButRetainsNextGenerationDefaults();
        testPendingStateCanBeRestoredWithoutChangingAppliedMetadata();
        testPrunedTargetIdentityCannotBeRecreatedBeforeNewGenerationApplies();
        testReadyRequiresMatchingActiveGenerationAndExactTargetScope();
        testClearLocationIsExplicitAndDoesNotEraseOtherSelections();
        testPersistingHighLevelPolicyRemovesLegacyDerivedValues();
        testIncompatibleSelectionFailsAtomicallyWithConcreteReason();
    }
    return 0;
}
