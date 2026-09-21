#import "VPNDetectionBypass.h"
#import "AppIdentityHookSupport.h"
#import "NetworkRuntimeCoverage.h"
#import "ProjectXLogging.h"
#import "PXProcessHookPolicy.h"

#import <CFNetwork/CFNetwork.h>
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dlfcn.h>
#import <ellekit/ellekit.h>
#import <os/lock.h>

#include <stdlib.h>
#include <string.h>

static NSString *const PXVPNSecuritySettingsSuite = @"com.weaponx.securitySettings";
static NSString *const PXVPNPreferenceKey = @"vpnDetectionBypassEnabled";
static NSString *const PXVPNPreferenceNotification = @"com.hydra.projectx.vpnDetectionBypassChanged";
static NSString *const PXVPNScopedAppsNotification = @"com.hydra.projectx.scopedAppsChanged";

static os_unfair_lock PXVPNGateLock = OS_UNFAIR_LOCK_INIT;
static PXVPNDetectionGateCache PXVPNGateCache = { false, false, false, false };
static PXVPNDetectionGateState PXVPNLastLoggedGateState = PXVPNDetectionGateStateUnknown;

typedef struct PXVPNInterfaceAllocation {
    struct ifaddrs *sanitizedInterfaces;
    struct ifaddrs *originalInterfaces;
    struct PXVPNInterfaceAllocation *next;
} PXVPNInterfaceAllocation;

static os_unfair_lock PXVPNInterfaceAllocationLock = OS_UNFAIR_LOCK_INIT;
static PXVPNInterfaceAllocation *PXVPNInterfaceAllocations = NULL;
static void (*PXVPNOriginalFreeIfAddrs)(struct ifaddrs *interfaces) = NULL;

static NSUserDefaults *PXVPNSettings(void) {
    static NSUserDefaults *settings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        settings = [[NSUserDefaults alloc] initWithSuiteName:PXVPNSecuritySettingsSuite];
    });
    return settings;
}

static BOOL PXVPNReadPreference(void) {
    NSUserDefaults *settings = PXVPNSettings();
    [settings synchronize];
    return [settings boolForKey:PXVPNPreferenceKey];
}

static BOOL PXVPNCachedPreferenceEnabled(void) {
    os_unfair_lock_lock(&PXVPNGateLock);
    if (!PXVPNGateCache.preferenceValid) {
        PXVPNGateCache.preferenceEnabled = PXVPNReadPreference();
        PXVPNGateCache.preferenceValid = true;
    }
    BOOL enabled = PXVPNGateCache.preferenceEnabled;
    os_unfair_lock_unlock(&PXVPNGateLock);
    return enabled;
}

bool PXVPNDetectionBypassShouldApply(void) {
    BOOL preferenceEnabled = PXVPNCachedPreferenceEnabled();
    BOOL networkIdentityAvailable = preferenceEnabled &&
        PXPrepareCurrentProcessNetworkIdentity() != nil;

    os_unfair_lock_lock(&PXVPNGateLock);
    PXVPNGateCache.scopeEnabled = networkIdentityAvailable;
    PXVPNGateCache.scopeValid = true;
    PXVPNDetectionGateState state = PXVPNDetectionGateStateForCache(&PXVPNGateCache);
    BOOL shouldApply = PXVPNDetectionShouldApplyForCacheAndNetworkIdentity(
        &PXVPNGateCache,
        networkIdentityAvailable);
    BOOL shouldLog = state != PXVPNLastLoggedGateState;
    PXVPNLastLoggedGateState = state;
    os_unfair_lock_unlock(&PXVPNGateLock);

    if (shouldLog) {
        NSString *stateName = @"unknown";
        if (state == PXVPNDetectionGateStatePreferenceDisabled) {
            stateName = @"preference-disabled";
        } else if (state == PXVPNDetectionGateStateTargetUnselected) {
            stateName = @"target-unselected";
        } else if (state == PXVPNDetectionGateStateReady) {
            stateName = @"ready";
        }
        PXLog(@"[VPNBypass] Gate state: %@", stateName);
    }

    return shouldApply;
}

static void PXVPNPreferenceChanged(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    BOOL enabled = PXVPNReadPreference();
    os_unfair_lock_lock(&PXVPNGateLock);
    PXVPNGateCache.preferenceEnabled = enabled;
    PXVPNGateCache.preferenceValid = true;
    os_unfair_lock_unlock(&PXVPNGateLock);
}

static void PXVPNScopedAppsChanged(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    os_unfair_lock_lock(&PXVPNGateLock);
    PXVPNDetectionInvalidateScopeCache(&PXVPNGateCache);
    os_unfair_lock_unlock(&PXVPNGateLock);
}

static PXVPNInterfaceAllocation *PXVPNTakeInterfaceAllocation(struct ifaddrs *interfaces) {
    PXVPNInterfaceAllocation *result = NULL;

    os_unfair_lock_lock(&PXVPNInterfaceAllocationLock);
    PXVPNInterfaceAllocation **cursor = &PXVPNInterfaceAllocations;
    while (*cursor) {
        if ((*cursor)->sanitizedInterfaces == interfaces) {
            result = *cursor;
            *cursor = result->next;
            break;
        }
        cursor = &(*cursor)->next;
    }
    os_unfair_lock_unlock(&PXVPNInterfaceAllocationLock);

    return result;
}

bool PXVPNDetectionApplyInterfacePolicy(struct ifaddrs **interfaces,
                                        const PXNetworkInterfacePolicy *policy) {
    if (!interfaces || !*interfaces || !policy || !PXVPNOriginalFreeIfAddrs) {
        return false;
    }
    struct ifaddrs *originalInterfaces = *interfaces;
    struct ifaddrs *sanitizedHead = NULL;
    if (!PXNetworkInterfacePolicyCreateView(originalInterfaces, policy, &sanitizedHead) ||
        !sanitizedHead) {
        return false;
    }

    PXVPNInterfaceAllocation *allocation = (PXVPNInterfaceAllocation *)calloc(1, sizeof(PXVPNInterfaceAllocation));
    if (!allocation) {
        PXNetworkInterfacePolicyFreeView(sanitizedHead);
        return false;
    }

    allocation->sanitizedInterfaces = sanitizedHead;
    allocation->originalInterfaces = originalInterfaces;

    os_unfair_lock_lock(&PXVPNInterfaceAllocationLock);
    allocation->next = PXVPNInterfaceAllocations;
    PXVPNInterfaceAllocations = allocation;
    os_unfair_lock_unlock(&PXVPNInterfaceAllocationLock);

    *interfaces = sanitizedHead;
    return true;
}

void PXVPNDetectionSanitizeInterfaces(struct ifaddrs **interfaces) {
    if (!interfaces || !*interfaces || !PXVPNDetectionBypassShouldApply()) {
        return;
    }

    BOOL containsTunnelInterface = NO;
    for (struct ifaddrs *interface = *interfaces; interface; interface = interface->ifa_next) {
        if (PXVPNDetectionIsTunnelInterfaceName(interface->ifa_name)) {
            containsTunnelInterface = YES;
            break;
        }
    }
    if (!containsTunnelInterface) {
        return;
    }

    PXNetworkInterfacePolicy policy = {0};
    policy.transport = PXNetworkInterfaceTransportOriginal;
    policy.hideTunnelInterfaces = true;
    (void)PXVPNDetectionApplyInterfacePolicy(interfaces, &policy);
}

static void PXVPNFreeIfAddrsHook(struct ifaddrs *interfaces) {
    if (!interfaces) {
        return;
    }

    PXVPNInterfaceAllocation *allocation = PXVPNTakeInterfaceAllocation(interfaces);
    if (!allocation) {
        PXVPNOriginalFreeIfAddrs(interfaces);
        return;
    }

    PXNetworkInterfacePolicyFreeView(allocation->sanitizedInterfaces);
    PXVPNOriginalFreeIfAddrs(allocation->originalInterfaces);
    free(allocation);
}

static BOOL PXVPNStringIsTunnelInterfaceName(NSString *value) {
    return [value isKindOfClass:[NSString class]] && PXVPNDetectionIsTunnelInterfaceName(value.UTF8String);
}

static BOOL PXVPNKeyDescribesInterface(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) {
        return NO;
    }

    NSString *lowercaseKey = key.lowercaseString;
    return [lowercaseKey containsString:@"interface"] || [lowercaseKey containsString:@"scope"];
}

static id PXVPNSanitizedProxyContainer(id value, BOOL scopedContainer);

static NSDictionary *PXVPNSanitizedProxyDictionary(NSDictionary *dictionary, BOOL scopedContainer) {
    NSMutableDictionary *sanitized = [dictionary mutableCopy];

    for (id rawKey in dictionary.allKeys) {
        if (![rawKey isKindOfClass:[NSString class]]) {
            continue;
        }

        NSString *key = rawKey;
        if (scopedContainer && PXVPNStringIsTunnelInterfaceName(key)) {
            [sanitized removeObjectForKey:key];
            continue;
        }

        PXVPNProxyKeyDisposition disposition = PXVPNDetectionProxyKeyDisposition(key.UTF8String);
        if (disposition == PXVPNProxyKeyDispositionRemove) {
            [sanitized removeObjectForKey:key];
            continue;
        }

        id originalValue = dictionary[key];
        if (PXVPNKeyDescribesInterface(key) && PXVPNStringIsTunnelInterfaceName(originalValue)) {
            [sanitized removeObjectForKey:key];
            continue;
        }

        BOOL nestedScope = scopedContainer || disposition == PXVPNProxyKeyDispositionSanitizeContainer;
        id sanitizedValue = PXVPNSanitizedProxyContainer(originalValue, nestedScope);
        if (sanitizedValue) {
            sanitized[key] = sanitizedValue;
        } else {
            [sanitized removeObjectForKey:key];
        }
    }

    return [sanitized copy];
}

static NSArray *PXVPNSanitizedProxyArray(NSArray *array, BOOL scopedContainer) {
    NSMutableArray *sanitized = [NSMutableArray arrayWithCapacity:array.count];
    for (id value in array) {
        if (scopedContainer && PXVPNStringIsTunnelInterfaceName(value)) {
            continue;
        }

        id sanitizedValue = PXVPNSanitizedProxyContainer(value, scopedContainer);
        if (sanitizedValue) {
            [sanitized addObject:sanitizedValue];
        }
    }
    return [sanitized copy];
}

static id PXVPNSanitizedProxyContainer(id value, BOOL scopedContainer) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        return PXVPNSanitizedProxyDictionary(value, scopedContainer);
    }
    if ([value isKindOfClass:[NSArray class]]) {
        return PXVPNSanitizedProxyArray(value, scopedContainer);
    }
    if (scopedContainer && PXVPNStringIsTunnelInterfaceName(value)) {
        return nil;
    }
    return value;
}

static CFDictionaryRef PXVPNCreateSanitizedProxyDictionary(CFDictionaryRef dictionary) {
    NSDictionary *original = (__bridge NSDictionary *)dictionary;
    NSDictionary *sanitized = PXVPNSanitizedProxyDictionary(original, NO);
    return (__bridge_retained CFDictionaryRef)sanitized;
}

static CFDictionaryRef (*PXVPNOriginalCFNetworkCopySystemProxySettings)(void) = NULL;
static CFDictionaryRef PXVPNHookedCFNetworkCopySystemProxySettings(void) {
    CFDictionaryRef original = PXVPNOriginalCFNetworkCopySystemProxySettings();
    BOOL shouldApply = original && PXVPNDetectionBypassShouldApply();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryProxyCFNetwork, shouldApply);
    if (!shouldApply) {
        return original;
    }
    if (CFGetTypeID(original) != CFDictionaryGetTypeID()) {
        return original;
    }

    CFDictionaryRef sanitized = PXVPNCreateSanitizedProxyDictionary(original);
    CFRelease(original);
    return sanitized;
}

static CFDictionaryRef (*PXVPNOriginalSCDynamicStoreCopyProxies)(SCDynamicStoreRef store) = NULL;
static CFDictionaryRef PXVPNHookedSCDynamicStoreCopyProxies(SCDynamicStoreRef store) {
    CFDictionaryRef original = PXVPNOriginalSCDynamicStoreCopyProxies(store);
    BOOL shouldApply = original && PXVPNDetectionBypassShouldApply();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryProxySystemConfiguration,
                                   shouldApply);
    if (!shouldApply) {
        return original;
    }
    if (CFGetTypeID(original) != CFDictionaryGetTypeID()) {
        return original;
    }

    CFDictionaryRef sanitized = PXVPNCreateSanitizedProxyDictionary(original);
    CFRelease(original);
    return sanitized;
}

%group PXVPNProxyConfigurationHooks

%hook NSURLSessionConfiguration

- (NSDictionary *)connectionProxyDictionary {
    NSDictionary *original = %orig;
    BOOL shouldApply = PXVPNDetectionBypassShouldApply();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryProxyURLSession, shouldApply);
    if (!shouldApply) {
        return original;
    }
    if (![original isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    return PXVPNSanitizedProxyDictionary(original, NO);
}

%end

%end

%group PXVPNStatusHooks

%hook NEVPNConnection

- (NEVPNStatus)status {
    NEVPNStatus original = %orig;
    BOOL shouldApply = PXVPNDetectionBypassShouldApply();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryVPNStatus, shouldApply);
    return shouldApply ? NEVPNStatusDisconnected : original;
}

%end

%end

%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXVPNPreferenceChanged(NULL, NULL, NULL, NULL, NULL);

        PXLog(@"[VPNBypass] Hook surface initialized");

        CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwinCenter,
                                        NULL,
                                        PXVPNPreferenceChanged,
                                        (__bridge CFStringRef)PXVPNPreferenceNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwinCenter,
                                        NULL,
                                        PXVPNScopedAppsChanged,
                                        (__bridge CFStringRef)PXVPNScopedAppsNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        %init(PXVPNProxyConfigurationHooks);
        if (NSClassFromString(@"NEVPNConnection")) {
            %init(PXVPNStatusHooks);
        }

        void *freeIfAddrs = dlsym(RTLD_DEFAULT, "freeifaddrs");
        if (!freeIfAddrs || EKHook(freeIfAddrs,
                                   (void *)PXVPNFreeIfAddrsHook,
                                   (void **)&PXVPNOriginalFreeIfAddrs) != 0) {
            PXLog(@"[VPNBypass] freeifaddrs hook unavailable");
        }

        void *copySystemProxySettings = dlsym(RTLD_DEFAULT, "CFNetworkCopySystemProxySettings");
        if (copySystemProxySettings) {
            if (EKHook(copySystemProxySettings,
                       (void *)PXVPNHookedCFNetworkCopySystemProxySettings,
                       (void **)&PXVPNOriginalCFNetworkCopySystemProxySettings) != 0) {
                PXLog(@"[VPNBypass] CFNetwork proxy hook unavailable");
            }
        }

        void *copyDynamicStoreProxies = dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyProxies");
        if (copyDynamicStoreProxies) {
            if (EKHook(copyDynamicStoreProxies,
                       (void *)PXVPNHookedSCDynamicStoreCopyProxies,
                       (void **)&PXVPNOriginalSCDynamicStoreCopyProxies) != 0) {
                PXLog(@"[VPNBypass] SystemConfiguration proxy hook unavailable");
            }
        }
    }
}
