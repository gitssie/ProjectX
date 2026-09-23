#import "ProfileManifest.h"
#import "DeviceModelManager.h"
#import "GraphicsIdentity.h"
#import "IOSVersionInfo.h"
#import "NetworkIdentity.h"
#import "PXEnvironmentModelSelection.h"
#import "PXEnvironmentPolicy.h"
#import "PXRootHidePath.h"

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
    assert([fiveG.network[@"configuredNetworkType"] isEqualToString:@"5g-nr"]);
    assert(PXNetworkIdentityIsCoherent(fiveG.network));

    PXProfileGenerationInput *combinedInput = fixedGenerationInput();
    combinedInput.networkTypes = [NSSet setWithObjects:
        @(PXEnvironmentNetworkTypeWiFi),
        @(PXEnvironmentNetworkType4GLTE),
        @(PXEnvironmentNetworkType5GNR), nil];
    PXProfileManifest *combined = [[[PXProfileGenerator alloc] init]
        generateManifestWithInput:combinedInput error:nil];
    assert([combined.network[@"transport"] isEqualToString:@"wifi"]);
    assert([fiveGRadioTechnologies containsObject:combined.network[@"radioTechnology"]]);
    assert(([combined.network[@"configuredNetworkTypes"] isEqualToArray:
        @[@"wifi", @"5g-nr", @"4g-lte"]]));
    assert([combined.network[@"supportedRadioTechnologies"] containsObject:
        @"CTRadioAccessTechnologyLTE"]);
    assert(PXNetworkIdentityIsCoherent(combined.network));

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

static void testOneProfileFileStoresAndReplacesAllGeneratedValues(void) {
    NSString *testRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"profile-store-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *identityDirectory = [testRoot stringByAppendingPathComponent:@"test/data/identity"];
    NSString *profilePath = [testRoot stringByAppendingPathComponent:@"current_profile.plist"];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    PXProfileGenerator *generator = [[PXProfileGenerator alloc] init];

    PXProfileGenerationInput *firstInput = fixedGenerationInput();
    PXProfileManifest *first = [generator generateManifestWithInput:firstInput error:nil];
    assert(first != nil);
    assert([store promoteManifest:first error:nil]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:profilePath]);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:
        [testRoot stringByAppendingPathComponent:@"Profiles"]]);
    NSDictionary *profile = [NSDictionary dictionaryWithContentsOfFile:profilePath];
    assert(profile[@"ProfileId"] == nil);
    NSDictionary *values = profile[@"values"];
    assert([profile[@"manifest"][@"generationID"]
        isEqualToString:first.generationID]);
    assert([values[@"identity/device_model.plist"][@"value"]
        isEqualToString:first.device[@"identifier"]]);
    assert([values[@"identity/network_settings.plist"][@"ssid"]
        isEqualToString:first.network[@"ssid"]]);
    assert(PXProfileUpdateContentsAtPath(profilePath, ^(NSMutableDictionary *profile) {
        NSMutableDictionary *storedValues = [profile[@"values"] mutableCopy];
        storedValues[@"identity/stale_uuid.plist"] = @{@"value": @"old"};
        storedValues[@"trustedCarriers"] = @{@"trustedCarrierIDs": @[@"test-carrier"]};
        profile[@"values"] = storedValues;
    }));

    store.failBeforePromotionForTesting = YES;
    PXProfileGenerationInput *secondInput = fixedGenerationInput();
    secondInput.seed = [@"new seed" dataUsingEncoding:NSUTF8StringEncoding];
    PXProfileManifest *second = [generator generateManifestWithInput:secondInput error:nil];
    assert(second != nil);
    assert(![store promoteManifest:second error:nil]);
    assert([[store activeGenerationIDWithError:nil] isEqualToString:first.generationID]);
    store.failBeforePromotionForTesting = NO;
    assert([store promoteManifest:second error:nil]);
    assert([[store activeGenerationIDWithError:nil] isEqualToString:second.generationID]);
    NSString *replacementIDFA = NSUUID.UUID.UUIDString;
    assert([store replaceActiveIdentifierValue:replacementIDFA forKey:@"idfa" error:nil]);
    NSDictionary *editedProfile = [NSDictionary dictionaryWithContentsOfFile:profilePath];
    assert([editedProfile[@"manifest"][@"identifiers"][@"idfa"] isEqualToString:replacementIDFA]);
    assert([editedProfile[@"values"][@"identity/advertising_id.plist"][@"value"] isEqualToString:replacementIDFA]);
    assert([editedProfile[@"values"][@"identity/device_ids.plist"][@"IDFA"] isEqualToString:replacementIDFA]);
    assert([[store activeGenerationIDWithError:nil] isEqualToString:second.generationID]);
    assert(![store replaceActiveIdentifierValue:@"invalid" forKey:@"idfa" error:nil]);
    assert(![store replaceActiveIdentifierValue:@"x" forKey:@"unknown" error:nil]);
    assert([[NSDictionary dictionaryWithContentsOfFile:profilePath][@"manifest"][@"identifiers"][@"idfa"]
        isEqualToString:replacementIDFA]);
    assert([store replaceActiveLocalIPAddress:@"192.0.2.42" IPv6Address:@"2001:db8::42" error:nil]);
    NSDictionary *networkProfile = [NSDictionary dictionaryWithContentsOfFile:profilePath];
    assert([networkProfile[@"manifest"][@"network"][@"localIPAddress"] isEqualToString:@"192.0.2.42"]);
    assert([networkProfile[@"values"][@"identity/network_settings.plist"][@"localIPv6Address"] isEqualToString:@"2001:db8::42"]);
    assert([networkProfile[@"values"][@"identity/device_ids.plist"][@"LocalIPAddress"] isEqualToString:@"192.0.2.42"]);
    NSDictionary *replacementValues = [NSDictionary dictionaryWithContentsOfFile:profilePath][@"values"];
    assert(replacementValues[@"identity/stale_uuid.plist"] == nil);
    assert([replacementValues[@"trustedCarriers"][@"trustedCarrierIDs"]
        isEqualToArray:@[@"test-carrier"]]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:profilePath]);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:
        [testRoot stringByAppendingPathComponent:@"Profiles"]]);
    [[NSFileManager defaultManager] removeItemAtPath:testRoot error:nil];
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
        testIncompleteProductionDeviceRecordNamesEveryInvalidField();
        testPinnedCountryPreferenceNeverBreaksCarrierRegionCoherence();
        testGeneratedManifestUsesPerAppAndPerGroupIdentityMaps();
        testGeneratedManifestSatisfiesCrossFieldInvariants();
        testInternallyIncoherentGraphicsModelIsRejectedBeforeManifestActivation();
        testManifestDeclaresFieldSourcesAndCreatesVirtualRuntimeSession();
        testOneProfileFileStoresAndReplacesAllGeneratedValues();
    }
    return 0;
}
