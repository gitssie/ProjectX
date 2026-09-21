#import "ProfileManifest.h"
#import "DeviceModelManager.h"
#import "GraphicsIdentity.h"
#import "IOSVersionInfo.h"
#import "NetworkIdentity.h"
#import "PXEnvironmentModelSelection.h"
#import "PXEnvironmentPolicy.h"

#include <assert.h>

static PXProfileGenerationInput *fixedGenerationInput(void) {
    const uint8_t seedBytes[] = {
        0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
        0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f
    };
    PXProfileGenerationInput *input = [[PXProfileGenerationInput alloc] init];
    input.seed = [NSData dataWithBytes:seedBytes length:sizeof(seedBytes)];
    input.generatedAt = [NSDate dateWithTimeIntervalSince1970:1700000000];
    input.modelCatalog = @[@{
        @"identifier": @"iPhone13,2",
        @"name": @"iPhone 12",
        @"productType": @"iPhone13,2",
        @"hwModel": @"D53gAP",
        @"boardID": @"D53gAP",
        @"screenResolution": @"2532x1170",
        @"viewportResolution": @"2532x1170",
        @"devicePixelRatio": @3,
        @"screenDensity": @460,
        @"cpuArchitecture": @"Apple A14 Bionic",
        @"cpuCoreCount": @6,
        @"deviceMemory": @4,
        @"gpuFamily": @"Apple A14 GPU",
        @"metalFeatureSet": @"Metal 3.0",
        @"webGLInfo": @{
            @"unmaskedVendor": @"Apple Inc.", @"unmaskedRenderer": @"Apple A14 GPU",
            @"webglVendor": @"Apple", @"webglRenderer": @"Apple GPU",
            @"webglVersion": @"WebGL 2.0", @"maxTextureSize": @16384,
            @"maxRenderBufferSize": @16384
        },
        @"supports5G": @YES,
        @"supportedStorageCapacities": @[@64, @128, @256],
        @"supportedIOSMajorVersions": @[@16, @17]
    }];
    input.physicalModelRecord = input.modelCatalog.firstObject;
    input.iOSCatalog = @[@{
        @"version": @"16.5",
        @"majorVersion": @16,
        @"build": @"20F66",
        @"kernel_version": @"Darwin Kernel Version 22.5.0",
        @"darwin": @"22.5.0",
        @"xnu": @"8796.121.2~5"
    }];
    input.carrierCatalog = @[@{
        @"carrierID": @"fr-orange-208-01",
        @"country": @"France",
        @"isoCountryCode": @"fr",
        @"name": @"Orange",
        @"mcc": @"208",
        @"mnc": @"01",
        @"supportedRadioTechnologies": @[
            @"CTRadioAccessTechnologyLTE",
            @"CTRadioAccessTechnologyNRNSA",
            @"CTRadioAccessTechnologyNR"
        ]
    }];
    input.pinnedLocation = @{@"latitude": @48.8566, @"longitude": @2.3522, @"pinned": @YES};
    input.region = @{};
    input.graphicsHostCapabilities = @{
        @"metalFamilies": @[@1001, @1002, @1003, @1004, @1005, @1006, @1007, @1008],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9,
                                @10, @11, @12, @13, @14, @15, @16],
        @"maxTextureSize": @16384,
        @"maxRenderbufferSize": @16384,
        @"supportsOpenGLES3": @YES
    };
    return input;
}

static uint64_t fingerprintJSV1Composite(NSUUID *vendorIdentifier) {
    NSArray<NSString *> *components = @[
        @"iPhone",
        @"D53gAP",
        @"{{0, 0}, {1170, 2532}}",
        @"4294967296",
        @"6",
        @"22.5.0",
        @"Darwin",
        @"20F66",
        @"Darwin Kernel Version 22.5.0",
        vendorIdentifier.UUIDString ?: @""
    ];
    uint64_t hash = UINT64_C(1469598103934665603);
    for (NSString *component in components) {
        NSData *data = [component dataUsingEncoding:NSASCIIStringEncoding];
        const uint8_t *bytes = data.bytes;
        for (NSUInteger index = 0; index < data.length; index++) {
            hash ^= bytes[index];
            hash *= UINT64_C(1099511628211);
        }
    }
    return hash;
}

static void testSelectedTargetVendorIdentityIsStableAndChangesWithGeneration(void) {
    NSString *bundleIdentifier = @"com.fingerprintjs.DemoApp";
    PXProfileGenerationInput *firstInput = fixedGenerationInput();
    firstInput.appBundleIdentifiers = [NSSet setWithObject:bundleIdentifier];
    PXProfileManifest *first = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:firstInput
        error:nil];
    NSUUID *firstVendorIdentifier = PXProfileVendorIdentifierForBundleIdentifier(
        first,
        bundleIdentifier);
    assert(firstVendorIdentifier != nil);
    assert([firstVendorIdentifier isEqual:
        PXProfileVendorIdentifierForBundleIdentifier(first, bundleIdentifier)]);
    assert(PXProfileVendorIdentifierForBundleIdentifier(first, @"com.example.unselected") == nil);

    PXProfileGenerationInput *secondInput = fixedGenerationInput();
    secondInput.seed = [@"a different valid generation seed" dataUsingEncoding:NSUTF8StringEncoding];
    secondInput.generatedAt = [firstInput.generatedAt dateByAddingTimeInterval:60];
    secondInput.appBundleIdentifiers = [NSSet setWithObject:bundleIdentifier];
    PXProfileManifest *second = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:secondInput
        error:nil];
    NSUUID *secondVendorIdentifier = PXProfileVendorIdentifierForBundleIdentifier(
        second,
        bundleIdentifier);
    assert(secondVendorIdentifier != nil);
    assert(![firstVendorIdentifier isEqual:secondVendorIdentifier]);
    assert(fingerprintJSV1Composite(firstVendorIdentifier) ==
        fingerprintJSV1Composite(firstVendorIdentifier));
    assert(fingerprintJSV1Composite(firstVendorIdentifier) !=
        fingerprintJSV1Composite(secondVendorIdentifier));

    NSMutableDictionary<NSString *, id> *incomplete =
        [[first propertyListRepresentation] mutableCopy];
    NSMutableDictionary<NSString *, id> *identifiers = [incomplete[@"identifiers"] mutableCopy];
    [identifiers removeObjectForKey:@"idfv"];
    incomplete[@"identifiers"] = identifiers;
    assert([PXProfileManifest manifestWithPropertyList:incomplete error:nil] == nil);
    assert(PXProfileVendorIdentifierForBundleIdentifier(nil, bundleIdentifier) == nil);
}

static void testTrustedCarrierSetRestrictsDeterministicGeneration(void) {
    PXProfileGenerationInput *input = fixedGenerationInput();
    NSDictionary<NSString *, id> *sfr = @{
        @"carrierID": @"fr-sfr-208-10",
        @"country": @"France",
        @"isoCountryCode": @"fr",
        @"name": @"SFR",
        @"mcc": @"208",
        @"mnc": @"10",
        @"supportedRadioTechnologies": @[@"CTRadioAccessTechnologyLTE", @"CTRadioAccessTechnologyNR"]
    };
    input.carrierCatalog = [input.carrierCatalog arrayByAddingObject:sfr];
    input.trustedCarrierIDs = [NSSet setWithObject:@"fr-sfr-208-10"];

    PXProfileGenerator *generator = [[PXProfileGenerator alloc] init];
    PXProfileManifest *first = [generator generateManifestWithInput:input error:nil];
    PXProfileManifest *second = [generator generateManifestWithInput:input error:nil];
    assert([first.network[@"carrierID"] isEqualToString:@"fr-sfr-208-10"]);
    assert([first.network isEqualToDictionary:second.network]);
}

static void testPendingNetworkTypeControlsGeneratedTransportAndRadio(void) {
    PXProfileGenerationInput *wifiInput = fixedGenerationInput();
    wifiInput.networkType = PXEnvironmentNetworkTypeWiFi;
    PXProfileManifest *wifi = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:wifiInput
        error:nil];
    assert([wifi.network[@"transport"] isEqualToString:@"wifi"]);
    assert([wifi.network[@"localIPAddress"] hasPrefix:@"192.168."]);
    assert(PXNetworkIdentityIsCoherent(wifi.network));

    PXProfileGenerationInput *fourGInput = fixedGenerationInput();
    fourGInput.networkType = PXEnvironmentNetworkType4GLTE;
    PXProfileManifest *fourG = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fourGInput
        error:nil];
    assert([fourG.network[@"transport"] isEqualToString:@"cellular"]);
    assert([fourG.network[@"radioTechnology"] isEqualToString:@"CTRadioAccessTechnologyLTE"]);
    assert([fourG.network[@"localIPAddress"] hasPrefix:@"10."]);
    assert([fourG.network[@"cellularSignalBars"] integerValue] >= 1);
    assert([fourG.network[@"cellularSignalBars"] integerValue] <= 5);
    assert(PXNetworkIdentityIsCoherent(fourG.network));

    PXProfileGenerationInput *fiveGInput = fixedGenerationInput();
    fiveGInput.networkType = PXEnvironmentNetworkType5GNR;
    PXProfileManifest *fiveG = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fiveGInput
        error:nil];
    assert([fiveG.network[@"transport"] isEqualToString:@"cellular"]);
    NSArray<NSString *> *fiveGRadioTechnologies = @[
        @"CTRadioAccessTechnologyNR",
        @"CTRadioAccessTechnologyNRNSA"
    ];
    assert([fiveGRadioTechnologies containsObject:fiveG.network[@"radioTechnology"]]);

    PXProfileGenerationInput *threeGInput = fixedGenerationInput();
    threeGInput.networkType = PXEnvironmentNetworkType3G;
    PXProfileManifest *threeG = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:threeGInput
        error:nil];
    assert([threeG.network[@"radioTechnology"] isEqualToString:@"CTRadioAccessTechnologyWCDMA"]);

    PXProfileGenerationInput *offlineInput = fixedGenerationInput();
    offlineInput.networkType = PXEnvironmentNetworkTypeNone;
    PXProfileManifest *offline = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:offlineInput
        error:nil];
    assert([offline.network[@"transport"] isEqualToString:@"none"]);
    assert([offline.network[@"radioTechnology"] isEqualToString:@""]);
    assert([offline.network[@"localIPAddress"] isEqualToString:@""]);
    assert([offline.network[@"ssid"] isEqualToString:@""]);
}

static void testUnsupportedPending5GModelFailsClosed(void) {
    PXProfileGenerationInput *input = fixedGenerationInput();
    NSMutableDictionary<NSString *, id> *legacyModel = [input.modelCatalog.firstObject mutableCopy];
    legacyModel[@"supports5G"] = @NO;
    input.modelCatalog = @[[legacyModel copy]];
    input.networkType = PXEnvironmentNetworkType5GNR;
    NSError *error = nil;
    assert([[[PXProfileGenerator alloc] init] generateManifestWithInput:input error:&error] == nil);
    assert(error != nil);
}

static void testIncompatibleIPhoneFourteenProIsRejectedBeforeProfileGeneration(void) {
    PXProfileGenerationInput *input = fixedGenerationInput();
    NSMutableDictionary<NSString *, id> *capturedModel = [input.modelCatalog.firstObject mutableCopy];
    capturedModel[@"identifier"] = @"iPhone15,2";
    capturedModel[@"name"] = @"iPhone 14 Pro";
    capturedModel[@"productType"] = @"iPhone15,2";
    capturedModel[@"hwModel"] = @"D73AP";
    capturedModel[@"boardID"] = @"D73AP";
    capturedModel[@"screenResolution"] = @"2556x1179";
    capturedModel[@"viewportResolution"] = @"2556x1179";
    capturedModel[@"screenDensity"] = @460;
    capturedModel[@"cpuArchitecture"] = @"Apple A16 Bionic";
    capturedModel[@"cpuCoreCount"] = @6;
    capturedModel[@"deviceMemory"] = @6;
    capturedModel[@"gpuFamily"] = @"Apple A16 Pro GPU";
    capturedModel[@"metalFeatureSet"] = @"Metal 3.1";
    capturedModel[@"webGLInfo"] = @{
        @"unmaskedVendor": @"Apple Inc.",
        @"unmaskedRenderer": @"Apple A16 Pro GPU",
        @"webglVendor": @"Apple",
        @"webglRenderer": @"Apple GPU",
        @"webglVersion": @"WebGL 2.0",
        @"maxTextureSize": @16384,
        @"maxRenderBufferSize": @16384
    };
    capturedModel[@"supports5G"] = @YES;
    capturedModel[@"supportedStorageCapacities"] = @[@128, @256, @512, @1024];
    capturedModel[@"supportedIOSMajorVersions"] = @[@16, @17, @18];
    input.modelCatalog = @[[capturedModel copy]];
    NSMutableDictionary<NSString *, id> *physicalModel =
        [input.physicalModelRecord mutableCopy];
    physicalModel[@"identifier"] = @"iPhone9,2";
    physicalModel[@"productType"] = @"iPhone9,2";
    physicalModel[@"name"] = @"iPhone 7 Plus";
    physicalModel[@"hwModel"] = @"D11AP";
    physicalModel[@"boardID"] = @"D11AP";
    physicalModel[@"screenResolution"] = @"1920x1080";
    physicalModel[@"viewportResolution"] = @"2208x1242";
    physicalModel[@"screenDensity"] = @401;
    physicalModel[@"cpuArchitecture"] = @"Apple A10 Fusion";
    physicalModel[@"cpuCoreCount"] = @4;
    physicalModel[@"deviceMemory"] = @3;
    physicalModel[@"gpuFamily"] = @"Apple A10 GPU";
    physicalModel[@"metalFeatureSet"] = @"Metal 2.2";
    physicalModel[@"webGLInfo"] = @{
        @"unmaskedVendor": @"Apple Inc.",
        @"unmaskedRenderer": @"Apple A10 GPU",
        @"webglVendor": @"Apple",
        @"webglRenderer": @"Apple GPU",
        @"webglVersion": @"WebGL 2.0",
        @"maxTextureSize": @16384,
        @"maxRenderBufferSize": @16384
    };
    physicalModel[@"supports5G"] = @NO;
    physicalModel[@"supportedStorageCapacities"] = @[@32, @128, @256];
    physicalModel[@"supportedIOSMajorVersions"] = @[@15];
    input.physicalModelRecord = [physicalModel copy];
    input.networkType = PXEnvironmentNetworkType4GLTE;
    input.graphicsHostCapabilities = @{
        @"metalFamilies": @[@1001, @1002, @1003],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @12, @13, @14],
        @"maxTextureSize": @16384,
        @"maxRenderbufferSize": @16384,
        @"supportsOpenGLES3": @YES
    };

    NSError *error = nil;
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:input
        error:&error];

    assert(manifest == nil);
    assert([error.domain isEqualToString:PXModelCompatibilityErrorDomain]);
    assert(error.code == PXModelCompatibilityErrorImmutableHardwareMismatch);
    assert([error.userInfo[PXModelCompatibilityMismatchFieldsErrorKey]
        containsObject:PXModelCompatibilityFieldGraphicsClass]);
}

static void testPhysicalModeWithUnavailableGraphicsProbeProducesValidManifest(void) {
    PXProfileGenerationInput *input = fixedGenerationInput();
    NSMutableDictionary<NSString *, id> *physicalModel = [input.modelCatalog.firstObject mutableCopy];
    physicalModel[@"identifier"] = @"iPhone9,2";
    physicalModel[@"productType"] = @"iPhone9,2";
    physicalModel[@"name"] = @"iPhone 7 Plus";
    physicalModel[@"hwModel"] = @"D11AP";
    physicalModel[@"boardID"] = @"D11AP";
    physicalModel[@"screenResolution"] = @"1920x1080";
    physicalModel[@"viewportResolution"] = @"2208x1242";
    physicalModel[@"screenDensity"] = @401;
    physicalModel[@"cpuArchitecture"] = @"Apple A10 Fusion";
    physicalModel[@"cpuCoreCount"] = @4;
    physicalModel[@"deviceMemory"] = @3;
    physicalModel[@"gpuFamily"] = @"Apple A10 GPU";
    physicalModel[@"metalFeatureSet"] = @"Metal 2.2";
    physicalModel[@"webGLInfo"] = @{
        @"unmaskedVendor": @"Apple Inc.",
        @"unmaskedRenderer": @"Apple A10 GPU",
        @"webglVendor": @"Apple",
        @"webglRenderer": @"Apple GPU",
        @"webglVersion": @"WebGL 2.0",
        @"maxTextureSize": @16384,
        @"maxRenderBufferSize": @16384
    };
    physicalModel[@"supports5G"] = @NO;
    physicalModel[@"supportedStorageCapacities"] = @[@32, @128, @256];
    physicalModel[@"supportedIOSMajorVersions"] = @[@15];
    input.modelCatalog = @[[physicalModel copy]];
    input.physicalModelRecord = [physicalModel copy];
    input.usesPhysicalDeviceModel = YES;
    NSMutableArray<NSDictionary<NSString *, id> *> *iOSCatalog = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *tuple in [[IOSVersionInfo sharedManager] availableIOSVersions]) {
        NSMutableDictionary<NSString *, id> *enrichedTuple = [tuple mutableCopy];
        enrichedTuple[@"majorVersion"] = @([[tuple[@"version"] componentsSeparatedByString:@"."].firstObject integerValue]);
        [iOSCatalog addObject:[enrichedTuple copy]];
    }
    input.iOSCatalog = [iOSCatalog copy];
    input.networkType = PXEnvironmentNetworkType4GLTE;
    input.graphicsHostCapabilities = @{
        @"metalFamilies": @[],
        @"metalFeatureSets": @[],
        @"maxTextureSize": @0,
        @"maxRenderbufferSize": @0,
        @"supportsOpenGLES3": @NO
    };

    NSError *error = nil;
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:input
        error:&error];

    assert(error == nil);
    assert(manifest != nil);
    assert([manifest.device[@"identifier"] isEqualToString:@"iPhone9,2"]);
    assert([manifest.operatingSystem[@"version"] isEqualToString:@"15.8.8"]);
    assert([manifest.operatingSystem[@"build"] isEqualToString:@"19H422"]);
    assert([manifest.operatingSystem[@"darwin"] isEqualToString:@"21.6.0"]);
    assert([manifest.operatingSystem[@"xnu"] isEqualToString:@"8020.241.44~1"]);
    assert([manifest.graphics[@"gpuFamily"] isEqualToString:@"Apple A10 GPU"]);
    assert([manifest.graphics[@"hostCapabilities"] isEqualToDictionary:input.graphicsHostCapabilities]);
    assert([manifest validateWithError:&error]);
    assert(error == nil);
}

static void testProductionIPhoneSevenPlusPhysicalPathReplacesEmptyLegacyProjection(void) {
    NSString *profileDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *identityDirectory = [profileDirectory stringByAppendingPathComponent:@"identity"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    assert([@{} writeToFile:[identityDirectory stringByAppendingPathComponent:@"device_ids.plist"]
                 atomically:YES]);

    DeviceModelManager *deviceManager = [[DeviceModelManager alloc] init];
    NSDictionary<NSString *, id> *physicalModelRecord =
        [deviceManager deviceSpecificationsForModel:@"iPhone9,2"];
    assert(physicalModelRecord != nil);

    PXEnvironmentPolicyStore *policyStore = [[PXEnvironmentPolicyStore alloc]
        initWithFilePath:[profileDirectory stringByAppendingPathComponent:@"pending_environment.plist"]];
    NSError *error = nil;
    assert([policyStore savePhysicalDeviceModelRecord:physicalModelRecord error:&error]);
    assert(error == nil);

    PXProfileStore *profileStore = [[PXProfileStore alloc]
        initWithIdentityDirectory:identityDirectory];
    assert([profileStore migrateLegacyProfileIfNeededWithError:&error]);
    assert(error == nil);

    NSDictionary<NSString *, id> *unavailableHostCapabilities = @{
        @"metalFamilies": @[],
        @"metalFeatureSets": @[],
        @"maxTextureSize": @0,
        @"maxRenderbufferSize": @0,
        @"supportsOpenGLES3": @NO
    };
    NSDictionary<NSString *, id> *resolvedModelRecord = PXResolveEnvironmentModelSelection(
        policyStore,
        [deviceManager allDeviceSpecificationRecords],
        physicalModelRecord,
        unavailableHostCapabilities,
        nil,
        &error);
    assert(error == nil);
    assert([resolvedModelRecord isEqualToDictionary:physicalModelRecord]);
    assert([policyStore selectedModelSelectionModeWithError:nil] ==
        PXEnvironmentModelSelectionModePhysicalDevice);

    PXProfileGenerationInput *input = fixedGenerationInput();
    input.modelCatalog = @[resolvedModelRecord];
    input.physicalModelRecord = physicalModelRecord;
    input.usesPhysicalDeviceModel = YES;
    NSMutableArray<NSDictionary<NSString *, id> *> *iOSCatalog = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *tuple in [[IOSVersionInfo sharedManager] availableIOSVersions]) {
        NSMutableDictionary<NSString *, id> *enrichedTuple = [tuple mutableCopy];
        enrichedTuple[@"majorVersion"] = @([[tuple[@"version"] componentsSeparatedByString:@"."].firstObject integerValue]);
        [iOSCatalog addObject:[enrichedTuple copy]];
    }
    input.iOSCatalog = [iOSCatalog copy];
    input.graphicsHostCapabilities = unavailableHostCapabilities;
    input.networkType = PXEnvironmentNetworkType4GLTE;

    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:input
        error:&error];
    assert(error == nil);
    assert(manifest != nil);
    NSArray<NSString *> *requiredDeviceFields = @[
        @"identifier", @"hwModel", @"boardID", @"screenResolution",
        @"cpuArchitecture", @"gpuFamily"
    ];
    for (NSString *field in requiredDeviceFields) {
        id value = manifest.device[field];
        assert([value isKindOfClass:[NSString class]]);
        assert([(NSString *)value length] > 0);
    }
    assert([manifest.device[@"identifier"] isEqualToString:@"iPhone9,2"]);
    assert([manifest validateWithError:&error]);
    assert(error == nil);
    assert([profileStore promoteManifest:manifest error:&error]);
    assert(error == nil);

    PXProfileManifest *activeManifest = [profileStore activeManifestWithError:&error];
    assert(error == nil);
    assert(activeManifest != nil);
    for (NSString *field in requiredDeviceFields) {
        id value = activeManifest.device[field];
        assert([value isKindOfClass:[NSString class]]);
        assert([(NSString *)value length] > 0);
    }
    assert([activeManifest.device[@"identifier"] isEqualToString:@"iPhone9,2"]);
    [[NSFileManager defaultManager] removeItemAtPath:profileDirectory error:nil];
}

static void testIncompleteProductionDeviceRecordNamesEveryInvalidField(void) {
    DeviceModelManager *deviceManager = [[DeviceModelManager alloc] init];
    NSDictionary<NSString *, id> *physicalModelRecord =
        [deviceManager deviceSpecificationsForModel:@"iPhone9,2"];
    assert(physicalModelRecord != nil);

    PXProfileGenerationInput *input = fixedGenerationInput();
    input.modelCatalog = @[physicalModelRecord];
    input.physicalModelRecord = physicalModelRecord;
    input.usesPhysicalDeviceModel = YES;
    NSMutableArray<NSDictionary<NSString *, id> *> *iOSCatalog = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *tuple in [[IOSVersionInfo sharedManager] availableIOSVersions]) {
        NSMutableDictionary<NSString *, id> *enrichedTuple = [tuple mutableCopy];
        enrichedTuple[@"majorVersion"] = @([[tuple[@"version"] componentsSeparatedByString:@"."].firstObject integerValue]);
        [iOSCatalog addObject:[enrichedTuple copy]];
    }
    input.iOSCatalog = [iOSCatalog copy];
    input.graphicsHostCapabilities = @{
        @"metalFamilies": @[],
        @"metalFeatureSets": @[],
        @"maxTextureSize": @0,
        @"maxRenderbufferSize": @0,
        @"supportsOpenGLES3": @NO
    };
    input.networkType = PXEnvironmentNetworkType4GLTE;

    PXProfileManifest *completeManifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:input
        error:nil];
    assert(completeManifest != nil);
    NSMutableDictionary<NSString *, id> *propertyList =
        [[completeManifest propertyListRepresentation] mutableCopy];
    NSMutableDictionary<NSString *, id> *incompleteDevice =
        [propertyList[@"device"] mutableCopy];
    [incompleteDevice removeObjectForKey:@"hwModel"];
    incompleteDevice[@"boardID"] = @"";
    [incompleteDevice removeObjectForKey:@"gpuFamily"];
    propertyList[@"device"] = [incompleteDevice copy];

    NSError *error = nil;
    assert([PXProfileManifest manifestWithPropertyList:propertyList error:&error] == nil);
    assert(error.code == 3);
    assert([error.localizedDescription isEqualToString:
        @"Selected device record has missing or invalid fields: hwModel, boardID, gpuFamily"]);
}

static void testPinnedCountryPreferenceNeverBreaksCarrierRegionCoherence(void) {
    NSDictionary<NSString *, id> *usCarrier = @{
        @"carrierID": @"us-att-310-410",
        @"country": @"United States",
        @"isoCountryCode": @"us",
        @"name": @"AT&T",
        @"mcc": @"310",
        @"mnc": @"410",
        @"supportedRadioTechnologies": @[@"CTRadioAccessTechnologyLTE", @"CTRadioAccessTechnologyNR"]
    };
    PXProfileGenerationInput *matchingInput = fixedGenerationInput();
    matchingInput.carrierCatalog = [matchingInput.carrierCatalog arrayByAddingObject:usCarrier];
    matchingInput.trustedCarrierIDs = [NSSet setWithObjects:@"fr-orange-208-01", @"us-att-310-410", nil];
    matchingInput.pinnedLocation = @{
        @"latitude": @48.8566,
        @"longitude": @2.3522,
        @"countryCode": @"FR",
        @"pinned": @YES
    };
    PXProfileManifest *matching = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:matchingInput
        error:nil];
    assert([matching.network[@"isoCountryCode"] isEqualToString:@"fr"]);
    assert([matching.region[@"countryCode"] isEqualToString:@"FR"]);
    assert([matching.location[@"latitude"] isEqual:@48.8566]);

    PXProfileGenerationInput *unmatchedInput = fixedGenerationInput();
    unmatchedInput.carrierCatalog = [unmatchedInput.carrierCatalog arrayByAddingObject:usCarrier];
    unmatchedInput.trustedCarrierIDs = [NSSet setWithObject:@"us-att-310-410"];
    unmatchedInput.pinnedLocation = matchingInput.pinnedLocation;
    PXProfileManifest *unmatched = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:unmatchedInput
        error:nil];
    assert([unmatched.network[@"isoCountryCode"] isEqualToString:@"us"]);
    assert([unmatched.region[@"countryCode"] isEqualToString:@"US"]);
    assert([unmatched.location isEqualToDictionary:matchingInput.pinnedLocation]);
}

static void testGeneratedManifestUsesPerAppAndPerGroupIdentityMaps(void) {
    PXProfileGenerationInput *input = fixedGenerationInput();
    input.appBundleIdentifiers = [NSSet setWithObjects:@"com.example.app", @"com.example.app.extension", nil];
    input.appGroupIdentifiers = [NSSet setWithObject:@"group.com.example.shared"];
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:input
        error:nil];

    PXAppIdentityRecord *mainIdentity = manifest.appIdentities[@"com.example.app"];
    PXAppIdentityRecord *extensionIdentity = manifest.appIdentities[@"com.example.app.extension"];
    PXAppGroupIdentityRecord *groupIdentity = manifest.appGroupIdentities[@"group.com.example.shared"];
    assert(manifest.schemaVersion == 5);
    assert(mainIdentity != nil);
    assert(extensionIdentity != nil);
    assert(groupIdentity != nil);
    assert(![mainIdentity.containerUUID isEqualToString:extensionIdentity.containerUUID]);
    assert(manifest.identifiers[@"appInstallUUID"] == nil);
    assert(manifest.identifiers[@"appContainerUUID"] == nil);
    assert(manifest.identifiers[@"appGroupUUID"] == nil);
}

static void testFixedSeedProducesStableManifest(void) {
    PXProfileGenerator *generator = [[PXProfileGenerator alloc] init];
    NSError *firstError = nil;
    NSError *secondError = nil;
    PXProfileManifest *first = [generator generateManifestWithInput:fixedGenerationInput() error:&firstError];
    PXProfileManifest *second = [generator generateManifestWithInput:fixedGenerationInput() error:&secondError];

    assert(firstError == nil);
    assert(secondError == nil);
    assert(first != nil);
    assert([first.generationID isEqualToString:second.generationID]);
    assert([[first propertyListRepresentation] isEqualToDictionary:[second propertyListRepresentation]]);
    assert([first.location[@"latitude"] isEqual:@48.8566]);
    assert([first.region[@"countryCode"] isEqualToString:@"FR"]);
    assert([first.region[@"primaryLanguageTag"] isEqualToString:@"fr-FR"]);
    assert([first.region[@"preferredLanguages"] isEqualToArray:@[@"fr-FR"]]);
    assert([first.region[@"localeIdentifier"] isEqualToString:@"fr_FR"]);
    assert([first.region[@"currencyCode"] isEqualToString:@"EUR"]);
    assert([first.region[@"timeZone"] isEqualToString:@"Europe/Paris"]);
    assert([first.region[@"calendarIdentifier"] isEqualToString:@"gregorian"]);
    assert([first.device[@"identifier"] isEqualToString:@"iPhone13,2"]);
    assert([first.operatingSystem[@"build"] isEqualToString:@"20F66"]);
}

static void testGeneratedManifestSatisfiesCrossFieldInvariants(void) {
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    NSError *validationError = nil;

    assert([manifest validateWithError:&validationError]);
    assert(validationError == nil);
    assert([manifest.device[@"supportedIOSMajorVersions"] containsObject:manifest.operatingSystem[@"majorVersion"]]);
    assert([manifest.network[@"supportedRadioTechnologies"] containsObject:manifest.network[@"radioTechnology"]]);
    PXGraphicsIdentity *graphics = [PXGraphicsIdentity identityWithPropertyList:manifest.graphics error:nil];
    assert(graphics != nil);
    assert([graphics.modelIdentifier isEqualToString:manifest.device[@"identifier"]]);
    assert([graphics.gpuName isEqualToString:manifest.device[@"gpuFamily"]]);
    assert([graphics.generationID isEqualToString:manifest.generationID]);
}

static void testInternallyIncoherentGraphicsModelIsRejectedBeforeManifestActivation(void) {
    PXProfileGenerationInput *input = fixedGenerationInput();
    NSMutableDictionary *incompatibleModel = [input.modelCatalog.firstObject mutableCopy];
    incompatibleModel[@"identifier"] = @"iPhone16,1";
    incompatibleModel[@"gpuFamily"] = @"Apple A17 Pro GPU";
    incompatibleModel[@"metalFeatureSet"] = @"Metal 2.2";
    input.modelCatalog = @[[incompatibleModel copy]];
    input.graphicsHostCapabilities = @{
        @"metalFamilies": @[@1001, @1002, @1003, @1004, @1005, @1006, @1007],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9,
                                @10, @11, @12, @13, @14, @15, @16],
        @"maxTextureSize": @8192,
        @"maxRenderbufferSize": @8192,
        @"supportsOpenGLES3": @YES
    };
    NSError *error = nil;
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:input
        error:&error];
    assert(manifest == nil);
    assert([error.domain isEqualToString:PXGraphicsIdentityErrorDomain]);
    assert(error.code == 1);
}

static void testManifestDeclaresFieldSourcesAndCreatesVirtualRuntimeSession(void) {
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    NSDictionary<NSString *, id> *propertyList = [manifest propertyListRepresentation];

    assert([manifest.fieldSourcePolicy[@"stableSyntheticIdentity"] isEqualToString:@"profile"]);
    assert([manifest.fieldSourcePolicy[@"bootUUID"] isEqualToString:@"virtualSession"]);
    assert([manifest.fieldSourcePolicy[@"bootTime"] isEqualToString:@"virtualSession"]);
    assert([manifest.fieldSourcePolicy[@"modelAndOSValues"] isEqualToString:@"derived"]);
    assert([manifest.fieldSourcePolicy[@"location"] isEqualToString:@"controlled"]);
    assert([manifest.fieldSourcePolicy[@"network"] isEqualToString:@"controlled"]);
    assert([manifest.fieldSourcePolicy[@"region"] isEqualToString:@"derivedFromCarrier"]);
    assert([[NSUUID alloc] initWithUUIDString:manifest.virtualSession.bootUUID] != nil);
    assert([propertyList[@"virtualSession"][@"bootUUID"] isEqualToString:manifest.virtualSession.bootUUID]);
    assert([propertyList[@"virtualSession"][@"bootTime"] isKindOfClass:[NSDate class]]);
    assert(manifest.identifiers[@"systemBootUUID"] == nil);
}

static void testFailedPromotionLeavesPreviousGenerationActive(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *directoryError = nil;
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&directoryError]);
    assert(directoryError == nil);

    PXProfileGenerator *generator = [[PXProfileGenerator alloc] init];
    PXProfileGenerationInput *firstInput = fixedGenerationInput();
    PXProfileManifest *first = [generator generateManifestWithInput:firstInput error:nil];
    PXProfileGenerationInput *secondInput = fixedGenerationInput();
    NSMutableData *secondSeed = [secondInput.seed mutableCopy];
    ((uint8_t *)secondSeed.mutableBytes)[0] ^= 0xff;
    secondInput.seed = secondSeed;
    PXProfileManifest *second = [generator generateManifestWithInput:secondInput error:nil];

    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:first error:nil]);
    store.failBeforePromotionForTesting = YES;
    assert(![store promoteManifest:second error:nil]);

    PXProfileManifest *active = [store activeManifestWithError:nil];
    NSDictionary *deviceProjection = [NSDictionary dictionaryWithContentsOfFile:
        [identityDirectory stringByAppendingPathComponent:@"device_model.plist"]];
    NSDictionary *bootUUIDProjection = [NSDictionary dictionaryWithContentsOfFile:
        [identityDirectory stringByAppendingPathComponent:@"system_boot_uuid.plist"]];
    NSDictionary *deviceIDsProjection = [NSDictionary dictionaryWithContentsOfFile:
        [identityDirectory stringByAppendingPathComponent:@"device_ids.plist"]];
    assert([active.generationID isEqualToString:first.generationID]);
    assert([deviceProjection[@"generationID"] isEqualToString:first.generationID]);
    assert([bootUUIDProjection[@"value"] isEqualToString:first.virtualSession.bootUUID]);
    assert([deviceIDsProjection[@"GraphicsGenerationID"] isEqualToString:first.generationID]);
    assert([deviceIDsProjection[@"GPUName"] isEqualToString:first.graphics[@"gpuName"]]);
    assert([deviceIDsProjection[@"MetalFamilies"] isEqualToArray:first.graphics[@"metalFamilies"]]);
    assert([deviceIDsProjection[@"WebGLInfo"] isEqualToDictionary:first.graphics[@"webGL"]]);
    assert([deviceIDsProjection[@"OpenGLInfo"] isEqualToDictionary:first.graphics[@"openGL"]]);
    assert(![active.generationID isEqualToString:second.generationID]);

    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testGenerationIdentifierCannotReuseDifferentMaterializedValues(void) {
    NSString *identityDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);

    PXProfileGenerationInput *firstInput = fixedGenerationInput();
    PXProfileGenerationInput *conflictingInput = fixedGenerationInput();
    conflictingInput.generatedAt = [firstInput.generatedAt dateByAddingTimeInterval:60.0];
    PXProfileGenerator *generator = [[PXProfileGenerator alloc] init];
    PXProfileManifest *first = [generator generateManifestWithInput:firstInput error:nil];
    PXProfileManifest *conflicting = [generator
        generateManifestWithInput:conflictingInput
        error:nil];
    assert([first.generationID isEqualToString:conflicting.generationID]);
    assert(![[first propertyListRepresentation]
        isEqualToDictionary:[conflicting propertyListRepresentation]]);

    PXProfileStore *store = [[PXProfileStore alloc]
        initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:first error:nil]);
    assert([store promoteManifest:first error:nil]);
    NSError *promotionError = nil;
    assert(![store promoteManifest:conflicting error:&promotionError]);
    assert(promotionError != nil);
    assert(promotionError.code == 14);
    assert([promotionError.localizedDescription isEqualToString:
        @"Generation identifier already exists with different materialized values"]);
    PXProfileManifest *active = [store activeManifestWithError:nil];
    assert([[active propertyListRepresentation]
        isEqualToDictionary:[first propertyListRepresentation]]);
    NSArray<NSString *> *generationDirectories = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:[identityDirectory
            stringByAppendingPathComponent:@"profile_generations"]
        error:nil];
    assert(generationDirectories.count == 1);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testConcurrentPromotionsAreSerialized(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    PXProfileGenerator *generator = [[PXProfileGenerator alloc] init];
    NSMutableArray<PXProfileManifest *> *manifests = [NSMutableArray array];
    for (uint8_t mutation = 1; mutation <= 8; mutation++) {
        PXProfileGenerationInput *input = fixedGenerationInput();
        NSMutableData *seed = [input.seed mutableCopy];
        ((uint8_t *)seed.mutableBytes)[0] ^= mutation;
        input.seed = seed;
        [manifests addObject:[generator generateManifestWithInput:input error:nil]];
    }

    __block BOOL allSucceeded = YES;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (PXProfileManifest *manifest in manifests) {
        dispatch_group_async(group, queue, ^{
            PXProfileStore *concurrentStore = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
            if (![concurrentStore promoteManifest:manifest error:nil]) {
                @synchronized(store) {
                    allSucceeded = NO;
                }
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    PXProfileManifest *active = [store activeManifestWithError:nil];
    assert(allSucceeded);
    assert(active != nil);
    NSString *activeGenerationDirectory = [identityDirectory stringByAppendingPathComponent:@"profile_active"];
    NSArray<NSString *> *activeProjectionFileNames = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:activeGenerationDirectory
        error:nil];
    assert(activeProjectionFileNames.count >= 20);
    for (NSString *fileName in activeProjectionFileNames) {
        if (![[fileName pathExtension] isEqualToString:@"plist"]) continue;
        NSDictionary *projection = [NSDictionary dictionaryWithContentsOfFile:
            [identityDirectory stringByAppendingPathComponent:fileName]];
        assert([projection[@"generationID"] isEqualToString:active.generationID]);
    }
    NSDictionary *networkProjection = [NSDictionary dictionaryWithContentsOfFile:
        [identityDirectory stringByAppendingPathComponent:@"network_settings.plist"]];
    NSDictionary *carrierProjection = [NSDictionary dictionaryWithContentsOfFile:
        [identityDirectory stringByAppendingPathComponent:@"carrier_details.plist"]];
    assert([networkProjection[@"carrierID"] isEqualToString:active.network[@"carrierID"]]);
    assert([networkProjection[@"serviceIdentifier"] isEqualToString:active.network[@"serviceIdentifier"]]);
    assert([networkProjection[@"radioTechnology"] isEqualToString:active.network[@"radioTechnology"]]);
    assert([carrierProjection[@"carrierID"] isEqualToString:active.network[@"carrierID"]]);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testMixedGenerationProjectionIsRejectedWithoutRepair(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    PXProfileManifest *manifest = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:manifest error:nil]);

    NSString *networkPath = [identityDirectory stringByAppendingPathComponent:@"network_settings.plist"];
    NSMutableDictionary *networkProjection = [NSMutableDictionary dictionaryWithContentsOfFile:networkPath];
    networkProjection[@"generationID"] = NSUUID.UUID.UUIDString;
    assert([networkProjection writeToFile:networkPath atomically:YES]);

    NSError *readError = nil;
    assert([store activeManifestWithError:&readError] == nil);
    assert(readError != nil);
    NSDictionary *unchangedCorruption = [NSDictionary dictionaryWithContentsOfFile:networkPath];
    assert([unchangedCorruption[@"generationID"] isEqualToString:networkProjection[@"generationID"]]);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testLegacyMigrationPreservesValuesAndIsIdempotent(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    PXProfileManifest *source = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];

    NSMutableDictionary *legacyDevice = [source.device mutableCopy];
    legacyDevice[@"value"] = source.device[@"identifier"];
    [legacyDevice writeToFile:[identityDirectory stringByAppendingPathComponent:@"device_model.plist"] atomically:YES];
    [source.operatingSystem writeToFile:[identityDirectory stringByAppendingPathComponent:@"ios_version.plist"] atomically:YES];
    NSMutableDictionary *legacyNetwork = [source.network mutableCopy];
    [legacyNetwork removeObjectForKey:@"ssid"];
    [legacyNetwork removeObjectForKey:@"bssid"];
    [legacyNetwork writeToFile:[identityDirectory stringByAppendingPathComponent:@"network_settings.plist"] atomically:YES];
    [@{
        @"IDFA": source.identifiers[@"idfa"],
        @"IDFV": source.identifiers[@"idfv"],
        @"DyldCacheUUID": source.identifiers[@"dyldCacheUUID"],
        @"PasteboardUUID": source.identifiers[@"pasteboardUUID"],
        @"KeychainUUID": source.identifiers[@"keychainUUID"],
        @"UserDefaultsUUID": source.identifiers[@"userDefaultsUUID"],
        @"AppGroupUUID": NSUUID.UUID.UUIDString,
        @"CoreDataUUID": source.identifiers[@"coreDataUUID"],
        @"AppInstallUUID": NSUUID.UUID.UUIDString,
        @"AppContainerUUID": NSUUID.UUID.UUIDString,
        @"DeviceName": @"Legacy User's iPhone",
        @"SerialNumber": source.identifiers[@"serialNumber"],
        @"IMEI": source.identifiers[@"imei"],
        @"MEID": source.identifiers[@"meid"]
    } writeToFile:[identityDirectory stringByAppendingPathComponent:@"device_ids.plist"] atomically:YES];
    [@{@"ssid": @"Legacy WiFi", @"bssid": @"00:11:22:33:44:55"} writeToFile:
        [identityDirectory stringByAppendingPathComponent:@"wifi_info.plist"] atomically:YES];
    [source.location writeToFile:[identityDirectory stringByAppendingPathComponent:@"location.plist"] atomically:YES];
    NSArray<NSString *> *retiredAppIdentityFiles = @[
        @"appgroup_uuid.plist",
        @"appinstall_uuid.plist",
        @"appcontainer_uuid.plist"
    ];
    for (NSString *fileName in retiredAppIdentityFiles) {
        [@{@"value": NSUUID.UUID.UUIDString} writeToFile:
            [identityDirectory stringByAppendingPathComponent:fileName]
            atomically:YES];
    }

    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store migrateLegacyProfileIfNeededWithError:nil]);
    PXProfileManifest *firstRead = [store activeManifestWithError:nil];
    assert([firstRead.device[@"identifier"] isEqualToString:source.device[@"identifier"]]);
    assert([firstRead.network[@"carrierName"] isEqualToString:source.network[@"carrierName"]]);
    assert([firstRead.identifiers[@"idfa"] isEqualToString:source.identifiers[@"idfa"]]);
    assert([firstRead.identifiers[@"deviceName"] isEqualToString:@"Legacy User's iPhone"]);
    assert([firstRead.network[@"ssid"] isEqualToString:@"Legacy WiFi"]);
    assert([firstRead.location[@"latitude"] isEqual:source.location[@"latitude"]]);
    assert(firstRead.schemaVersion == 5);
    assert(firstRead.appIdentities.count == 0);
    assert(firstRead.appGroupIdentities.count == 0);
    assert(firstRead.identifiers[@"appInstallUUID"] == nil);
    for (NSString *fileName in retiredAppIdentityFiles) {
        assert(![[NSFileManager defaultManager] fileExistsAtPath:
            [identityDirectory stringByAppendingPathComponent:fileName]]);
    }

    assert([store migrateLegacyProfileIfNeededWithError:nil]);
    PXProfileManifest *secondRead = [store activeManifestWithError:nil];
    assert([firstRead.generationID isEqualToString:secondRead.generationID]);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testAddingScopedAppIdentityDoesNotRegenerateDeviceOrNetwork(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXProfileManifest *source = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:source error:nil]);
    NSDictionary<NSString *, id> *regionProjection = [NSDictionary dictionaryWithContentsOfFile:
        [identityDirectory stringByAppendingPathComponent:@"region.plist"]];
    assert([regionProjection[@"generationID"] isEqualToString:source.generationID]);
    assert([regionProjection[@"value"] isEqualToDictionary:source.region]);

    NSSet<NSString *> *groups = [NSSet setWithObject:@"group.com.example.shared"];
    NSSet<NSString *> *installKeys = [NSSet setWithObject:@"vendor_first_launch_token"];
    assert([store ensureApplicationIdentityForBundleIdentifier:@"com.example.app"
                                              groupIdentifiers:groups
                                         installIdentifierKeys:installKeys
                                                          error:nil]);
    PXProfileManifest *updated = [store activeManifestWithError:nil];
    assert([updated.generationID isEqualToString:source.generationID]);
    assert([updated.device isEqualToDictionary:source.device]);
    assert([updated.network isEqualToDictionary:source.network]);
    assert(updated.appIdentities[@"com.example.app"] != nil);
    assert(updated.appGroupIdentities[@"group.com.example.shared"] != nil);

    NSDictionary *firstUpdate = [updated propertyListRepresentation];
    assert([store ensureApplicationIdentityForBundleIdentifier:@"com.example.app"
                                              groupIdentifiers:groups
                                         installIdentifierKeys:installKeys
                                                          error:nil]);
    assert([[[store activeManifestWithError:nil] propertyListRepresentation] isEqualToDictionary:firstUpdate]);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testActiveApplicationIdentityMapCanBePrunedAndRestoredWithoutChangingProfile(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXProfileGenerationInput *input = fixedGenerationInput();
    input.appBundleIdentifiers = [NSSet setWithArray:@[
        @"com.example.installed",
        @"com.example.deleted"
    ]];
    input.appGroupIdentifiers = [NSSet setWithObject:@"group.com.example.shared"];
    PXProfileManifest *source = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:input
        error:nil];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:source error:nil]);
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *originalIdentities =
        [store activeApplicationIdentityPropertyListsWithError:nil];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *remainingIdentities =
        [originalIdentities mutableCopy];
    [remainingIdentities removeObjectForKey:@"com.example.deleted"];

    assert([store replaceActiveApplicationIdentityPropertyLists:remainingIdentities error:nil]);

    PXProfileManifest *pruned = [store activeManifestWithError:nil];
    assert(pruned.appIdentities[@"com.example.deleted"] == nil);
    assert(pruned.appIdentities[@"com.example.installed"] != nil);
    assert([[pruned propertyListRepresentation][@"appGroupIdentities"]
        isEqualToDictionary:[source propertyListRepresentation][@"appGroupIdentities"]]);
    assert([pruned.generationID isEqualToString:source.generationID]);
    assert([pruned.device isEqualToDictionary:source.device]);
    assert([store replaceActiveApplicationIdentityPropertyLists:originalIdentities error:nil]);
    assert([[[store activeManifestWithError:nil] propertyListRepresentation][@"appIdentities"]
        isEqualToDictionary:[source propertyListRepresentation][@"appIdentities"]]);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testActiveSchemaThreeManifestMigrationIsPersistedAndIdempotent(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXProfileManifest *source = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:source error:nil]);
    NSString *manifestPath = [[identityDirectory stringByAppendingPathComponent:@"profile_manifest.plist"]
        stringByResolvingSymlinksInPath];
    NSMutableDictionary<NSString *, id> *legacyManifest =
        [[NSDictionary dictionaryWithContentsOfFile:manifestPath] mutableCopy];
    legacyManifest[@"schemaVersion"] = @3;
    NSMutableDictionary<NSString *, id> *legacyIdentifiers = [legacyManifest[@"identifiers"] mutableCopy];
    legacyIdentifiers[@"appInstallUUID"] = NSUUID.UUID.UUIDString;
    legacyIdentifiers[@"appContainerUUID"] = NSUUID.UUID.UUIDString;
    legacyIdentifiers[@"appGroupUUID"] = NSUUID.UUID.UUIDString;
    legacyManifest[@"identifiers"] = legacyIdentifiers;
    [legacyManifest removeObjectForKey:@"appIdentities"];
    [legacyManifest removeObjectForKey:@"appGroupIdentities"];
    assert([legacyManifest writeToFile:manifestPath atomically:YES]);

    assert([store migrateLegacyProfileIfNeededWithError:nil]);
    NSDictionary<NSString *, id> *migratedPropertyList = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    assert([migratedPropertyList[@"schemaVersion"] integerValue] == 5);
    assert(migratedPropertyList[@"identifiers"][@"appInstallUUID"] == nil);
    PXProfileManifest *migrated = [store activeManifestWithError:nil];
    assert([migrated.generationID isEqualToString:source.generationID]);
    assert([migrated.device isEqualToDictionary:source.device]);
    assert([migrated.network isEqualToDictionary:source.network]);

    assert([store migrateLegacyProfileIfNeededWithError:nil]);
    assert([[NSDictionary dictionaryWithContentsOfFile:manifestPath] isEqualToDictionary:migratedPropertyList]);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testSchemaFourPartialRegionMigrationIsPersistedAndIdempotent(void) {
    NSString *identityDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PXProfileManifest *source = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:source error:nil]);
    NSString *manifestPath = [[identityDirectory stringByAppendingPathComponent:@"profile_manifest.plist"]
        stringByResolvingSymlinksInPath];
    NSMutableDictionary<NSString *, id> *legacyManifest =
        [[NSDictionary dictionaryWithContentsOfFile:manifestPath] mutableCopy];
    legacyManifest[@"schemaVersion"] = @4;
    NSDictionary<NSString *, id> *legacyRegion = @{
        @"countryCode": @"FR",
        @"localeIdentifier": @"fr_FR",
        @"timeZone": @"Europe/Paris",
        @"currencyCode": @"EUR"
    };
    legacyManifest[@"region"] = legacyRegion;
    assert([legacyManifest writeToFile:manifestPath atomically:YES]);
    NSString *regionProjectionPath = [[identityDirectory stringByAppendingPathComponent:@"region.plist"]
        stringByResolvingSymlinksInPath];
    NSMutableDictionary<NSString *, id> *legacyRegionProjection =
        [[NSDictionary dictionaryWithContentsOfFile:regionProjectionPath] mutableCopy];
    legacyRegionProjection[@"value"] = legacyRegion;
    assert([legacyRegionProjection writeToFile:regionProjectionPath atomically:YES]);

    assert([store migrateLegacyProfileIfNeededWithError:nil]);
    NSDictionary<NSString *, id> *migratedPropertyList = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    PXProfileManifest *migrated = [store activeManifestWithError:nil];
    assert([migratedPropertyList[@"schemaVersion"] integerValue] == 5);
    assert([migrated.region[@"preferredLanguages"] isEqualToArray:@[@"fr-FR"]]);
    assert([migrated.region[@"calendarIdentifier"] isEqualToString:@"gregorian"]);
    assert([migrated.generationID isEqualToString:source.generationID]);
    assert([migrated.identifiers isEqualToDictionary:source.identifiers]);
    assert([migrated.network isEqualToDictionary:source.network]);
    NSDictionary<NSString *, id> *regionProjection = [NSDictionary dictionaryWithContentsOfFile:
        [identityDirectory stringByAppendingPathComponent:@"region.plist"]];
    assert([regionProjection[@"generationID"] isEqualToString:migrated.generationID]);
    assert([regionProjection[@"value"] isEqualToDictionary:migrated.region]);

    assert([store migrateLegacyProfileIfNeededWithError:nil]);
    assert([[NSDictionary dictionaryWithContentsOfFile:manifestPath] isEqualToDictionary:migratedPropertyList]);
    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

static void testMalformedApplicationIdentityMapFailsClosed(void) {
    PXProfileManifest *source = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    NSMutableDictionary<NSString *, id> *propertyList = [[source propertyListRepresentation] mutableCopy];
    propertyList[@"appIdentities"] = @{
        @"com.example.app": @{@"installUUID": NSUUID.UUID.UUIDString}
    };
    NSError *error = nil;
    assert([PXProfileManifest manifestWithPropertyList:propertyList error:&error] == nil);
    assert(error != nil);
}

static void testMalformedSchemaFiveRegionFailsClosedWithoutRepair(void) {
    PXProfileManifest *source = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:fixedGenerationInput()
        error:nil];
    NSMutableDictionary<NSString *, id> *propertyList = [[source propertyListRepresentation] mutableCopy];
    propertyList[@"region"] = @{
        @"countryCode": @"FR",
        @"localeIdentifier": @"fr_FR",
        @"timeZone": @"Invalid/Timezone",
        @"currencyCode": @"EUR"
    };
    NSError *error = nil;
    assert([PXProfileManifest manifestWithPropertyList:propertyList error:&error] == nil);
    assert(error != nil);
}

int main(void) {
    @autoreleasepool {
        testFixedSeedProducesStableManifest();
        testSelectedTargetVendorIdentityIsStableAndChangesWithGeneration();
        testTrustedCarrierSetRestrictsDeterministicGeneration();
        testPendingNetworkTypeControlsGeneratedTransportAndRadio();
        testUnsupportedPending5GModelFailsClosed();
        testIncompatibleIPhoneFourteenProIsRejectedBeforeProfileGeneration();
        testPhysicalModeWithUnavailableGraphicsProbeProducesValidManifest();
        testProductionIPhoneSevenPlusPhysicalPathReplacesEmptyLegacyProjection();
        testIncompleteProductionDeviceRecordNamesEveryInvalidField();
        testPinnedCountryPreferenceNeverBreaksCarrierRegionCoherence();
        testGeneratedManifestUsesPerAppAndPerGroupIdentityMaps();
        testGeneratedManifestSatisfiesCrossFieldInvariants();
        testInternallyIncoherentGraphicsModelIsRejectedBeforeManifestActivation();
        testManifestDeclaresFieldSourcesAndCreatesVirtualRuntimeSession();
        testFailedPromotionLeavesPreviousGenerationActive();
        testGenerationIdentifierCannotReuseDifferentMaterializedValues();
        testConcurrentPromotionsAreSerialized();
        testMixedGenerationProjectionIsRejectedWithoutRepair();
        testLegacyMigrationPreservesValuesAndIsIdempotent();
        testAddingScopedAppIdentityDoesNotRegenerateDeviceOrNetwork();
        testActiveApplicationIdentityMapCanBePrunedAndRestoredWithoutChangingProfile();
        testActiveSchemaThreeManifestMigrationIsPersistedAndIdempotent();
        testSchemaFourPartialRegionMigrationIsPersistedAndIdempotent();
        testMalformedApplicationIdentityMapFailsClosed();
        testMalformedSchemaFiveRegionFailsClosedWithoutRepair();
    }
    return 0;
}
