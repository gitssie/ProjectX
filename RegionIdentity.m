#import "RegionIdentity.h"

@interface PXRegionIdentity ()

@property (nonatomic, copy, readwrite) NSString *stableRegionIdentifier;
@property (nonatomic, copy, readwrite) NSString *countryCode;
@property (nonatomic, copy, readwrite) NSString *primaryLanguageTag;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *preferredLanguages;
@property (nonatomic, copy, readwrite) NSString *localeIdentifier;
@property (nonatomic, copy, readwrite) NSString *timeZoneIdentifier;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *timeZoneIdentifiers;
@property (nonatomic, copy, readwrite) NSString *currencyCode;
@property (nonatomic, copy, readwrite) NSString *calendarIdentifier;
@property (nonatomic, copy, readwrite) NSString *measurementSystem;
@property (nonatomic, copy, readwrite) NSString *temperatureUnit;

@end

@implementation PXRegionIdentity

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{
        @"regionID": self.stableRegionIdentifier,
        @"countryCode": self.countryCode,
        @"primaryLanguageTag": self.primaryLanguageTag,
        @"preferredLanguages": self.preferredLanguages,
        @"localeIdentifier": self.localeIdentifier,
        @"timeZone": self.timeZoneIdentifier,
        @"timeZoneIdentifiers": self.timeZoneIdentifiers,
        @"currencyCode": self.currencyCode,
        @"calendarIdentifier": self.calendarIdentifier,
        @"measurementSystem": self.measurementSystem,
        @"temperatureUnit": self.temperatureUnit
    };
}

- (BOOL)validate {
    if (self.stableRegionIdentifier.length == 0 || self.countryCode.length != 2 ||
        ![self.stableRegionIdentifier isEqualToString:self.stableRegionIdentifier.lowercaseString] ||
        ![self.countryCode isEqualToString:self.countryCode.uppercaseString] ||
        self.primaryLanguageTag.length == 0 || self.preferredLanguages.count == 0 ||
        ![self.preferredLanguages.firstObject isEqualToString:self.primaryLanguageTag] ||
        self.localeIdentifier.length == 0 || self.currencyCode.length != 3 ||
        ![self.currencyCode isEqualToString:self.currencyCode.uppercaseString] ||
        self.calendarIdentifier.length == 0 || self.timeZoneIdentifiers.count == 0 ||
        ![self.timeZoneIdentifiers containsObject:self.timeZoneIdentifier]) {
        return NO;
    }
    if (![NSLocale.ISOCountryCodes containsObject:self.countryCode] ||
        ![NSLocale.ISOCurrencyCodes containsObject:self.currencyCode] ||
        ![self.calendarIdentifier isEqualToString:@"gregorian"]) {
        return NO;
    }
    for (NSString *languageTag in self.preferredLanguages) {
        if (languageTag.length == 0 ||
            [NSLocale canonicalLanguageIdentifierFromString:languageTag].length == 0) {
            return NO;
        }
    }
    for (NSString *timeZoneIdentifier in self.timeZoneIdentifiers) {
        if (![NSTimeZone timeZoneWithName:timeZoneIdentifier]) {
            return NO;
        }
    }
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:self.localeIdentifier];
    NSString *localeCountryCode = [locale objectForKey:NSLocaleCountryCode];
    NSString *localeCurrencyCode = [locale objectForKey:NSLocaleCurrencyCode];
    NSString *localeLanguageCode = [locale objectForKey:NSLocaleLanguageCode];
    NSString *primaryLanguageCode = [self.primaryLanguageTag componentsSeparatedByString:@"-"].firstObject;
    if (![localeCountryCode isEqualToString:self.countryCode] ||
        ![localeCurrencyCode isEqualToString:self.currencyCode] ||
        ![localeLanguageCode isEqualToString:primaryLanguageCode]) {
        return NO;
    }
    return [@[@"metric", @"us", @"uk"] containsObject:self.measurementSystem] &&
        [@[@"celsius", @"fahrenheit"] containsObject:self.temperatureUnit];
}

+ (nullable instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList {
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSArray *preferredLanguages = [propertyList[@"preferredLanguages"] isKindOfClass:[NSArray class]]
        ? propertyList[@"preferredLanguages"]
        : @[];
    NSArray *timeZoneIdentifiers = [propertyList[@"timeZoneIdentifiers"] isKindOfClass:[NSArray class]]
        ? propertyList[@"timeZoneIdentifiers"]
        : @[];
    for (id value in preferredLanguages) {
        if (![value isKindOfClass:[NSString class]]) {
            return nil;
        }
    }
    for (id value in timeZoneIdentifiers) {
        if (![value isKindOfClass:[NSString class]]) {
            return nil;
        }
    }
    PXRegionIdentity *identity = [[self alloc] init];
    identity.stableRegionIdentifier = [propertyList[@"regionID"] isKindOfClass:[NSString class]]
        ? propertyList[@"regionID"]
        : @"";
    identity.countryCode = [propertyList[@"countryCode"] isKindOfClass:[NSString class]]
        ? propertyList[@"countryCode"]
        : @"";
    identity.primaryLanguageTag = [propertyList[@"primaryLanguageTag"] isKindOfClass:[NSString class]]
        ? propertyList[@"primaryLanguageTag"]
        : @"";
    identity.preferredLanguages = [preferredLanguages copy];
    identity.localeIdentifier = [propertyList[@"localeIdentifier"] isKindOfClass:[NSString class]]
        ? propertyList[@"localeIdentifier"]
        : @"";
    identity.timeZoneIdentifier = [propertyList[@"timeZone"] isKindOfClass:[NSString class]]
        ? propertyList[@"timeZone"]
        : @"";
    identity.timeZoneIdentifiers = [timeZoneIdentifiers copy];
    identity.currencyCode = [propertyList[@"currencyCode"] isKindOfClass:[NSString class]]
        ? propertyList[@"currencyCode"]
        : @"";
    identity.calendarIdentifier = [propertyList[@"calendarIdentifier"] isKindOfClass:[NSString class]]
        ? propertyList[@"calendarIdentifier"]
        : @"";
    identity.measurementSystem = [propertyList[@"measurementSystem"] isKindOfClass:[NSString class]]
        ? propertyList[@"measurementSystem"]
        : @"";
    identity.temperatureUnit = [propertyList[@"temperatureUnit"] isKindOfClass:[NSString class]]
        ? propertyList[@"temperatureUnit"]
        : @"";
    return [identity validate] ? identity : nil;
}

@end

static PXRegionIdentity *PXRegion(NSDictionary<NSString *, id> *propertyList) {
    return [PXRegionIdentity identityWithPropertyList:propertyList];
}

static NSUInteger PXSeededTimeZoneIndex(NSData *seed, NSString *countryCode, NSUInteger upperBound) {
    if (upperBound == 0) {
        return 0;
    }
    uint64_t hash = UINT64_C(1469598103934665603);
    const uint8_t *seedBytes = seed.bytes;
    for (NSUInteger index = 0; index < seed.length; index++) {
        hash ^= seedBytes[index];
        hash *= UINT64_C(1099511628211);
    }
    NSData *countryData = [countryCode.uppercaseString dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *countryBytes = countryData.bytes;
    for (NSUInteger index = 0; index < countryData.length; index++) {
        hash ^= countryBytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return (NSUInteger)(hash % upperBound);
}

NSArray<PXRegionIdentity *> *PXRegionCatalog(void) {
    static NSArray<PXRegionIdentity *> *catalog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catalog = @[
            PXRegion(@{
                @"regionID": @"us",
                @"countryCode": @"US",
                @"primaryLanguageTag": @"en-US",
                @"preferredLanguages": @[@"en-US", @"es-US"],
                @"localeIdentifier": @"en_US",
                @"timeZone": @"America/New_York",
                @"timeZoneIdentifiers": @[
                    @"America/New_York", @"America/Chicago", @"America/Denver", @"America/Los_Angeles"
                ],
                @"currencyCode": @"USD",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"us",
                @"temperatureUnit": @"fahrenheit"
            }),
            PXRegion(@{
                @"regionID": @"in",
                @"countryCode": @"IN",
                @"primaryLanguageTag": @"en-IN",
                @"preferredLanguages": @[@"en-IN", @"hi-IN"],
                @"localeIdentifier": @"en_IN",
                @"timeZone": @"Asia/Kolkata",
                @"timeZoneIdentifiers": @[@"Asia/Kolkata"],
                @"currencyCode": @"INR",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"metric",
                @"temperatureUnit": @"celsius"
            }),
            PXRegion(@{
                @"regionID": @"ca",
                @"countryCode": @"CA",
                @"primaryLanguageTag": @"en-CA",
                @"preferredLanguages": @[@"en-CA", @"fr-CA"],
                @"localeIdentifier": @"en_CA",
                @"timeZone": @"America/Toronto",
                @"timeZoneIdentifiers": @[@"America/Toronto", @"America/Vancouver"],
                @"currencyCode": @"CAD",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"metric",
                @"temperatureUnit": @"celsius"
            }),
            PXRegion(@{
                @"regionID": @"fr",
                @"countryCode": @"FR",
                @"primaryLanguageTag": @"fr-FR",
                @"preferredLanguages": @[@"fr-FR"],
                @"localeIdentifier": @"fr_FR",
                @"timeZone": @"Europe/Paris",
                @"timeZoneIdentifiers": @[@"Europe/Paris"],
                @"currencyCode": @"EUR",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"metric",
                @"temperatureUnit": @"celsius"
            }),
            PXRegion(@{
                @"regionID": @"gb",
                @"countryCode": @"GB",
                @"primaryLanguageTag": @"en-GB",
                @"preferredLanguages": @[@"en-GB"],
                @"localeIdentifier": @"en_GB",
                @"timeZone": @"Europe/London",
                @"timeZoneIdentifiers": @[@"Europe/London"],
                @"currencyCode": @"GBP",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"uk",
                @"temperatureUnit": @"celsius"
            }),
            PXRegion(@{
                @"regionID": @"de",
                @"countryCode": @"DE",
                @"primaryLanguageTag": @"de-DE",
                @"preferredLanguages": @[@"de-DE"],
                @"localeIdentifier": @"de_DE",
                @"timeZone": @"Europe/Berlin",
                @"timeZoneIdentifiers": @[@"Europe/Berlin"],
                @"currencyCode": @"EUR",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"metric",
                @"temperatureUnit": @"celsius"
            }),
            PXRegion(@{
                @"regionID": @"au",
                @"countryCode": @"AU",
                @"primaryLanguageTag": @"en-AU",
                @"preferredLanguages": @[@"en-AU"],
                @"localeIdentifier": @"en_AU",
                @"timeZone": @"Australia/Sydney",
                @"timeZoneIdentifiers": @[@"Australia/Sydney", @"Australia/Perth"],
                @"currencyCode": @"AUD",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"metric",
                @"temperatureUnit": @"celsius"
            }),
            PXRegion(@{
                @"regionID": @"jp",
                @"countryCode": @"JP",
                @"primaryLanguageTag": @"ja-JP",
                @"preferredLanguages": @[@"ja-JP"],
                @"localeIdentifier": @"ja_JP",
                @"timeZone": @"Asia/Tokyo",
                @"timeZoneIdentifiers": @[@"Asia/Tokyo"],
                @"currencyCode": @"JPY",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"metric",
                @"temperatureUnit": @"celsius"
            }),
            PXRegion(@{
                @"regionID": @"br",
                @"countryCode": @"BR",
                @"primaryLanguageTag": @"pt-BR",
                @"preferredLanguages": @[@"pt-BR"],
                @"localeIdentifier": @"pt_BR",
                @"timeZone": @"America/Sao_Paulo",
                @"timeZoneIdentifiers": @[@"America/Sao_Paulo", @"America/Manaus"],
                @"currencyCode": @"BRL",
                @"calendarIdentifier": @"gregorian",
                @"measurementSystem": @"metric",
                @"temperatureUnit": @"celsius"
            })
        ];
    });
    return catalog;
}

PXRegionIdentity *PXRegionIdentityForCountryCode(NSString *countryCode, NSData *seed) {
    for (PXRegionIdentity *identity in PXRegionCatalog()) {
        if ([identity.countryCode caseInsensitiveCompare:countryCode] == NSOrderedSame) {
            NSUInteger timeZoneIndex = PXSeededTimeZoneIndex(seed,
                                                             identity.countryCode,
                                                             identity.timeZoneIdentifiers.count);
            NSMutableDictionary<NSString *, id> *propertyList =
                [[identity propertyListRepresentation] mutableCopy];
            propertyList[@"timeZone"] = identity.timeZoneIdentifiers[timeZoneIndex];
            return [PXRegionIdentity identityWithPropertyList:propertyList];
        }
    }
    return nil;
}

PXRegionIdentity *PXRegionIdentityByCompletingPropertyList(NSDictionary<NSString *, id> *propertyList,
                                                           NSString *fallbackCountryCode,
                                                           NSData *seed) {
    PXRegionIdentity *completeIdentity = [PXRegionIdentity identityWithPropertyList:propertyList];
    if (completeIdentity && (fallbackCountryCode.length == 0 ||
        [completeIdentity.countryCode caseInsensitiveCompare:fallbackCountryCode] == NSOrderedSame)) {
        return completeIdentity;
    }
    NSString *countryCode = [propertyList[@"countryCode"] isKindOfClass:[NSString class]]
        ? propertyList[@"countryCode"]
        : fallbackCountryCode;
    BOOL propertyCountryMatchesFallback = fallbackCountryCode.length == 0 || countryCode.length == 0 ||
        [countryCode caseInsensitiveCompare:fallbackCountryCode] == NSOrderedSame;
    if (!propertyCountryMatchesFallback) {
        countryCode = fallbackCountryCode;
    }
    PXRegionIdentity *catalogIdentity = PXRegionIdentityForCountryCode(countryCode, seed);
    NSString *legacyTimeZone = [propertyList[@"timeZone"] isKindOfClass:[NSString class]]
        ? propertyList[@"timeZone"]
        : nil;
    if (!catalogIdentity || !propertyCountryMatchesFallback || legacyTimeZone.length == 0 ||
        ![catalogIdentity.timeZoneIdentifiers containsObject:legacyTimeZone]) {
        return catalogIdentity;
    }
    NSMutableDictionary<NSString *, id> *completedPropertyList =
        [[catalogIdentity propertyListRepresentation] mutableCopy];
    completedPropertyList[@"timeZone"] = legacyTimeZone;
    return [PXRegionIdentity identityWithPropertyList:completedPropertyList];
}
