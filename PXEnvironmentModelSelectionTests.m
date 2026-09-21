#import <Foundation/Foundation.h>

#include <assert.h>

#import "GraphicsIdentity.h"
#import "PXEnvironmentModelSelection.h"
#import "PXEnvironmentPolicy.h"

static NSString *CreateSelectionPolicyPath(void) {
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager]
        createDirectoryAtPath:directory
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil]);
    return [directory stringByAppendingPathComponent:@"pending_environment.plist"];
}

static NSDictionary<NSString *, id> *SelectionModelRecord(
    NSString *identifier,
    NSString *name,
    NSString *gpu,
    NSString *metal,
    BOOL supports5G
) {
    BOOL isNewerModel = [gpu containsString:@"A16"];
    BOOL isPlusModel = [name containsString:@"Plus"];
    return @{
        @"identifier": identifier,
        @"productType": identifier,
        @"name": name,
        @"cpuArchitecture": isNewerModel ? @"Apple A16 Bionic" : @"Apple A10 Fusion",
        @"cpuCoreCount": isNewerModel ? @6 : @4,
        @"gpuFamily": gpu,
        @"metalFeatureSet": metal,
        @"deviceMemory": isNewerModel ? @6 : (isPlusModel ? @3 : @2),
        @"screenResolution": isNewerModel ? @"2556x1179" : (isPlusModel ? @"1920x1080" : @"1334x750"),
        @"viewportResolution": isNewerModel ? @"2556x1179" : (isPlusModel ? @"2208x1242" : @"1334x750"),
        @"devicePixelRatio": isNewerModel ? @3 : (isPlusModel ? @3 : @2),
        @"screenDensity": isNewerModel ? @460 : (isPlusModel ? @401 : @326),
        @"supports5G": @(supports5G),
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

static NSDictionary<NSString *, id> *A10HostCapabilities(void) {
    return @{
        @"metalFamilies": @[@1001, @1002, @1003],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @12, @13, @14],
        @"maxTextureSize": @16384,
        @"maxRenderbufferSize": @16384,
        @"supportsOpenGLES3": @YES
    };
}

static NSDictionary<NSString *, id> *UncertainHostCapabilities(NSArray<NSNumber *> *families) {
    return @{
        @"metalFamilies": families,
        @"metalFeatureSets": @[],
        @"maxTextureSize": @0,
        @"maxRenderbufferSize": @0,
        @"supportsOpenGLES3": @NO
    };
}

static NSDictionary<NSString *, id> *IPhoneSevenPlusRecord(void) {
    return SelectionModelRecord(
        @"iPhone9,2",
        @"iPhone 7 Plus",
        @"Apple A10 GPU",
        @"Metal 2.2",
        NO);
}

static void RemoveSelectionFixture(NSString *filePath) {
    [[NSFileManager defaultManager]
        removeItemAtPath:filePath.stringByDeletingLastPathComponent
                   error:nil];
}

static void testMissingSelectionMigratesToPhysicalDevice(void) {
    NSString *filePath = CreateSelectionPolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:filePath];
    BOOL didMigrate = NO;
    NSError *error = nil;

    NSDictionary<NSString *, id> *resolved = PXResolveEnvironmentModelSelection(
        store,
        @[IPhoneSevenPlusRecord()],
        IPhoneSevenPlusRecord(),
        A10HostCapabilities(),
        &didMigrate,
        &error);

    assert(error == nil);
    assert(didMigrate);
    assert([resolved[@"identifier"] isEqualToString:@"iPhone9,2"]);
    assert([store selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModePhysicalDevice);
    assert([store selectedModelIdentifierWithError:nil] == nil);
    RemoveSelectionFixture(filePath);
}

static void testPhysicalSelectionIgnoresOptionalGraphicsProbeUncertainty(void) {
    NSArray<NSDictionary<NSString *, id> *> *uncertainHosts = @[
        UncertainHostCapabilities(@[]),
        UncertainHostCapabilities(@[@1008])
    ];
    for (NSDictionary<NSString *, id> *hostCapabilities in uncertainHosts) {
        NSString *filePath = CreateSelectionPolicyPath();
        PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
            initWithFilePath:filePath];
        BOOL didMigrate = NO;
        NSError *error = nil;

        NSDictionary<NSString *, id> *resolved = PXResolveEnvironmentModelSelection(
            store,
            @[IPhoneSevenPlusRecord()],
            IPhoneSevenPlusRecord(),
            hostCapabilities,
            &didMigrate,
            &error);

        assert(error == nil);
        assert(didMigrate);
        assert([resolved[@"identifier"] isEqualToString:@"iPhone9,2"]);
        assert([store selectedModelSelectionModeWithError:nil] ==
            PXEnvironmentModelSelectionModePhysicalDevice);
        assert([store selectedModelIdentifierWithError:nil] == nil);
        RemoveSelectionFixture(filePath);
    }
}

static void testRemovedIPadSelectionRecoversToPhysicalIPhone(void) {
    NSString *filePath = CreateSelectionPolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:filePath];
    NSDictionary<NSString *, id> *stalePolicy = @{
        @"schemaVersion": @1,
        @"modelIdentifier": @"iPad14,3",
        @"modelSelectionMode": @"custom",
        @"networkType": @"4g-lte",
        @"pendingChanges": @YES
    };
    assert([stalePolicy writeToFile:filePath atomically:YES]);
    BOOL didMigrate = NO;
    NSError *error = nil;

    NSDictionary<NSString *, id> *resolved = PXResolveEnvironmentModelSelection(
        store,
        @[IPhoneSevenPlusRecord()],
        IPhoneSevenPlusRecord(),
        A10HostCapabilities(),
        &didMigrate,
        &error);

    assert(error == nil);
    assert(didMigrate);
    assert([resolved[@"identifier"] isEqualToString:@"iPhone9,2"]);
    assert([store selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModePhysicalDevice);
    assert([store selectedModelIdentifierWithError:nil] == nil);
    assert([store selectedNetworkTypeWithError:nil] == PXEnvironmentNetworkType4GLTE);
    RemoveSelectionFixture(filePath);
}

static void testIncompatibleLegacySelectionMigratesToPhysicalDevice(void) {
    NSString *filePath = CreateSelectionPolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:filePath];
    NSDictionary<NSString *, id> *iPhoneFourteenPro = SelectionModelRecord(
        @"iPhone15,2",
        @"iPhone 14 Pro",
        @"Apple A16 Pro GPU",
        @"Metal 3.1",
        YES);
    NSDictionary<NSString *, id> *legacyPolicy = @{
        @"schemaVersion": @1,
        @"modelRecord": iPhoneFourteenPro,
        @"networkType": @"5g-nr",
        @"pendingChanges": @YES
    };
    assert([legacyPolicy writeToFile:filePath atomically:YES]);
    BOOL didMigrate = NO;
    NSError *error = nil;

    NSDictionary<NSString *, id> *resolved = PXResolveEnvironmentModelSelection(
        store,
        @[iPhoneFourteenPro, IPhoneSevenPlusRecord()],
        IPhoneSevenPlusRecord(),
        A10HostCapabilities(),
        &didMigrate,
        &error);

    assert(error == nil);
    assert(didMigrate);
    assert([resolved[@"identifier"] isEqualToString:@"iPhone9,2"]);
    assert([store selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModePhysicalDevice);
    assert([store selectedModelIdentifierWithError:nil] == nil);
    assert([store selectedNetworkTypeWithError:nil] == PXEnvironmentNetworkTypeUnspecified);
    RemoveSelectionFixture(filePath);
}

static void testCompatibleCustomSelectionRemainsSelected(void) {
    NSString *filePath = CreateSelectionPolicyPath();
    PXEnvironmentPolicyStore *store = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:filePath];
    NSDictionary<NSString *, id> *customA10Model = SelectionModelRecord(
        @"iPhone9,4",
        @"iPhone 7 Plus",
        @"Apple A10 GPU",
        @"Metal 2.2",
        NO);
    assert([store saveSelectedModelRecord:customA10Model
                       physicalModelRecord:IPhoneSevenPlusRecord()
                   hostGraphicsCapabilities:A10HostCapabilities()
                                       error:nil]);
    BOOL didMigrate = YES;

    NSDictionary<NSString *, id> *resolved = PXResolveEnvironmentModelSelection(
        store,
        @[customA10Model, IPhoneSevenPlusRecord()],
        IPhoneSevenPlusRecord(),
        A10HostCapabilities(),
        &didMigrate,
        nil);

    assert([resolved isEqualToDictionary:customA10Model]);
    assert(!didMigrate);
    assert([store selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModeCustom);
    RemoveSelectionFixture(filePath);
}

static void testGraphicsCapabilityFailureOffersPhysicalRecovery(void) {
    NSError *graphicsError = [NSError errorWithDomain:PXGraphicsIdentityErrorDomain
                                                 code:3
                                             userInfo:nil];
    NSError *otherError = [NSError errorWithDomain:PXGraphicsIdentityErrorDomain
                                              code:2
                                          userInfo:nil];
    assert(PXEnvironmentModelSelectionCanRecoverFromError(graphicsError));
    assert(!PXEnvironmentModelSelectionCanRecoverFromError(otherError));
    NSError *modelMismatch = [NSError
        errorWithDomain:PXModelCompatibilityErrorDomain
                   code:PXModelCompatibilityErrorImmutableHardwareMismatch
               userInfo:nil];
    NSError *missingHostCapabilities = [NSError
        errorWithDomain:PXModelCompatibilityErrorDomain
                   code:PXModelCompatibilityErrorHostCapabilitiesUnavailable
               userInfo:nil];
    assert(PXEnvironmentModelSelectionCanRecoverFromError(modelMismatch));
    assert(!PXEnvironmentModelSelectionCanRecoverFromError(missingHostCapabilities));
}

int main(void) {
    @autoreleasepool {
        testMissingSelectionMigratesToPhysicalDevice();
        testPhysicalSelectionIgnoresOptionalGraphicsProbeUncertainty();
        testRemovedIPadSelectionRecoversToPhysicalIPhone();
        testIncompatibleLegacySelectionMigratesToPhysicalDevice();
        testCompatibleCustomSelectionRemainsSelected();
        testGraphicsCapabilityFailureOffersPhysicalRecovery();
    }
    return 0;
}
