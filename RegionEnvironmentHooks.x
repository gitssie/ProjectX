#import "PXRootHidePath.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#import "AppIdentity.h"
#import "IdentifierManager.h"
#import "ProfileManifest.h"
#import "PXProcessHookPolicy.h"
#import "RegionEnvironment.h"

static BOOL PXRegionEnvironmentShouldApply(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO)) {
        return NO;
    }
    IdentifierManager *manager = [IdentifierManager sharedManager];
    return PXAppIdentityBundleIsEligible(bundleIdentifier,
                                         [manager isApplicationEnabled:bundleIdentifier],
                                         [manager isExtensionEnabled:bundleIdentifier]);
}

static NSDictionary<NSString *, id> *PXLoadCurrentRegionEnvironmentSource(void) {
    IdentifierManager *manager = [IdentifierManager sharedManager];
    NSString *identityDirectory = [manager profileIdentityPath];
    if (identityDirectory.length == 0) {
        return nil;
    }
    PXProfileManifest *manifest = [[[PXProfileStore alloc] initWithIdentityDirectory:identityDirectory]
        activeManifestWithError:nil];
    if (!manifest ||
        manifest.generationID.length == 0 || manifest.region.count == 0 ||
        ![PXRegionIdentity identityWithPropertyList:manifest.region]) {
        return nil;
    }
    return @{ @"generationID": manifest.generationID, @"region": manifest.region };
}

static PXRegionEnvironmentCache *PXRegionEnvironmentProcessCache(void) {
    static PXRegionEnvironmentCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[PXRegionEnvironmentCache alloc]
            initWithSourceLoader:^NSDictionary<NSString *, id> *{
                return PXLoadCurrentRegionEnvironmentSource();
            }
            scopeEvaluator:^BOOL{
                return PXRegionEnvironmentShouldApply();
            }];
    });
    return cache;
}

PXRegionEnvironmentSnapshot *PXCurrentRegionEnvironmentSnapshot(void) {
    return PXRegionEnvironmentProcessCache().currentSnapshot;
}

static void PXRegionGenerationChangedCallback(CFNotificationCenterRef center,
                                              void *observer,
                                              CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    if (![PXRegionEnvironmentProcessCache() reloadAfterGenerationChange]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:NSCurrentLocaleDidChangeNotification
                                                            object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:NSSystemTimeZoneDidChangeNotification
                                                            object:nil];
    });
}

%hook NSLocale

+ (instancetype)currentLocale {
    return PXCurrentRegionEnvironmentSnapshot().locale ?: %orig;
}

+ (instancetype)systemLocale {
    return PXCurrentRegionEnvironmentSnapshot().locale ?: %orig;
}

+ (instancetype)autoupdatingCurrentLocale {
    return PXCurrentRegionEnvironmentSnapshot().locale ?: %orig;
}

+ (NSArray<NSString *> *)preferredLanguages {
    return PXCurrentRegionEnvironmentSnapshot().preferredLanguages ?: %orig;
}

%end

%hook NSTimeZone

+ (instancetype)localTimeZone {
    return PXCurrentRegionEnvironmentSnapshot().timeZone ?: %orig;
}

+ (instancetype)systemTimeZone {
    return PXCurrentRegionEnvironmentSnapshot().timeZone ?: %orig;
}

+ (instancetype)defaultTimeZone {
    return PXCurrentRegionEnvironmentSnapshot().timeZone ?: %orig;
}

+ (instancetype)autoupdatingCurrentTimeZone {
    return PXCurrentRegionEnvironmentSnapshot().timeZone ?: %orig;
}

%end


%hook NSCalendar

+ (instancetype)currentCalendar {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? [snapshot newCalendar] : %orig;
}

+ (instancetype)autoupdatingCurrentCalendar {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? [snapshot newCalendar] : %orig;
}

%end


%hook NSBundle

+ (NSArray<NSString *> *)preferredLocalizationsFromArray:(NSArray<NSString *> *)localizationsArray {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    if (!snapshot) {
        return %orig;
    }
    return [%c(NSBundle) preferredLocalizationsFromArray:localizationsArray
                                          forPreferences:snapshot.preferredLanguages];
}

- (NSArray<NSString *> *)preferredLocalizations {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    if (!snapshot) {
        return %orig;
    }
    return [%c(NSBundle) preferredLocalizationsFromArray:self.localizations
                                          forPreferences:snapshot.preferredLanguages];
}

%end


%hookf(CFLocaleRef, CFLocaleCopyCurrent) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? CFBridgingRetain(snapshot.locale) : %orig;
}

%hookf(CFLocaleRef, CFLocaleGetSystem) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? (__bridge CFLocaleRef)snapshot.locale : %orig;
}

%hookf(CFArrayRef, CFLocaleCopyPreferredLanguages) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? CFBridgingRetain([snapshot.preferredLanguages copy]) : %orig;
}

%hookf(CFTimeZoneRef, CFTimeZoneCopySystem) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? CFBridgingRetain(snapshot.timeZone) : %orig;
}

%hookf(CFTimeZoneRef, CFTimeZoneCopyDefault) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? CFBridgingRetain(snapshot.timeZone) : %orig;
}

%hookf(CFCalendarRef, CFCalendarCopyCurrent) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot ? (__bridge_retained CFCalendarRef)[snapshot newCalendar] : %orig;
}

%hookf(CFPropertyListRef, CFPreferencesCopyAppValue, CFStringRef key, CFStringRef applicationID) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    NSString *preferenceKey = (__bridge NSString *)key;
    id regionalValue = [snapshot regionalPreferenceValueForKey:preferenceKey];
    return regionalValue ? CFBridgingRetain(regionalValue) : %orig;
}

%hookf(CFPropertyListRef, CFPreferencesCopyValue, CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    NSString *preferenceKey = (__bridge NSString *)key;
    id regionalValue = [snapshot regionalPreferenceValueForKey:preferenceKey];
    return regionalValue ? CFBridgingRetain(regionalValue) : %orig;
}

%hookf(CFDictionaryRef, CFPreferencesCopyMultiple, CFArrayRef keysToFetch, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    if (!snapshot) {
        return %orig;
    }
    CFDictionaryRef originalValuesReference = %orig;
    NSDictionary<NSString *, id> *originalValues = CFBridgingRelease(originalValuesReference);
    if (!keysToFetch) {
        return CFBridgingRetain([snapshot dictionaryByApplyingRegionalPreferences:originalValues ?: @{}]);
    }
    NSMutableDictionary<NSString *, id> *regionalValues = [originalValues mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in (__bridge NSArray *)keysToFetch) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        id regionalValue = [snapshot regionalPreferenceValueForKey:key];
        if (regionalValue) {
            regionalValues[key] = regionalValue;
        }
    }
    return CFBridgingRetain([regionalValues copy]);
}

%hookf(Boolean, CFPreferencesGetAppBooleanValue, CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    NSNumber *regionalValue = [snapshot regionalPreferenceValueForKey:(__bridge NSString *)key];
    if (![regionalValue isKindOfClass:[NSNumber class]]) {
        return %orig;
    }
    if (keyExistsAndHasValidFormat) {
        *keyExistsAndHasValidFormat = true;
    }
    return regionalValue.boolValue;
}


%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXRegionEnvironmentProcessCache();
        [IdentifierManager sharedManager];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        PXRegionGenerationChangedCallback,
                                        CFSTR("com.hydra.projectx.profileGenerationChanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
    }
}
