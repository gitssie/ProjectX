#import <Foundation/Foundation.h>

#import "AppIdentityHookSupport.h"
#import "PXProcessHookPolicy.h"

typedef struct __SecTask *PXSecTaskRef;
extern PXSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(PXSecTaskRef task,
                                                CFStringRef entitlement,
                                                CFErrorRef *error);

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *PXPreloadedAppGroupMappings = @{};

static NSArray<NSString *> *PXCurrentProcessAppGroupIdentifiers(void) {
    PXSecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) {
        return @[];
    }
    CFTypeRef entitlementValue = SecTaskCopyValueForEntitlement(
        task,
        CFSTR("com.apple.security.application-groups"),
        NULL);
    CFRelease(task);
    if (!entitlementValue) {
        return @[];
    }
    NSArray *entitlementGroups = [(__bridge id)entitlementValue isKindOfClass:[NSArray class]]
        ? [(__bridge NSArray *)entitlementValue copy]
        : @[];
    CFRelease(entitlementValue);
    NSMutableArray<NSString *> *groupIdentifiers = [NSMutableArray array];
    for (id groupIdentifier in entitlementGroups) {
        if ([groupIdentifier isKindOfClass:[NSString class]] && [groupIdentifier length] > 0) {
            [groupIdentifiers addObject:groupIdentifier];
        }
    }
    return [groupIdentifiers copy];
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *PXLoadAppGroupMappings(
    PXAppIdentityRecord *appIdentity
) {
    if (!PXPrepareCurrentProcessDataPathMapping(appIdentity)) {
        return @{};
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *mappings = [NSMutableDictionary dictionary];
    NSArray<NSString *> *groupIdentifiers = PXCurrentProcessAppGroupIdentifiers();
    NSMutableDictionary<NSString *, NSURL *> *realGroupURLs = [NSMutableDictionary dictionary];
    for (NSString *groupIdentifier in groupIdentifiers) {
        NSURL *realGroupURL = [fileManager containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
        if (realGroupURL.isFileURL && PXIsValidRealAppGroupRoot(realGroupURL.path)) {
            realGroupURLs[groupIdentifier] = realGroupURL;
        }
    }
    NSDictionary<NSString *, PXAppGroupIdentityRecord *> *groupIdentities =
        PXPrepareCurrentProcessGroupIdentities([NSSet setWithArray:realGroupURLs.allKeys]);
    for (NSString *groupIdentifier in realGroupURLs) {
        NSURL *realGroupURL = realGroupURLs[groupIdentifier];
        PXAppGroupIdentityRecord *groupIdentity = groupIdentities[groupIdentifier];
        if (!groupIdentity) {
            continue;
        }
        NSString *virtualGroupRoot = PXVirtualAppGroupRoot(groupIdentity.containerUUID);
        if (![[PXAppIdentityRuntime sharedRuntime] addRealGroupRoot:realGroupURL.path
                                                   virtualGroupRoot:virtualGroupRoot]) {
            continue;
        }
        NSURL *virtualGroupURL = [[PXAppIdentityRuntime sharedRuntime]
            translatedObservableFileURLForURL:realGroupURL];
        if ([virtualGroupURL.path isEqualToString:realGroupURL.path]) {
            continue;
        }
        mappings[groupIdentifier] = @{
            @"realRoot": realGroupURL.path.stringByStandardizingPath,
            @"virtualURL": virtualGroupURL
        };
    }
    return [mappings copy];
}

%group PXAppGroupIdentityHooks

%hook NSFileManager

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSURL *realGroupURL = %orig;
    if (PXAppIdentityMappingsChangedSinceLaunch() ||
        !realGroupURL.isFileURL || !PXIsValidRealAppGroupRoot(realGroupURL.path)) {
        return realGroupURL;
    }
    NSDictionary<NSString *, id> *mapping = PXPreloadedAppGroupMappings[groupIdentifier];
    NSString *cachedRealRoot = mapping[@"realRoot"];
    NSURL *virtualGroupURL = mapping[@"virtualURL"];
    if (![cachedRealRoot isKindOfClass:[NSString class]] ||
        ![virtualGroupURL isKindOfClass:[NSURL class]] ||
        ![realGroupURL.path.stringByStandardizingPath isEqualToString:cachedRealRoot]) {
        return realGroupURL;
    }
    return virtualGroupURL;
}

%end

%end


%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXObserveAppIdentityMappingChanges();
        PXAppIdentityRecord *appIdentity = PXPrepareCurrentProcessAppIdentity();
        if (!appIdentity) {
            return;
        }
        PXPreloadedAppGroupMappings = PXLoadAppGroupMappings(appIdentity);
        %init(PXAppGroupIdentityHooks);
    }
}
