#import "NetworkIdentity.h"

#include <assert.h>

static NSDictionary<NSString *, id> *carrierMatching(NSString *countryCode,
                                                       NSString *name,
                                                       NSString *mcc,
                                                       NSString *mnc) {
    for (NSDictionary<NSString *, id> *carrier in PXCarriersForCountry(countryCode)) {
        if ([carrier[@"name"] isEqualToString:name] &&
            [carrier[@"mcc"] isEqualToString:mcc] &&
            [carrier[@"mnc"] isEqualToString:mnc]) {
            return carrier;
        }
    }
    return nil;
}

static void testCarrier5GCapabilityUsesCatalogRadioTechnologies(void) {
    NSDictionary<NSString *, id> *jio = carrierMatching(@"in", @"Jio", @"405", @"840");
    NSDictionary<NSString *, id> *sprint = carrierMatching(@"us", @"Sprint", @"310", @"120");
    assert(PXCarrierSupports5G(jio));
    assert(!PXCarrierSupports5G(sprint));
    assert(!PXCarrierSupports5G(nil));
}

static void testFranceOrangeUsesFrenchCarrierMetadata(void) {
    NSArray<NSDictionary<NSString *, id> *> *carriers = PXCarriersForCountry(@"fr");
    NSPredicate *orangePredicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary<NSString *, id> *carrier,
                                                                         NSDictionary<NSString *, id> *bindings) {
        (void)bindings;
        return [carrier[@"name"] isEqualToString:@"Orange"];
    }];
    NSDictionary<NSString *, id> *orange = [carriers filteredArrayUsingPredicate:orangePredicate].firstObject;

    assert(orange != nil);
    assert([orange[@"country"] isEqualToString:@"France"]);
    assert([orange[@"isoCountryCode"] isEqualToString:@"fr"]);
    assert([orange[@"mcc"] isEqualToString:@"208"]);
    assert([orange[@"mnc"] isEqualToString:@"01"]);
}

static void testExistingCountryCatalogEntriesRemainCoherent(void) {
    NSDictionary<NSString *, id> *verizon = carrierMatching(@"us", @"Verizon", @"311", @"480");
    NSDictionary<NSString *, id> *jio = carrierMatching(@"in", @"Jio", @"405", @"840");
    NSDictionary<NSString *, id> *rogers = carrierMatching(@"ca", @"Rogers", @"302", @"720");

    assert([verizon[@"isoCountryCode"] isEqualToString:@"us"]);
    assert([verizon[@"country"] isEqualToString:@"United States"]);
    assert([jio[@"isoCountryCode"] isEqualToString:@"in"]);
    assert([jio[@"country"] isEqualToString:@"India"]);
    assert([rogers[@"isoCountryCode"] isEqualToString:@"ca"]);
    assert([rogers[@"country"] isEqualToString:@"Canada"]);
    assert(PXCarriersForCountry(@"zz").count == 0);
    assert([PXCarrierCatalog() containsObject:carrierMatching(@"fr", @"Orange", @"208", @"01")]);
}

static void testCarrierCatalogHasUniqueStableIdentifiers(void) {
    NSMutableSet<NSString *> *carrierIDs = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *carrier in PXCarrierCatalog()) {
        NSString *carrierID = carrier[@"carrierID"];
        assert(carrierID.length > 0);
        assert(![carrierIDs containsObject:carrierID]);
        assert([carrier[@"country"] length] > 0);
        assert([carrier[@"isoCountryCode"] length] == 2);
        assert([carrier[@"mcc"] length] > 0);
        assert([carrier[@"mnc"] length] > 0);
        [carrierIDs addObject:carrierID];
    }
    assert(carrierIDs.count == PXCarrierCatalog().count);
}

static void testTrustedCarrierPolicyNormalizationRepairsCatalogChanges(void) {
    NSSet<NSString *> *allCarrierIDs = PXAllCarrierIDs();
    NSArray<NSString *> *sortedCarrierIDs = [allCarrierIDs.allObjects
        sortedArrayUsingSelector:@selector(compare:)];
    NSString *knownCarrierID = sortedCarrierIDs.lastObject;
    NSString *defaultCarrierID = sortedCarrierIDs.firstObject;
    BOOL repaired = NO;
    NSSet<NSString *> *mixedSelection = PXNormalizedTrustedCarrierIDs(
        [NSSet setWithObjects:knownCarrierID, @"removed-carrier", nil],
        &repaired
    );
    assert(repaired);
    assert([mixedSelection isEqualToSet:[NSSet setWithObject:knownCarrierID]]);

    repaired = NO;
    NSSet<NSString *> *allInvalidSelection = PXNormalizedTrustedCarrierIDs(
        [NSSet setWithObject:@"removed-carrier"],
        &repaired
    );
    assert(repaired);
    assert([allInvalidSelection isEqualToSet:[NSSet setWithObject:defaultCarrierID]]);

    repaired = NO;
    NSSet<NSString *> *missingSelection = PXNormalizedTrustedCarrierIDs(nil, &repaired);
    assert(repaired);
    assert([missingSelection isEqualToSet:[NSSet setWithObject:defaultCarrierID]]);
}

static void testModelAndCarrierCapabilitiesConstrainGeneratedRadio(void) {
    NSDictionary<NSString *, id> *jio = carrierMatching(@"in", @"Jio", @"405", @"840");
    NSDictionary<NSString *, id> *legacyIdentity = PXBuildNetworkIdentity(jio, NO, 1, 2, @"service-a");
    NSDictionary<NSString *, id> *fiveGIdentity = PXBuildNetworkIdentity(jio, YES, 0, 1, @"service-a");

    assert([legacyIdentity[@"transport"] isEqualToString:@"cellular"]);
    assert([legacyIdentity[@"radioTechnology"] isEqualToString:@"CTRadioAccessTechnologyLTE"]);
    assert([fiveGIdentity[@"transport"] isEqualToString:@"wifi"]);
    assert([fiveGIdentity[@"carrierName"] isEqualToString:@"Jio"]);
    assert([fiveGIdentity[@"radioTechnology"] isEqualToString:@"CTRadioAccessTechnologyNR"]);
    assert(![fiveGIdentity[@"radioTechnology"] isEqualToString:@"CTRadioAccessTechnologyNRNSA"]);
    assert([fiveGIdentity[@"serviceIdentifier"] isEqualToString:@"service-a"]);
    assert([fiveGIdentity isEqualToDictionary:PXBuildNetworkIdentity(jio, YES, 0, 1, @"service-a")]);
}

static void testIPAddressUpdatesPreserveGeneratedNetworkIdentity(void) {
    NSDictionary<NSString *, id> *existing = @{
        @"carrierName": @"Orange",
        @"mcc": @"208",
        @"mnc": @"01",
        @"isoCountryCode": @"fr",
        @"transport": @"wifi",
        @"radioTechnology": @"CTRadioAccessTechnologyNR",
        @"serviceIdentifier": @"service-fr"
    };
    NSDictionary<NSString *, id> *merged = PXNetworkSettingsByMerging(existing, @{
        @"localIPAddress": @"192.168.1.20",
        @"localIPv6Address": @"fe80::20"
    });

    assert([merged[@"localIPAddress"] isEqualToString:@"192.168.1.20"]);
    assert([merged[@"localIPv6Address"] isEqualToString:@"fe80::20"]);
    assert([merged[@"carrierName"] isEqualToString:@"Orange"]);
    assert([merged[@"isoCountryCode"] isEqualToString:@"fr"]);
    assert([merged[@"transport"] isEqualToString:@"wifi"]);
    assert([merged[@"radioTechnology"] isEqualToString:@"CTRadioAccessTechnologyNR"]);
    assert([merged[@"serviceIdentifier"] isEqualToString:@"service-fr"]);
}

static void testServiceIdentifiersPreservePhysicalKeysAndUseStableFallback(void) {
    NSArray<NSString *> *physicalKeys = @[@"real-service-b", @"real-service-a"];
    NSArray<NSString *> *preserved = PXResolvedServiceIdentifiers(physicalKeys, @"synthetic-service");
    NSArray<NSString *> *fallback = PXResolvedServiceIdentifiers(@[], @"synthetic-service");
    NSDictionary<NSString *, NSString *> *radios = PXValuesByServiceIdentifier(
        fallback,
        @"CTRadioAccessTechnologyNRNSA"
    );

    assert([preserved isEqualToArray:physicalKeys]);
    assert([fallback isEqualToArray:@[@"synthetic-service"]]);
    assert(![fallback.firstObject isEqualToString:@"0"]);
    assert([radios[@"synthetic-service"] isEqualToString:@"CTRadioAccessTechnologyNRNSA"]);
}

static void testConfiguredFourGIdentityRejectsContradictoryOrMissingSignals(void) {
    NSDictionary<NSString *, id> *fourG = @{
        @"carrierID": @"fr-orange-208-01",
        @"country": @"France",
        @"isoCountryCode": @"fr",
        @"carrierName": @"Orange",
        @"mcc": @"208",
        @"mnc": @"01",
        @"supportedRadioTechnologies": @[@"CTRadioAccessTechnologyLTE"],
        @"transport": @"cellular",
        @"configuredNetworkType": @"4g-lte",
        @"radioTechnology": @"CTRadioAccessTechnologyLTE",
        @"serviceIdentifier": @"service-fr",
        @"localIPAddress": @"10.23.45.67",
        @"localIPv6Address": @"fe80::1234:5678",
        @"cellularSignalBars": @4,
        @"wifiSignalStrength": @-60,
        @"allowsVOIP": @YES
    };
    assert(PXNetworkIdentityIsCoherent(fourG));

    for (NSDictionary<NSString *, id> *invalidUpdate in @[
        @{@"transport": @"wifi"},
        @{@"radioTechnology": @"CTRadioAccessTechnologyNR"},
        @{@"localIPAddress": @"0.0.0.0"},
        @{@"localIPv6Address": @"::"},
        @{@"serviceIdentifier": @""}
    ]) {
        assert(!PXNetworkIdentityIsCoherent(
            PXNetworkSettingsByMerging(fourG, invalidUpdate)));
    }

    NSDictionary<NSString *, id> *fiveGNSA = PXNetworkSettingsByMerging(fourG, @{
        @"configuredNetworkType": @"5g-nr",
        @"radioTechnology": @"CTRadioAccessTechnologyNRNSA"
    });
    assert(PXNetworkIdentityIsCoherent(fiveGNSA));
    assert(PXNetworkIdentityIsCoherent(PXNetworkSettingsByMerging(fiveGNSA, @{
        @"configuredNetworkType": @"5g"
    })));
    NSDictionary<NSString *, id> *combined = PXNetworkSettingsByMerging(fiveGNSA, @{
        @"configuredNetworkType": @"wifi",
        @"configuredNetworkTypes": @[@"wifi", @"5g-nr", @"4g-lte"],
        @"transport": @"wifi",
        @"supportedRadioTechnologies": @[
            @"CTRadioAccessTechnologyLTE", @"CTRadioAccessTechnologyNRNSA"
        ]
    });
    assert(PXNetworkIdentityIsCoherent(combined));
    assert(!PXNetworkIdentityIsCoherent(PXNetworkSettingsByMerging(combined, @{
        @"configuredNetworkTypes": @[@"wifi", @"none"]
    })));
    assert(!PXNetworkIdentityIsCoherent(PXNetworkSettingsByMerging(combined, @{
        @"radioTechnology": @"CTRadioAccessTechnologyEdge"
    })));
}

int main(void) {
    @autoreleasepool {
        testCarrier5GCapabilityUsesCatalogRadioTechnologies();
        testFranceOrangeUsesFrenchCarrierMetadata();
        testExistingCountryCatalogEntriesRemainCoherent();
        testCarrierCatalogHasUniqueStableIdentifiers();
        testTrustedCarrierPolicyNormalizationRepairsCatalogChanges();
        testModelAndCarrierCapabilitiesConstrainGeneratedRadio();
        testIPAddressUpdatesPreserveGeneratedNetworkIdentity();
        testServiceIdentifiersPreservePhysicalKeysAndUseStableFallback();
        testConfiguredFourGIdentityRejectsContradictoryOrMissingSignals();
    }
    return 0;
}
