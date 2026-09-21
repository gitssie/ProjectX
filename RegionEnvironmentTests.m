#import <Foundation/Foundation.h>
#include <assert.h>

#import "AppIdentity.h"
#import "RegionEnvironment.h"

static void testSnapshotProducesCoherentLocaleTimezoneAndFreshCalendars(void) {
    PXRegionIdentity *region = PXRegionIdentityForCountryCode(
        @"FR",
        [@"snapshot-seed" dataUsingEncoding:NSUTF8StringEncoding]);
    PXRegionEnvironmentSnapshot *snapshot = [[PXRegionEnvironmentSnapshot alloc]
        initWithRegionIdentity:region];
    assert([snapshot.locale.countryCode isEqualToString:@"FR"]);
    assert([snapshot.locale.currencyCode isEqualToString:@"EUR"]);
    assert([snapshot.timeZone.name isEqualToString:@"Europe/Paris"]);
    assert([snapshot.preferredLanguages isEqualToArray:@[@"fr-FR"]]);

    NSCalendar *firstCalendar = [snapshot newCalendar];
    NSCalendar *secondCalendar = [snapshot newCalendar];
    assert(firstCalendar != secondCalendar);
    assert([firstCalendar.calendarIdentifier isEqualToString:NSCalendarIdentifierGregorian]);
    assert([firstCalendar.locale.localeIdentifier isEqualToString:@"fr_FR"]);
    assert([firstCalendar.timeZone.name isEqualToString:@"Europe/Paris"]);
}

static void testRegionalPreferencesOverrideOnlyExactAppleKeys(void) {
    PXRegionIdentity *region = PXRegionIdentityForCountryCode(
        @"FR",
        [@"preference-seed" dataUsingEncoding:NSUTF8StringEncoding]);
    PXRegionEnvironmentSnapshot *snapshot = [[PXRegionEnvironmentSnapshot alloc]
        initWithRegionIdentity:region];
    assert([[snapshot valueForRegionalPreferenceKey:@"AppleLanguages"
                                      requestedClass:[NSArray class]
                                       originalValue:@[@"en-US"]]
        isEqualToArray:@[@"fr-FR"]]);
    assert([[snapshot valueForRegionalPreferenceKey:@"AppleLocale"
                                      requestedClass:[NSString class]
                                       originalValue:@"en_US"] isEqualToString:@"fr_FR"]);
    assert([[snapshot valueForRegionalPreferenceKey:@"AppleMetricUnits"
                                      requestedClass:[NSNumber class]
                                       originalValue:@NO] boolValue]);
    assert([[snapshot valueForRegionalPreferenceKey:@"AppleTemperatureUnit"
                                      requestedClass:[NSString class]
                                       originalValue:@"Fahrenheit"] isEqualToString:@"Celsius"]);
    NSString *installIdentity = NSUUID.UUID.UUIDString;
    assert([snapshot valueForRegionalPreferenceKey:@"installation_id"
                                     requestedClass:[NSString class]
                                      originalValue:installIdentity] == installIdentity);
    assert([[snapshot valueForRegionalPreferenceKey:@"AppleLocale"
                                      requestedClass:[NSArray class]
                                       originalValue:@[@"untouched"]]
        isEqualToArray:@[@"untouched"]]);
}

static void testGenerationReloadReplacesCacheOnlyAfterValidActivation(void) {
    PXRegionIdentity *france = PXRegionIdentityForCountryCode(
        @"FR",
        [@"fr-cache" dataUsingEncoding:NSUTF8StringEncoding]);
    PXRegionIdentity *unitedStates = PXRegionIdentityForCountryCode(
        @"US",
        [@"us-cache" dataUsingEncoding:NSUTF8StringEncoding]);
    __block BOOL scoped = YES;
    __block NSDictionary<NSString *, id> *source = @{
        @"generationID": @"generation-fr",
        @"region": [france propertyListRepresentation]
    };
    PXRegionEnvironmentCache *cache = [[PXRegionEnvironmentCache alloc]
        initWithSourceLoader:^NSDictionary<NSString *, id> *{
            return source;
        }
        scopeEvaluator:^BOOL{
            return scoped;
        }];
    assert([cache.currentSnapshot.locale.countryCode isEqualToString:@"FR"]);

    source = @{
        @"generationID": @"generation-us",
        @"region": [unitedStates propertyListRepresentation]
    };
    assert([cache.currentSnapshot.locale.countryCode isEqualToString:@"FR"]);
    assert([cache reloadAfterGenerationChange]);
    assert([cache.currentSnapshot.locale.countryCode isEqualToString:@"US"]);
    assert(![cache reloadAfterGenerationChange]);
    scoped = NO;
    assert(cache.currentSnapshot == nil);
    scoped = YES;
    assert([cache.currentSnapshot.locale.countryCode isEqualToString:@"US"]);

    source = @{@"generationID": @"generation-invalid", @"region": @{@"countryCode": @"ZZ"}};
    assert(![cache reloadAfterGenerationChange]);
    assert(cache.currentSnapshot == nil);
}

static void testRegionalAndAppInstallPreferencePoliciesRemainIndependent(void) {
    PXRegionIdentity *region = PXRegionIdentityForCountryCode(
        @"FR",
        [@"combined-policy" dataUsingEncoding:NSUTF8StringEncoding]);
    PXRegionEnvironmentSnapshot *snapshot = [[PXRegionEnvironmentSnapshot alloc]
        initWithRegionIdentity:region];
    PXAppIdentityRecord *appIdentity = [PXAppIdentityRecord
        identityForProfileSeed:@"profile-seed"
        bundleIdentifier:@"com.example.app"
        installIdentifierKeys:[NSSet setWithObject:@"vendor_install_id"]];
    PXAppInstallIdentityPolicy *installPolicy = [[PXAppInstallIdentityPolicy alloc]
        initWithIdentity:appIdentity];

    id regionalInstallValue = [snapshot valueForRegionalPreferenceKey:@"vendor_install_id"
                                                        requestedClass:[NSString class]
                                                         originalValue:@"original-install"];
    assert([[installPolicy valueForRead:regionalInstallValue
                                    key:@"vendor_install_id"
                         requestedClass:[NSString class]] isEqualToString:appIdentity.installUUID]);
    id regionalLocaleValue = [snapshot valueForRegionalPreferenceKey:@"AppleLocale"
                                                       requestedClass:[NSString class]
                                                        originalValue:@"en_US"];
    assert([[installPolicy valueForRead:regionalLocaleValue
                                    key:@"AppleLocale"
                         requestedClass:[NSString class]] isEqualToString:@"fr_FR"]);
}

int main(void) {
    @autoreleasepool {
        testSnapshotProducesCoherentLocaleTimezoneAndFreshCalendars();
        testRegionalPreferencesOverrideOnlyExactAppleKeys();
        testGenerationReloadReplacesCacheOnlyAfterValidActivation();
        testRegionalAndAppInstallPreferencePoliciesRemainIndependent();
    }
    return 0;
}
