#import "AppIdentityHookSupport.h"

#import "NetworkIdentity.h"
#import "ProfileManifest.h"

#include <assert.h>

@interface IdentifierManager : NSObject
@end

@implementation IdentifierManager
@end

void PXLog(NSString *format, ...) {
    (void)format;
}

static PXProfileGenerationInput *vendorGenerationInput(NSData *seed) {
    PXProfileGenerationInput *input = [[PXProfileGenerationInput alloc] init];
    input.seed = seed;
    input.generatedAt = [NSDate dateWithTimeIntervalSince1970:1700000000];
    input.networkType = PXEnvironmentNetworkType4GLTE;
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
            @"unmaskedVendor": @"Apple Inc.",
            @"unmaskedRenderer": @"Apple A14 GPU",
            @"webglVendor": @"Apple",
            @"webglRenderer": @"Apple GPU",
            @"webglVersion": @"WebGL 2.0",
            @"maxTextureSize": @16384,
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
    input.pinnedLocation = @{
        @"latitude": @48.8566,
        @"longitude": @2.3522,
        @"pinned": @YES
    };
    input.region = @{};
    input.graphicsHostCapabilities = @{
        @"metalFamilies": @[@1001, @1002, @1003, @1004, @1005, @1006, @1007, @1008],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9,
                                @10, @11, @12, @13, @14, @15, @16],
        @"maxTextureSize": @16384,
        @"maxRenderbufferSize": @16384,
        @"supportsOpenGLES3": @YES
    };
    input.appBundleIdentifiers = [NSSet setWithObject:@"com.fingerprintjs.DemoApp"];
    return input;
}

static void testProductionVendorSeamReloadsAfterPromotionWithoutNotification(void) {
    NSString *bundleIdentifier = @"com.fingerprintjs.DemoApp";
    NSString *identityDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:identityDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);

    PXProfileGenerator *generator = [[PXProfileGenerator alloc] init];
    PXProfileManifest *first = [generator
        generateManifestWithInput:vendorGenerationInput(
            [@"first production vendor generation" dataUsingEncoding:NSUTF8StringEncoding])
        error:nil];
    PXProfileManifest *second = [generator
        generateManifestWithInput:vendorGenerationInput(
            [@"second production vendor generation" dataUsingEncoding:NSUTF8StringEncoding])
        error:nil];
    PXProfileStore *store = [[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory];
    assert([store promoteManifest:first error:nil]);

    NSUUID *firstIdentifier = PXPrepareScopedVendorIdentifier(bundleIdentifier, identityDirectory);
    assert(firstIdentifier != nil);
    assert([firstIdentifier isEqual:
        PXPrepareScopedVendorIdentifier(bundleIdentifier, identityDirectory)]);
    NSDictionary<NSString *, id> *firstNetworkIdentity =
        PXPrepareScopedNetworkIdentity(bundleIdentifier, identityDirectory);
    assert(PXNetworkIdentityIsCoherent(firstNetworkIdentity));
    assert([firstNetworkIdentity[@"transport"] isEqualToString:@"cellular"]);
    assert([firstNetworkIdentity[@"radioTechnology"] isEqualToString:@"CTRadioAccessTechnologyLTE"]);

    assert([store promoteManifest:second error:nil]);
    NSUUID *secondIdentifier = PXPrepareScopedVendorIdentifier(bundleIdentifier, identityDirectory);
    assert(secondIdentifier != nil);
    assert(![firstIdentifier isEqual:secondIdentifier]);
    assert([secondIdentifier isEqual:[[NSUUID alloc]
        initWithUUIDString:second.identifiers[@"idfv"]]]);
    NSDictionary<NSString *, id> *secondNetworkIdentity =
        PXPrepareScopedNetworkIdentity(bundleIdentifier, identityDirectory);
    assert(PXNetworkIdentityIsCoherent(secondNetworkIdentity));
    assert(![firstNetworkIdentity isEqualToDictionary:secondNetworkIdentity]);

    NSString *activeLink = [identityDirectory stringByAppendingPathComponent:@"profile_active"];
    assert([[NSFileManager defaultManager] removeItemAtPath:activeLink error:nil]);
    assert(PXPrepareScopedVendorIdentifier(bundleIdentifier, identityDirectory) == nil);
    assert(PXPrepareScopedNetworkIdentity(bundleIdentifier, identityDirectory) == nil);

    [[NSFileManager defaultManager] removeItemAtPath:identityDirectory error:nil];
}

int main(void) {
    @autoreleasepool {
        testProductionVendorSeamReloadsAfterPromotionWithoutNotification();
    }
    return 0;
}
