#import "NetworkIdentity.h"

#import <arpa/inet.h>

static NSArray<NSString *> *PXAllRadioTechnologies(void) {
    return @[
        @"CTRadioAccessTechnologyLTE",
        @"CTRadioAccessTechnologyNRNSA",
        @"CTRadioAccessTechnologyNR"
    ];
}

static NSDictionary<NSString *, id> *PXCarrier(NSString *carrierID,
                                                 NSString *country,
                                                 NSString *isoCountryCode,
                                                 NSString *name,
                                                 NSString *mcc,
                                                 NSString *mnc,
                                                 NSArray<NSString *> *supportedRadioTechnologies) {
    return @{
        @"carrierID": carrierID,
        @"country": country,
        @"isoCountryCode": isoCountryCode,
        @"name": name,
        @"mcc": mcc,
        @"mnc": mnc,
        @"supportedRadioTechnologies": supportedRadioTechnologies
    };
}

static NSDictionary<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *PXCarrierCatalogByCountry(void) {
    static NSDictionary<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *catalog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *allRadios = PXAllRadioTechnologies();
        NSArray<NSString *> *lteOnly = @[@"CTRadioAccessTechnologyLTE"];
        NSArray<NSString *> *lteAndStandalone5G = @[
            @"CTRadioAccessTechnologyLTE",
            @"CTRadioAccessTechnologyNR"
        ];
        NSArray<NSString *> *lteAndNonStandalone5G = @[
            @"CTRadioAccessTechnologyLTE",
            @"CTRadioAccessTechnologyNRNSA"
        ];

        catalog = @{
            @"us": @[
                PXCarrier(@"us-verizon-310-004", @"United States", @"us", @"Verizon", @"310", @"004", allRadios),
                PXCarrier(@"us-verizon-310-010", @"United States", @"us", @"Verizon", @"310", @"010", allRadios),
                PXCarrier(@"us-verizon-311-480", @"United States", @"us", @"Verizon", @"311", @"480", allRadios),
                PXCarrier(@"us-att-310-170", @"United States", @"us", @"AT&T", @"310", @"170", allRadios),
                PXCarrier(@"us-att-310-410", @"United States", @"us", @"AT&T", @"310", @"410", allRadios),
                PXCarrier(@"us-att-310-150", @"United States", @"us", @"AT&T", @"310", @"150", allRadios),
                PXCarrier(@"us-att-310-680", @"United States", @"us", @"AT&T", @"310", @"680", allRadios),
                PXCarrier(@"us-tmobile-310-260", @"United States", @"us", @"T-Mobile", @"310", @"260", allRadios),
                PXCarrier(@"us-tmobile-310-160", @"United States", @"us", @"T-Mobile", @"310", @"160", allRadios),
                PXCarrier(@"us-tmobile-310-240", @"United States", @"us", @"T-Mobile", @"310", @"240", allRadios),
                PXCarrier(@"us-tmobile-310-800", @"United States", @"us", @"T-Mobile", @"310", @"800", allRadios),
                PXCarrier(@"us-sprint-310-120", @"United States", @"us", @"Sprint", @"310", @"120", lteOnly),
                PXCarrier(@"us-sprint-311-870", @"United States", @"us", @"Sprint", @"311", @"870", lteOnly),
                PXCarrier(@"us-sprint-312-530", @"United States", @"us", @"Sprint", @"312", @"530", lteOnly),
                PXCarrier(@"us-cellcom-311-210", @"United States", @"us", @"Cellcom", @"311", @"210", lteOnly)
            ],
            @"in": @[
                PXCarrier(@"in-jio-405-840", @"India", @"in", @"Jio", @"405", @"840", lteAndStandalone5G),
                PXCarrier(@"in-jio-405-854", @"India", @"in", @"Jio", @"405", @"854", lteAndStandalone5G),
                PXCarrier(@"in-jio-405-855", @"India", @"in", @"Jio", @"405", @"855", lteAndStandalone5G),
                PXCarrier(@"in-jio-405-856", @"India", @"in", @"Jio", @"405", @"856", lteAndStandalone5G),
                PXCarrier(@"in-jio-405-857", @"India", @"in", @"Jio", @"405", @"857", lteAndStandalone5G),
                PXCarrier(@"in-airtel-404-45", @"India", @"in", @"Airtel", @"404", @"45", lteAndNonStandalone5G),
                PXCarrier(@"in-airtel-404-49", @"India", @"in", @"Airtel", @"404", @"49", lteAndNonStandalone5G),
                PXCarrier(@"in-airtel-404-70", @"India", @"in", @"Airtel", @"404", @"70", lteAndNonStandalone5G),
                PXCarrier(@"in-airtel-404-90", @"India", @"in", @"Airtel", @"404", @"90", lteAndNonStandalone5G),
                PXCarrier(@"in-airtel-404-92", @"India", @"in", @"Airtel", @"404", @"92", lteAndNonStandalone5G),
                PXCarrier(@"in-bsnl-404-34", @"India", @"in", @"BSNL", @"404", @"34", lteOnly),
                PXCarrier(@"in-bsnl-404-38", @"India", @"in", @"BSNL", @"404", @"38", lteOnly),
                PXCarrier(@"in-bsnl-404-51", @"India", @"in", @"BSNL", @"404", @"51", lteOnly),
                PXCarrier(@"in-bsnl-404-53", @"India", @"in", @"BSNL", @"404", @"53", lteOnly),
                PXCarrier(@"in-mtnl-404-68", @"India", @"in", @"MTNL", @"404", @"68", lteOnly),
                PXCarrier(@"in-mtnl-404-69", @"India", @"in", @"MTNL", @"404", @"69", lteOnly)
            ],
            @"ca": @[
                PXCarrier(@"ca-rogers-302-720", @"Canada", @"ca", @"Rogers", @"302", @"720", allRadios),
                PXCarrier(@"ca-rogers-302-370", @"Canada", @"ca", @"Rogers", @"302", @"370", allRadios),
                PXCarrier(@"ca-bell-302-610", @"Canada", @"ca", @"Bell", @"302", @"610", allRadios),
                PXCarrier(@"ca-bell-302-640", @"Canada", @"ca", @"Bell", @"302", @"640", allRadios),
                PXCarrier(@"ca-bell-302-651", @"Canada", @"ca", @"Bell", @"302", @"651", allRadios),
                PXCarrier(@"ca-telus-302-220", @"Canada", @"ca", @"Telus", @"302", @"220", allRadios),
                PXCarrier(@"ca-telus-302-221", @"Canada", @"ca", @"Telus", @"302", @"221", allRadios),
                PXCarrier(@"ca-freedom-302-490", @"Canada", @"ca", @"Freedom Mobile", @"302", @"490", allRadios),
                PXCarrier(@"ca-videotron-302-500", @"Canada", @"ca", @"Videotron", @"302", @"500", allRadios),
                PXCarrier(@"ca-videotron-302-510", @"Canada", @"ca", @"Videotron", @"302", @"510", allRadios),
                PXCarrier(@"ca-sasktel-302-780", @"Canada", @"ca", @"SaskTel", @"302", @"780", lteOnly),
                PXCarrier(@"ca-fido-302-370", @"Canada", @"ca", @"Fido", @"302", @"370", lteOnly),
                PXCarrier(@"ca-koodo-302-220", @"Canada", @"ca", @"Koodo", @"302", @"220", lteOnly),
                PXCarrier(@"ca-chatr-302-720", @"Canada", @"ca", @"Chatr", @"302", @"720", lteOnly),
                PXCarrier(@"ca-cityfone-302-720", @"Canada", @"ca", @"Cityfone", @"302", @"720", lteOnly),
                PXCarrier(@"ca-speakout-302-720", @"Canada", @"ca", @"7-Eleven Speak Out", @"302", @"720", lteOnly)
            ],
            @"fr": @[
                PXCarrier(@"fr-orange-208-01", @"France", @"fr", @"Orange", @"208", @"01", allRadios),
                PXCarrier(@"fr-sfr-208-10", @"France", @"fr", @"SFR", @"208", @"10", allRadios)
            ],
            @"gb": @[
                PXCarrier(@"gb-ee-234-30", @"United Kingdom", @"gb", @"EE", @"234", @"30", allRadios)
            ],
            @"de": @[
                PXCarrier(@"de-telekom-262-01", @"Germany", @"de", @"Telekom", @"262", @"01", allRadios)
            ],
            @"au": @[
                PXCarrier(@"au-telstra-505-01", @"Australia", @"au", @"Telstra", @"505", @"01", allRadios)
            ],
            @"jp": @[
                PXCarrier(@"jp-docomo-440-10", @"Japan", @"jp", @"NTT DOCOMO", @"440", @"10", allRadios)
            ],
            @"br": @[
                PXCarrier(@"br-claro-724-05", @"Brazil", @"br", @"Claro", @"724", @"05", allRadios)
            ]
        };
    });
    return catalog;
}

NSArray<NSDictionary<NSString *, id> *> *PXCarriersForCountry(NSString *countryCode) {
    if (countryCode.length == 0) {
        return @[];
    }
    return PXCarrierCatalogByCountry()[countryCode.lowercaseString] ?: @[];
}

NSArray<NSDictionary<NSString *, id> *> *PXCarrierCatalog(void) {
    NSDictionary<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *catalogByCountry = PXCarrierCatalogByCountry();
    NSMutableArray<NSDictionary<NSString *, id> *> *catalog = [NSMutableArray array];
    NSArray<NSString *> *countryCodes = [catalogByCountry.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *countryCode in countryCodes) {
        [catalog addObjectsFromArray:catalogByCountry[countryCode]];
    }
    return [catalog copy];
}

BOOL PXCarrierSupports5G(NSDictionary<NSString *, id> *carrier) {
    NSArray<NSString *> *technologies = [carrier[@"supportedRadioTechnologies"]
        isKindOfClass:[NSArray class]]
        ? carrier[@"supportedRadioTechnologies"]
        : @[];
    return [technologies containsObject:@"CTRadioAccessTechnologyNR"] ||
        [technologies containsObject:@"CTRadioAccessTechnologyNRNSA"];
}

NSSet<NSString *> *PXAllCarrierIDs(void) {
    NSMutableSet<NSString *> *carrierIDs = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *carrier in PXCarrierCatalog()) {
        NSString *carrierID = carrier[@"carrierID"];
        if (carrierID.length > 0) {
            [carrierIDs addObject:carrierID];
        }
    }
    return [carrierIDs copy];
}

NSSet<NSString *> *PXNormalizedTrustedCarrierIDs(NSSet<NSString *> *savedCarrierIDs, BOOL *repaired) {
    NSSet<NSString *> *allCarrierIDs = PXAllCarrierIDs();
    NSMutableSet<NSString *> *validCarrierIDs = [NSMutableSet set];
    for (id carrierID in savedCarrierIDs) {
        if ([carrierID isKindOfClass:[NSString class]] && [allCarrierIDs containsObject:carrierID]) {
            [validCarrierIDs addObject:carrierID];
        }
    }

    BOOL needsRepair = !savedCarrierIDs || ![validCarrierIDs isEqualToSet:savedCarrierIDs] ||
        validCarrierIDs.count != 1;
    if (validCarrierIDs.count == 0) {
        [validCarrierIDs unionSet:allCarrierIDs];
        needsRepair = YES;
    }
    NSString *selectedCarrierID = [validCarrierIDs.allObjects
        sortedArrayUsingSelector:@selector(compare:)].firstObject;
    NSSet<NSString *> *normalizedCarrierIDs = selectedCarrierID
        ? [NSSet setWithObject:selectedCarrierID]
        : [NSSet set];
    if (repaired) {
        *repaired = needsRepair;
    }
    return normalizedCarrierIDs;
}

NSArray<NSDictionary<NSString *, id> *> *PXCarriersFromCatalog(NSArray<NSDictionary<NSString *, id> *> *catalog,
                                                                 NSSet<NSString *> *trustedCarrierIDs) {
    NSMutableArray<NSDictionary<NSString *, id> *> *carriers = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *carrier in catalog) {
        if ([trustedCarrierIDs containsObject:carrier[@"carrierID"]]) {
            [carriers addObject:carrier];
        }
    }
    return [carriers copy];
}

NSArray<NSDictionary<NSString *, id> *> *PXCarriersForTrustedCarrierIDs(NSSet<NSString *> *trustedCarrierIDs) {
    return PXCarriersFromCatalog(PXCarrierCatalog(), trustedCarrierIDs);
}

NSDictionary<NSString *, id> *PXBuildNetworkIdentity(NSDictionary<NSString *, id> *carrier,
                                                       BOOL supports5G,
                                                       NSUInteger transportIndex,
                                                       NSUInteger radioTechnologyIndex,
                                                       NSString *serviceIdentifier) {
    NSArray<NSString *> *carrierTechnologies = [carrier[@"supportedRadioTechnologies"] isKindOfClass:[NSArray class]]
        ? carrier[@"supportedRadioTechnologies"]
        : @[];
    NSMutableArray<NSString *> *allowedTechnologies = [NSMutableArray array];

    for (NSString *technology in carrierTechnologies) {
        BOOL isLTE = [technology isEqualToString:@"CTRadioAccessTechnologyLTE"];
        if (isLTE || supports5G) {
            [allowedTechnologies addObject:technology];
        }
    }
    if (allowedTechnologies.count == 0) {
        [allowedTechnologies addObject:@"CTRadioAccessTechnologyLTE"];
    }

    NSString *transport = transportIndex % 2 == 0 ? @"wifi" : @"cellular";
    NSString *radioTechnology = allowedTechnologies[radioTechnologyIndex % allowedTechnologies.count];

    return @{
        @"carrierID": carrier[@"carrierID"] ?: @"",
        @"country": carrier[@"country"] ?: @"",
        @"isoCountryCode": [carrier[@"isoCountryCode"] lowercaseString] ?: @"",
        @"carrierName": carrier[@"name"] ?: @"",
        @"mcc": carrier[@"mcc"] ?: @"",
        @"mnc": carrier[@"mnc"] ?: @"",
        @"supportedRadioTechnologies": carrierTechnologies,
        @"transport": transport,
        @"radioTechnology": radioTechnology,
        @"serviceIdentifier": serviceIdentifier ?: @"",
        @"allowsVOIP": @YES
    };
}

NSDictionary<NSString *, id> *PXNetworkSettingsByMerging(NSDictionary<NSString *, id> *existingSettings,
                                                           NSDictionary<NSString *, id> *updates) {
    NSMutableDictionary<NSString *, id> *merged = [existingSettings mutableCopy] ?: [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:updates ?: @{}];
    return [merged copy];
}

NSArray<NSString *> *PXResolvedServiceIdentifiers(NSArray<NSString *> *originalServiceIdentifiers,
                                                    NSString *persistedServiceIdentifier) {
    NSMutableArray<NSString *> *resolved = [NSMutableArray array];
    for (id serviceIdentifier in originalServiceIdentifiers) {
        if (![serviceIdentifier isKindOfClass:[NSString class]] || [serviceIdentifier length] == 0) {
            continue;
        }
        if (![resolved containsObject:serviceIdentifier]) {
            [resolved addObject:serviceIdentifier];
        }
    }

    if (resolved.count == 0 && persistedServiceIdentifier.length > 0) {
        [resolved addObject:persistedServiceIdentifier];
    }
    return [resolved copy];
}

NSDictionary<NSString *, NSString *> *PXValuesByServiceIdentifier(NSArray<NSString *> *serviceIdentifiers,
                                                                   NSString *value) {
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    for (NSString *serviceIdentifier in serviceIdentifiers) {
        if (serviceIdentifier.length > 0) {
            values[serviceIdentifier] = value ?: @"";
        }
    }
    return [values copy];
}

static BOOL PXNetworkIdentityHasNonemptyString(NSDictionary<NSString *, id> *identity, NSString *key) {
    id value = identity[key];
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0;
}

static BOOL PXNetworkIdentityHasPlausibleIPv4Address(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) {
        return NO;
    }
    struct in_addr address = {0};
    if (inet_pton(AF_INET, value.UTF8String, &address) != 1) {
        return NO;
    }

    uint32_t hostAddress = ntohl(address.s_addr);
    return hostAddress != INADDR_ANY &&
           hostAddress != INADDR_BROADCAST &&
           (hostAddress & 0xFF000000U) != 0x7F000000U &&
           (hostAddress & 0xF0000000U) != 0xE0000000U;
}

static BOOL PXNetworkIdentityHasPlausibleIPv6Address(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) {
        return NO;
    }
    struct in6_addr address = IN6ADDR_ANY_INIT;
    if (inet_pton(AF_INET6, value.UTF8String, &address) != 1) {
        return NO;
    }

    return !IN6_IS_ADDR_UNSPECIFIED(&address) &&
           !IN6_IS_ADDR_LOOPBACK(&address) &&
           !IN6_IS_ADDR_MULTICAST(&address);
}

BOOL PXNetworkIdentityIsCoherent(NSDictionary<NSString *, id> *identity) {
    if (![identity isKindOfClass:NSDictionary.class]) {
        return NO;
    }

    for (NSString *key in @[@"carrierID", @"country", @"isoCountryCode", @"carrierName", @"mcc", @"mnc", @"serviceIdentifier"]) {
        if (!PXNetworkIdentityHasNonemptyString(identity, key)) {
            return NO;
        }
    }

    NSString *networkType = [identity[@"configuredNetworkType"] isKindOfClass:NSString.class]
        ? identity[@"configuredNetworkType"]
        : nil;
    NSString *transport = [identity[@"transport"] isKindOfClass:NSString.class]
        ? identity[@"transport"]
        : nil;
    NSString *radioTechnology = [identity[@"radioTechnology"] isKindOfClass:NSString.class]
        ? identity[@"radioTechnology"]
        : nil;
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *requirements = @{
        @"5g": @{@"transport": @"cellular"},
        @"4g-lte": @{@"transport": @"cellular", @"radioTechnology": @"CTRadioAccessTechnologyLTE"},
        @"3g": @{@"transport": @"cellular", @"radioTechnology": @"CTRadioAccessTechnologyWCDMA"},
        @"2g": @{@"transport": @"cellular", @"radioTechnology": @"CTRadioAccessTechnologyEdge"},
        @"wifi": @{@"transport": @"wifi"},
        @"none": @{@"transport": @"none"}
    };
    NSDictionary<NSString *, NSString *> *required = requirements[networkType];
    if (!required && ![networkType isEqualToString:@"unspecified"]) {
        return NO;
    }
    if (required && ![transport isEqualToString:required[@"transport"]]) {
        return NO;
    }
    NSString *requiredRadioTechnology = required[@"radioTechnology"];
    if (requiredRadioTechnology && ![radioTechnology isEqualToString:requiredRadioTechnology]) {
        return NO;
    }
    if ([networkType isEqualToString:@"5g"] &&
        ![@[@"CTRadioAccessTechnologyNR", @"CTRadioAccessTechnologyNRNSA"]
            containsObject:radioTechnology]) {
        return NO;
    }

    if ([transport isEqualToString:@"none"]) {
        return !PXNetworkIdentityHasNonemptyString(identity, @"localIPAddress") &&
               !PXNetworkIdentityHasNonemptyString(identity, @"localIPv6Address");
    }
    if (![transport isEqualToString:@"wifi"] && ![transport isEqualToString:@"cellular"]) {
        return NO;
    }
    if (!PXNetworkIdentityHasPlausibleIPv4Address(identity[@"localIPAddress"]) ||
        !PXNetworkIdentityHasPlausibleIPv6Address(identity[@"localIPv6Address"])) {
        return NO;
    }

    NSNumber *cellularSignalBars = [identity[@"cellularSignalBars"] isKindOfClass:NSNumber.class]
        ? identity[@"cellularSignalBars"]
        : nil;
    NSNumber *wifiSignalStrength = [identity[@"wifiSignalStrength"] isKindOfClass:NSNumber.class]
        ? identity[@"wifiSignalStrength"]
        : nil;
    return cellularSignalBars && cellularSignalBars.integerValue >= 1 && cellularSignalBars.integerValue <= 5 &&
           wifiSignalStrength && wifiSignalStrength.integerValue >= -100 && wifiSignalStrength.integerValue <= -20;
}
