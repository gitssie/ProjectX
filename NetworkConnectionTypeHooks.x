#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import "AppIdentityHookSupport.h"
#import "ProjectXLogging.h"
#import "PXProcessHookPolicy.h"
#import <objc/runtime.h>
#import <ellekit/ellekit.h>
#import <netinet/in.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import "NetworkIdentity.h"
#import "NetworkRuntimeCoverage.h"
#import "VPNDetectionBypass.h"

#pragma mark - Helper Functions

static NSDictionary *getNetworkIdentityFromProfile() {
    return PXPrepareCurrentProcessNetworkIdentity();
}

static NSString *getCurrentISOCountryCode() {
    return getNetworkIdentityFromProfile()[@"isoCountryCode"];
}

static BOOL shouldSpoofNetworkIdentity() {
    return getNetworkIdentityFromProfile() != nil;
}

static BOOL shouldSpoofConnectionType() {
    return shouldSpoofNetworkIdentity();
}

static BOOL shouldShowAsWiFi() {
    return [getNetworkIdentityFromProfile()[@"transport"] isEqualToString:@"wifi"];
}

static BOOL shouldShowAsCellular() {
    return [getNetworkIdentityFromProfile()[@"transport"] isEqualToString:@"cellular"];
}

// Get carrier details from the current profile
static NSDictionary *getCarrierDetailsFromProfile() {
    NSDictionary *identity = getNetworkIdentityFromProfile();
    if (![identity[@"carrierName"] isKindOfClass:[NSString class]] ||
        ![identity[@"mcc"] isKindOfClass:[NSString class]] ||
        ![identity[@"mnc"] isKindOfClass:[NSString class]]) {
        return nil;
    }

    return @{
        @"carrierName": identity[@"carrierName"],
        @"mobileCountryCode": identity[@"mcc"],
        @"mobileNetworkCode": identity[@"mnc"],
        @"isoCountryCode": identity[@"isoCountryCode"] ?: @"",
        @"allowsVOIP": identity[@"allowsVOIP"] ?: @YES,
        @"serviceIdentifier": identity[@"serviceIdentifier"] ?: @"",
        @"radioTechnology": identity[@"radioTechnology"] ?: @""
    };
}

static int __attribute__((unused)) getWiFiSignalStrength() {
    return [getNetworkIdentityFromProfile()[@"wifiSignalStrength"] intValue];
}

static int getCellularSignalBars() {
    return [getNetworkIdentityFromProfile()[@"cellularSignalBars"] intValue];
}

static NSString *getCurrentCellularNetworkType() {
    NSString *radioTechnology = getNetworkIdentityFromProfile()[@"radioTechnology"];
    return [radioTechnology isKindOfClass:NSString.class] && radioTechnology.length > 0
        ? radioTechnology
        : nil;
}

#pragma mark - SCNetworkReachability Hooks

// Hook SCNetworkReachabilityGetFlags to modify network type
static Boolean (*original_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags);

Boolean hooked_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean result = original_SCNetworkReachabilityGetFlags(target, flags);
    if (!result || !flags) {
        return result;
    }
    @try {
        BOOL shouldApply = shouldSpoofConnectionType();
        PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryReachability, shouldApply);
        if (!shouldApply) {
            return result;
        }
        if (shouldShowAsWiFi()) {
            *flags |= kSCNetworkReachabilityFlagsReachable;
            *flags &= ~kSCNetworkReachabilityFlagsIsWWAN;
        } else if (shouldShowAsCellular()) {
            *flags |= kSCNetworkReachabilityFlagsReachable;
            *flags |= kSCNetworkReachabilityFlagsIsWWAN;
        } else {
            *flags &= ~kSCNetworkReachabilityFlagsReachable;
            *flags &= ~kSCNetworkReachabilityFlagsIsWWAN;
        }
    } @catch (NSException *exception) {
        PXLog(@"[NetworkHook] Failed to apply generated reachability identity: %@", exception);
    }
    return result;
}

#pragma mark - CoreTelephony Hooks

static CTCarrier *createSyntheticCarrier() {
    Class carrierClass = NSClassFromString(@"CTCarrier");
    return carrierClass ? [[carrierClass alloc] init] : nil;
}

// Hook for CTTelephonyNetworkInfo
%hook CTTelephonyNetworkInfo

- (NSDictionary<NSString *, CTCarrier *> *)serviceSubscriberCellularProviders {
    NSDictionary<NSString *, CTCarrier *> *original = %orig;
    NSDictionary *identity = getNetworkIdentityFromProfile();
    BOOL shouldApply = shouldSpoofNetworkIdentity() && getCarrierDetailsFromProfile() != nil;
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }

    NSArray<NSString *> *serviceIdentifiers = PXResolvedServiceIdentifiers(
        original.allKeys,
        identity[@"serviceIdentifier"]
    );
    NSMutableDictionary<NSString *, CTCarrier *> *providers = [NSMutableDictionary dictionary];
    for (NSString *serviceIdentifier in serviceIdentifiers) {
        CTCarrier *carrier = original[serviceIdentifier];
        if (!carrier) {
            carrier = createSyntheticCarrier();
        }
        if (carrier) {
            providers[serviceIdentifier] = carrier;
        }
    }
    return [providers copy];
}

- (CTCarrier *)subscriberCellularProvider {
    CTCarrier *original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity() && getCarrierDetailsFromProfile() != nil;
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return original ?: createSyntheticCarrier();
}

- (CTCarrier *)subscriberCellularProviderForIdentifier:(NSString *)identifier {
    CTCarrier *original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity() && identifier.length > 0 &&
        getCarrierDetailsFromProfile() != nil;
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return original ?: createSyntheticCarrier();
}

- (NSString *)currentRadioAccessTechnology {
    NSString *original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryRadioTechnology, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return getCurrentCellularNetworkType() ?: original;
}

- (NSDictionary<NSString *, NSString *> *)serviceCurrentRadioAccessTechnology {
    NSDictionary<NSString *, NSString *> *original = %orig;
    NSString *radioTechnology = getCurrentCellularNetworkType();
    NSDictionary *identity = getNetworkIdentityFromProfile();
    BOOL shouldApply = shouldSpoofNetworkIdentity() && radioTechnology.length > 0;
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryRadioTechnology, shouldApply);
    if (!shouldApply) {
        return original;
    }

    NSArray<NSString *> *candidateIdentifiers = original.allKeys;
    if (candidateIdentifiers.count == 0) {
        candidateIdentifiers = [self serviceSubscriberCellularProviders].allKeys;
    }
    NSArray<NSString *> *serviceIdentifiers = PXResolvedServiceIdentifiers(
        candidateIdentifiers,
        identity[@"serviceIdentifier"]
    );
    return PXValuesByServiceIdentifier(serviceIdentifiers, radioTechnology);
}

- (NSString *)dataServiceIdentifier {
    NSString *original = %orig;
    if (!shouldSpoofNetworkIdentity()) {
        return original;
    }

    NSDictionary *identity = getNetworkIdentityFromProfile();
    NSArray<NSString *> *serviceIdentifiers = PXResolvedServiceIdentifiers(
        [self serviceSubscriberCellularProviders].allKeys,
        identity[@"serviceIdentifier"]
    );
    if ([serviceIdentifiers containsObject:original]) {
        return original;
    }
    return serviceIdentifiers.firstObject;
}

%end

// Hook for CTCarrier
%hook CTCarrier

- (NSString *)carrierName {
    NSString *original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return getCarrierDetailsFromProfile()[@"carrierName"] ?: original;
}

- (NSString *)mobileCountryCode {
    NSString *original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return getCarrierDetailsFromProfile()[@"mobileCountryCode"] ?: original;
}

- (NSString *)mobileNetworkCode {
    NSString *original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return getCarrierDetailsFromProfile()[@"mobileNetworkCode"] ?: original;
}

- (NSString *)isoCountryCode {
    NSString *original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return getCurrentISOCountryCode() ?: original;
}

- (BOOL)allowsVOIP {
    BOOL original = %orig;
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryCarrier, shouldApply);
    if (!shouldApply) {
        return original;
    }
    NSNumber *allowsVOIP = getCarrierDetailsFromProfile()[@"allowsVOIP"];
    return allowsVOIP ? allowsVOIP.boolValue : original;
}

%end

#pragma mark - NSURLSession and CFNetwork Hooks

// Hook for cellular detection in NSURLSession
%hook NSURLSessionConfiguration

- (BOOL)allowsCellularAccess {
    if (shouldShowAsWiFi()) {
        return %orig;
    }
    
    return %orig;
}

- (BOOL)isDiscretionary {
    if (!shouldSpoofConnectionType() || shouldShowAsWiFi()) {
        return %orig;
    }
    return NO;
}

%end

#pragma mark - getifaddrs Hook for Local IP Address

// Enable getifaddrs hook for local IP spoofing
static int (*original_getifaddrs)(struct ifaddrs **);

static BOOL PXNetworkInterfacePolicyForIdentity(NSDictionary<NSString *, id> *identity,
                                                PXNetworkInterfacePolicy *policy) {
    if (!identity || !policy) {
        return NO;
    }
    memset(policy, 0, sizeof(*policy));
    NSString *transport = identity[@"transport"];
    if ([transport isEqualToString:@"wifi"]) {
        policy->transport = PXNetworkInterfaceTransportWiFi;
    } else if ([transport isEqualToString:@"cellular"]) {
        policy->transport = PXNetworkInterfaceTransportCellular;
    } else if ([transport isEqualToString:@"none"]) {
        policy->transport = PXNetworkInterfaceTransportOffline;
        return YES;
    } else {
        return NO;
    }
    policy->hasIPv4Address = inet_pton(AF_INET,
        [identity[@"localIPAddress"] UTF8String], &policy->ipv4Address) == 1;
    policy->hasIPv6Address = inet_pton(AF_INET6,
        [identity[@"localIPv6Address"] UTF8String], &policy->ipv6Address) == 1;
    return policy->hasIPv4Address && policy->hasIPv6Address;
}

static int hooked_getifaddrs(struct ifaddrs **ifap) {
    int result = original_getifaddrs(ifap);
    NSDictionary<NSString *, id> *identity = result == 0 && ifap && *ifap
        ? getNetworkIdentityFromProfile()
        : nil;
    PXNetworkInterfacePolicy policy = {0};
    BOOL applied = NO;
    if (identity && PXNetworkInterfacePolicyForIdentity(identity, &policy)) {
        policy.hideTunnelInterfaces = PXVPNDetectionBypassShouldApply();
        applied = PXVPNDetectionApplyInterfacePolicy(ifap, &policy);
    }
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryInterfaces, applied);
    return result;
}

#pragma mark - Network.framework Hooks (iOS 12+)

// Attempt to hook NWPathMonitor for newer iOS versions
%group NetworkFrameworkHooks

%hook NWPath

- (BOOL)isExpensive {
    BOOL original = %orig;
    BOOL shouldApply = shouldSpoofConnectionType();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryNetworkFramework, shouldApply);
    if (!shouldApply) {
        return original;
    }
    return shouldShowAsCellular();
}

- (BOOL)usesInterfaceType:(NSInteger)type {
    BOOL shouldApply = shouldSpoofConnectionType();
    BOOL hideVPN = PXVPNDetectionBypassShouldApply();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryNetworkFramework,
                                   shouldApply || hideVPN);
    if (hideVPN && PXVPNDetectionShouldHidePathInterfaceType(type)) {
        return NO;
    }
    if (!shouldApply) {
        return %orig;
    }

    if (shouldShowAsWiFi()) {
        // Interface type 1 is typically WiFi
        if (type == 1) {
            return YES;
        }
        // Interface type 2 is typically cellular
        else if (type == 2) {
            return NO;
        }
    }
    // For cellular mode
    else {
        // Interface type 1 is typically WiFi
        if (type == 1) {
            return NO;
        }
        // Interface type 2 is typically cellular
        else if (type == 2) {
            return YES;
        }
    }
    
    return %orig;
}

%end

%end

static CFArrayRef (*original_CNCopySupportedInterfaces)(void);

static CFArrayRef hooked_CNCopySupportedInterfaces(void) {
    CFArrayRef originalInterfaces = original_CNCopySupportedInterfaces();
    BOOL shouldApply = originalInterfaces && shouldSpoofConnectionType();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryWiFiInformation, shouldApply);
    if (!shouldApply || shouldShowAsWiFi()) {
        return originalInterfaces;
    }
    CFRelease(originalInterfaces);
    return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

// Add hooks for CoreTelephony signal strength
%hook CTServiceDescriptor

- (NSString *)signalStrengthBars {
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryRadioTechnology, shouldApply);
    if (!shouldApply) {
        return %orig;
    }
    
    int bars = getCellularSignalBars();
    NSString *barsString = [NSString stringWithFormat:@"%d", bars];
    return barsString;
}

%end

%hook UIStatusBarSignalStrengthItemView

- (void)setCellularSignalStrengthBars:(int)bars {
    BOOL shouldApply = shouldSpoofNetworkIdentity();
    PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategoryRadioTechnology, shouldApply);
    if (!shouldApply) {
        %orig;
        return;
    }
    
    int spoofedBars = getCellularSignalBars();
    %orig(spoofedBars);
}

%end

#pragma mark - Initialization

%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXLog(@"[NetworkHook] Initializing network connection type hooks");
        %init;
            
            // Initialize Network.framework hooks if available
            Class NWPathClass = NSClassFromString(@"NWPath");
            if (NWPathClass) {
                %init(NetworkFrameworkHooks);
                PXLog(@"[NetworkHook] Successfully initialized Network.framework hooks");
            }
            
            // Setup the SCNetworkReachabilityGetFlags hook
            void *SCNetworkReachabilityGetFlagsPtr = dlsym(RTLD_DEFAULT, "SCNetworkReachabilityGetFlags");
            if (SCNetworkReachabilityGetFlagsPtr) {
                // Use ElleKit for hooking (preferred for iOS 15+)
                EKHook(SCNetworkReachabilityGetFlagsPtr, 
                       (void *)hooked_SCNetworkReachabilityGetFlags, 
                       (void **)&original_SCNetworkReachabilityGetFlags);
                PXLog(@"[NetworkHook] Successfully hooked SCNetworkReachabilityGetFlags");
            } else {
                PXLog(@"[NetworkHook] ERROR: Could not find SCNetworkReachabilityGetFlags function!");
            }
            
            // Enable getifaddrs hook for local IP spoofing
            void *getifaddrsPtr = dlsym(RTLD_DEFAULT, "getifaddrs");
            if (getifaddrsPtr) {
                EKHook(getifaddrsPtr, (void *)hooked_getifaddrs, (void **)&original_getifaddrs);
                PXLog(@"[NetworkHook] Successfully hooked getifaddrs for local IP spoofing");
            } else {
                PXLog(@"[NetworkHook] ERROR: Could not find getifaddrs function!");
            }
            
            void *CNCopySupportedInterfacesPtr = dlsym(RTLD_DEFAULT, "CNCopySupportedInterfaces");
            if (CNCopySupportedInterfacesPtr) {
                EKHook(CNCopySupportedInterfacesPtr,
                       (void *)hooked_CNCopySupportedInterfaces,
                       (void **)&original_CNCopySupportedInterfaces);
                PXLog(@"[NetworkHook] Successfully hooked CNCopySupportedInterfaces");
            } else {
                PXLog(@"[NetworkHook] ERROR: Could not find CNCopySupportedInterfaces function!");
            }

            // CNCopyCurrentNetworkInfo has one owner in WiFiHook.x. Keeping a
            // single replacement avoids nested retained dictionaries and
            // preserves the CoreFoundation create/copy ownership contract.
    }
}
