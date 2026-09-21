#import "RegionEnvironment.h"

@interface PXRegionEnvironmentSnapshot ()

@property (nonatomic, strong, readwrite) PXRegionIdentity *regionIdentity;
@property (nonatomic, strong, readwrite) NSLocale *locale;
@property (nonatomic, strong, readwrite) NSTimeZone *timeZone;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *preferredLanguages;

@end

@interface PXRegionEnvironmentCache ()

@property (nonatomic, copy) PXRegionEnvironmentSourceLoader sourceLoader;
@property (nonatomic, copy) PXRegionEnvironmentScopeEvaluator scopeEvaluator;
@property (nonatomic, copy, nullable) NSString *cachedGenerationID;
@property (nonatomic, strong, nullable) PXRegionEnvironmentSnapshot *cachedSnapshot;
@property (nonatomic, strong) NSMutableArray<PXRegionEnvironmentSnapshot *> *retiredSnapshots;

@end


static __thread BOOL PXRegionEnvironmentLoadInProgress = NO;

@implementation PXRegionEnvironmentSnapshot

- (instancetype)initWithRegionIdentity:(PXRegionIdentity *)regionIdentity {
    self = [super init];
    if (self) {
        _regionIdentity = regionIdentity;
        _locale = [NSLocale localeWithLocaleIdentifier:regionIdentity.localeIdentifier];
        _timeZone = [NSTimeZone timeZoneWithName:regionIdentity.timeZoneIdentifier];
        _preferredLanguages = [regionIdentity.preferredLanguages copy];
    }
    return self;
}

- (NSCalendar *)newCalendar {
    NSCalendarIdentifier calendarIdentifier = [self.regionIdentity.calendarIdentifier isEqualToString:@"gregorian"]
        ? NSCalendarIdentifierGregorian
        : self.regionIdentity.calendarIdentifier;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:calendarIdentifier];
    calendar.locale = self.locale;
    calendar.timeZone = self.timeZone;
    return calendar;
}

- (nullable id)regionalPreferenceValueForKey:(NSString *)key {
    if ([key isEqualToString:@"AppleLanguages"]) {
        return self.preferredLanguages;
    }
    if ([key isEqualToString:@"AppleLocale"]) {
        return self.regionIdentity.localeIdentifier;
    }
    if ([key isEqualToString:@"AppleMeasurementUnits"]) {
        return [self.regionIdentity.measurementSystem isEqualToString:@"us"] ? @"Inches" : @"Centimeters";
    }
    if ([key isEqualToString:@"AppleMetricUnits"]) {
        return @(![self.regionIdentity.measurementSystem isEqualToString:@"us"]);
    }
    if ([key isEqualToString:@"AppleTemperatureUnit"]) {
        return [self.regionIdentity.temperatureUnit isEqualToString:@"fahrenheit"]
            ? @"Fahrenheit"
            : @"Celsius";
    }
    if ([key isEqualToString:@"AppleCalendarIdentifier"]) {
        return self.regionIdentity.calendarIdentifier;
    }
    if ([key isEqualToString:@"AppleTimeZone"]) {
        return self.regionIdentity.timeZoneIdentifier;
    }
    return nil;
}

- (nullable id)valueForRegionalPreferenceKey:(NSString *)key
                               requestedClass:(Class)requestedClass
                                originalValue:(nullable id)originalValue {
    id regionalValue = [self regionalPreferenceValueForKey:key];
    if (!regionalValue || ![regionalValue isKindOfClass:requestedClass]) {
        return originalValue;
    }
    return regionalValue;
}

- (NSDictionary<NSString *, id> *)dictionaryByApplyingRegionalPreferences:
    (NSDictionary<NSString *, id> *)dictionary {
    NSMutableDictionary<NSString *, id> *regionalDictionary = [dictionary mutableCopy];
    NSArray<NSString *> *regionalKeys = @[
        @"AppleLanguages",
        @"AppleLocale",
        @"AppleMeasurementUnits",
        @"AppleMetricUnits",
        @"AppleTemperatureUnit",
        @"AppleCalendarIdentifier",
        @"AppleTimeZone"
    ];
    for (NSString *key in regionalKeys) {
        regionalDictionary[key] = [self regionalPreferenceValueForKey:key];
    }
    return [regionalDictionary copy];
}

@end

@implementation PXRegionEnvironmentCache

- (instancetype)initWithSourceLoader:(PXRegionEnvironmentSourceLoader)sourceLoader
                       scopeEvaluator:(PXRegionEnvironmentScopeEvaluator)scopeEvaluator {
    self = [super init];
    if (self) {
        _sourceLoader = [sourceLoader copy];
        _scopeEvaluator = [scopeEvaluator copy];
        _retiredSnapshots = [NSMutableArray array];
    }
    return self;
}

- (nullable NSDictionary<NSString *, id> *)loadValidatedSnapshotResult {
    if (PXRegionEnvironmentLoadInProgress) {
        return nil;
    }
    PXRegionEnvironmentLoadInProgress = YES;
    NSDictionary<NSString *, id> *result = nil;
    @try {
        if (!self.scopeEvaluator()) {
            return nil;
        }
        NSDictionary<NSString *, id> *source = self.sourceLoader();
        NSString *generationID = [source[@"generationID"] isKindOfClass:[NSString class]]
            ? source[@"generationID"]
            : nil;
        NSDictionary<NSString *, id> *regionPropertyList = [source[@"region"] isKindOfClass:[NSDictionary class]]
            ? source[@"region"]
            : nil;
        PXRegionIdentity *regionIdentity = regionPropertyList
            ? [PXRegionIdentity identityWithPropertyList:regionPropertyList]
            : nil;
        if (generationID.length == 0 || !regionIdentity) {
            return nil;
        }
        result = @{
            @"generationID": generationID,
            @"snapshot": [[PXRegionEnvironmentSnapshot alloc] initWithRegionIdentity:regionIdentity]
        };
    } @finally {
        PXRegionEnvironmentLoadInProgress = NO;
    }
    return result;
}

- (nullable PXRegionEnvironmentSnapshot *)currentSnapshot {
    if (PXRegionEnvironmentLoadInProgress) {
        return nil;
    }
    PXRegionEnvironmentLoadInProgress = YES;
    BOOL scoped = NO;
    @try {
        scoped = self.scopeEvaluator();
    } @finally {
        PXRegionEnvironmentLoadInProgress = NO;
    }
    if (!scoped) {
        return nil;
    }
    @synchronized(self) {
        if (self.cachedSnapshot) {
            return self.cachedSnapshot;
        }
        NSDictionary<NSString *, id> *result = [self loadValidatedSnapshotResult];
        self.cachedGenerationID = result[@"generationID"];
        self.cachedSnapshot = result[@"snapshot"];
        return self.cachedSnapshot;
    }
}

- (BOOL)reloadAfterGenerationChange {
    NSDictionary<NSString *, id> *result = [self loadValidatedSnapshotResult];
    @synchronized(self) {
        if (!result) {
            if (self.cachedSnapshot) {
                [self.retiredSnapshots addObject:self.cachedSnapshot];
            }
            self.cachedGenerationID = nil;
            self.cachedSnapshot = nil;
            return NO;
        }
        NSString *generationID = result[@"generationID"];
        BOOL generationChanged = ![generationID isEqualToString:self.cachedGenerationID];
        if (!generationChanged) {
            return NO;
        }
        if (self.cachedSnapshot) {
            [self.retiredSnapshots addObject:self.cachedSnapshot];
        }
        self.cachedGenerationID = generationID;
        self.cachedSnapshot = result[@"snapshot"];
        return generationChanged;
    }
}

- (void)invalidate {
    @synchronized(self) {
        if (self.cachedSnapshot) {
            [self.retiredSnapshots addObject:self.cachedSnapshot];
        }
        self.cachedGenerationID = nil;
        self.cachedSnapshot = nil;
    }
}

@end
