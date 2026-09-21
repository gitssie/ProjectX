#import <Foundation/Foundation.h>
#include <assert.h>

#import "RegionIdentity.h"

static void testFranceRegionIdentityIsCompleteAndCoherent(void) {
    NSData *seed = [@"france-seed" dataUsingEncoding:NSUTF8StringEncoding];
    PXRegionIdentity *region = PXRegionIdentityForCountryCode(@"FR", seed);
    assert(region != nil);
    assert([region.stableRegionIdentifier isEqualToString:@"fr"]);
    assert([region.countryCode isEqualToString:@"FR"]);
    assert([region.primaryLanguageTag isEqualToString:@"fr-FR"]);
    assert([region.preferredLanguages.firstObject isEqualToString:@"fr-FR"]);
    assert([region.localeIdentifier isEqualToString:@"fr_FR"]);
    assert([region.currencyCode isEqualToString:@"EUR"]);
    assert([region.timeZoneIdentifier isEqualToString:@"Europe/Paris"]);
    assert([region.calendarIdentifier isEqualToString:@"gregorian"]);
    assert([region validate]);
}

static void testRegionCatalogCoversEveryCarrierCountryWithValidUniqueRecords(void) {
    NSSet<NSString *> *expectedCountryCodes = [NSSet setWithArray:@[
        @"US", @"IN", @"CA", @"FR", @"GB", @"DE", @"AU", @"JP", @"BR"
    ]];
    NSMutableSet<NSString *> *actualCountryCodes = [NSMutableSet set];
    NSMutableSet<NSString *> *regionIdentifiers = [NSMutableSet set];
    for (PXRegionIdentity *region in PXRegionCatalog()) {
        assert([region validate]);
        assert(![actualCountryCodes containsObject:region.countryCode]);
        assert(![regionIdentifiers containsObject:region.stableRegionIdentifier]);
        [actualCountryCodes addObject:region.countryCode];
        [regionIdentifiers addObject:region.stableRegionIdentifier];
    }
    assert([actualCountryCodes isEqualToSet:expectedCountryCodes]);
}

static void testTimezoneSelectionIsSeededStableAndCountryBound(void) {
    NSData *stableSeed = [@"stable-us-seed" dataUsingEncoding:NSUTF8StringEncoding];
    PXRegionIdentity *first = PXRegionIdentityForCountryCode(@"US", stableSeed);
    PXRegionIdentity *second = PXRegionIdentityForCountryCode(@"us", stableSeed);
    assert([first.timeZoneIdentifier isEqualToString:second.timeZoneIdentifier]);

    NSMutableSet<NSString *> *selectedTimeZones = [NSMutableSet set];
    for (NSUInteger index = 0; index < 64; index++) {
        NSData *seed = [[NSString stringWithFormat:@"seed-%lu", (unsigned long)index]
            dataUsingEncoding:NSUTF8StringEncoding];
        PXRegionIdentity *selection = PXRegionIdentityForCountryCode(@"US", seed);
        assert([first.timeZoneIdentifiers containsObject:selection.timeZoneIdentifier]);
        [selectedTimeZones addObject:selection.timeZoneIdentifier];
    }
    assert(selectedTimeZones.count > 1);
}

static void testLegacyPartialRegionCompletesIdempotentlyWithoutChangingValidTimezone(void) {
    NSData *seed = nil;
    for (NSUInteger index = 0; index < 64; index++) {
        NSData *candidateSeed = [[NSString stringWithFormat:@"migration-seed-%lu", (unsigned long)index]
            dataUsingEncoding:NSUTF8StringEncoding];
        PXRegionIdentity *candidate = PXRegionIdentityForCountryCode(@"CA", candidateSeed);
        if (![candidate.timeZoneIdentifier isEqualToString:@"America/Vancouver"]) {
            seed = candidateSeed;
            break;
        }
    }
    assert(seed != nil);
    NSDictionary<NSString *, id> *legacyRegion = @{
        @"countryCode": @"ca",
        @"localeIdentifier": @"en_CA",
        @"timeZone": @"America/Vancouver",
        @"currencyCode": @"CAD"
    };
    PXRegionIdentity *completed = PXRegionIdentityByCompletingPropertyList(legacyRegion, @"CA", seed);
    assert(completed != nil);
    assert([completed.timeZoneIdentifier isEqualToString:@"America/Vancouver"]);
    PXRegionIdentity *secondCompletion = PXRegionIdentityByCompletingPropertyList(
        [completed propertyListRepresentation],
        @"CA",
        seed);
    assert([[completed propertyListRepresentation] isEqualToDictionary:
        [secondCompletion propertyListRepresentation]]);
}

static void testCorruptCrossFieldRegionMetadataIsRejected(void) {
    PXRegionIdentity *france = PXRegionIdentityForCountryCode(
        @"FR",
        [@"invalid-region" dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableDictionary<NSString *, id> *invalidLanguage =
        [[france propertyListRepresentation] mutableCopy];
    invalidLanguage[@"primaryLanguageTag"] = @"en-US";
    invalidLanguage[@"preferredLanguages"] = @[@"en-US"];
    assert([PXRegionIdentity identityWithPropertyList:invalidLanguage] == nil);
}

int main(void) {
    @autoreleasepool {
        testFranceRegionIdentityIsCompleteAndCoherent();
        testRegionCatalogCoversEveryCarrierCountryWithValidUniqueRecords();
        testTimezoneSelectionIsSeededStableAndCountryBound();
        testLegacyPartialRegionCompletesIdempotentlyWithoutChangingValidTimezone();
        testCorruptCrossFieldRegionMetadataIsRejected();
    }
    return 0;
}
