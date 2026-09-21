#import <Foundation/Foundation.h>

#import "AppIdentityHookSupport.h"
#import "PXProcessHookPolicy.h"
#import "RegionEnvironment.h"

static PXAppIdentityRecord *PXCurrentInstallIdentity = nil;
static PXAppInstallIdentityPolicy *PXCurrentInstallPolicy = nil;

static BOOL PXShouldVirtualizeInstallKey(NSString *key) {
    return !PXAppIdentityMappingsChangedSinceLaunch() && PXCurrentInstallIdentity &&
        PXInstallIdentifierKeyMatches(key, PXCurrentInstallIdentity.installIdentifierKeys);
}

static NSDictionary *PXDictionaryByVirtualizingInstallKeys(NSDictionary *dictionary) {
    return !PXAppIdentityMappingsChangedSinceLaunch() && PXCurrentInstallPolicy
        ? [PXCurrentInstallPolicy dictionaryByVirtualizingInstallKeys:dictionary]
        : dictionary;
}

static NSDictionary *PXDictionaryByApplyingPreferenceReadPolicies(NSDictionary *dictionary) {
    NSDictionary *installDictionary = PXDictionaryByVirtualizingInstallKeys(dictionary);
    PXRegionEnvironmentSnapshot *regionalSnapshot = PXCurrentRegionEnvironmentSnapshot();
    return regionalSnapshot
        ? [regionalSnapshot dictionaryByApplyingRegionalPreferences:installDictionary]
        : installDictionary;
}

static id PXRegionalPreferenceValue(id originalValue, NSString *key, Class requestedClass) {
    PXRegionEnvironmentSnapshot *snapshot = PXCurrentRegionEnvironmentSnapshot();
    return snapshot
        ? [snapshot valueForRegionalPreferenceKey:key requestedClass:requestedClass originalValue:originalValue]
        : originalValue;
}

%group PXAppInstallIdentityHooks

%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    id originalValue = %orig;
    id regionalValue = PXRegionalPreferenceValue(originalValue, defaultName, [NSObject class]);
    return !PXAppIdentityMappingsChangedSinceLaunch() && PXCurrentInstallPolicy
        ? [PXCurrentInstallPolicy valueForRead:regionalValue key:defaultName requestedClass:[NSObject class]]
        : regionalValue;
}

- (NSString *)stringForKey:(NSString *)defaultName {
    NSString *originalValue = %orig;
    NSString *regionalValue = PXRegionalPreferenceValue(originalValue, defaultName, [NSString class]);
    return !PXAppIdentityMappingsChangedSinceLaunch() && PXCurrentInstallPolicy
        ? [PXCurrentInstallPolicy valueForRead:regionalValue key:defaultName requestedClass:[NSString class]]
        : regionalValue;
}

- (NSData *)dataForKey:(NSString *)defaultName {
    NSData *originalValue = %orig;
    NSData *regionalValue = PXRegionalPreferenceValue(originalValue, defaultName, [NSData class]);
    return !PXAppIdentityMappingsChangedSinceLaunch() && PXCurrentInstallPolicy
        ? [PXCurrentInstallPolicy valueForRead:regionalValue key:defaultName requestedClass:[NSData class]]
        : regionalValue;
}

- (NSArray *)arrayForKey:(NSString *)defaultName {
    NSArray *originalValue = %orig;
    return PXRegionalPreferenceValue(originalValue, defaultName, [NSArray class]);
}

- (NSArray<NSString *> *)stringArrayForKey:(NSString *)defaultName {
    NSArray<NSString *> *originalValue = %orig;
    return PXRegionalPreferenceValue(originalValue, defaultName, [NSArray class]);
}

- (BOOL)boolForKey:(NSString *)defaultName {
    NSNumber *regionalValue = [PXCurrentRegionEnvironmentSnapshot()
        regionalPreferenceValueForKey:defaultName];
    return [regionalValue isKindOfClass:[NSNumber class]] ? regionalValue.boolValue : %orig;
}

- (id)objectForKeyedSubscript:(NSString *)key {
    id originalValue = %orig;
    id regionalValue = PXRegionalPreferenceValue(originalValue, key, [NSObject class]);
    return !PXAppIdentityMappingsChangedSinceLaunch() && PXCurrentInstallPolicy
        ? [PXCurrentInstallPolicy valueForRead:regionalValue key:key requestedClass:[NSObject class]]
        : regionalValue;
}

- (id)valueForKey:(NSString *)key {
    id regionalValue = [PXCurrentRegionEnvironmentSnapshot() regionalPreferenceValueForKey:key];
    if (regionalValue) {
        return regionalValue;
    }
    if (PXShouldVirtualizeInstallKey(key)) {
        return PXCurrentInstallIdentity.installUUID;
    }
    return %orig;
}

- (NSDictionary *)dictionaryRepresentation {
    NSDictionary *originalRepresentation = %orig;
    return PXDictionaryByApplyingPreferenceReadPolicies(originalRepresentation);
}

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    if (PXShouldVirtualizeInstallKey(defaultName)) {
        %orig([PXCurrentInstallPolicy valueForWrite:value key:defaultName], defaultName);
        return;
    }
    %orig;
}

- (void)setObject:(id)value forKeyedSubscript:(NSString *)key {
    if (PXShouldVirtualizeInstallKey(key)) {
        %orig([PXCurrentInstallPolicy valueForWrite:value key:key], key);
        return;
    }
    %orig;
}

- (void)setValue:(id)value forKey:(NSString *)key {
    if (PXShouldVirtualizeInstallKey(key)) {
        %orig(PXCurrentInstallIdentity.installUUID, key);
        return;
    }
    %orig;
}

- (void)registerDefaults:(NSDictionary<NSString *, id> *)registrationDictionary {
    %orig(PXDictionaryByVirtualizingInstallKeys(registrationDictionary));
}

- (void)setPersistentDomain:(NSDictionary<NSString *, id> *)domain forName:(NSString *)domainName {
    %orig(PXDictionaryByVirtualizingInstallKeys(domain), domainName);
}

%end

%end


%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXObserveAppIdentityMappingChanges();
        PXCurrentInstallIdentity = PXPrepareCurrentProcessAppIdentity();
        if (!PXCurrentInstallIdentity) {
            return;
        }
        PXCurrentInstallPolicy = [[PXAppInstallIdentityPolicy alloc] initWithIdentity:PXCurrentInstallIdentity];
        %init(PXAppInstallIdentityHooks);
    }
}
