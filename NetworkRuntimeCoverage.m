#import "NetworkRuntimeCoverage.h"

#import "ProjectXLogging.h"

#import <Foundation/Foundation.h>
#import <os/lock.h>

static os_unfair_lock PXNetworkCoverageLock = OS_UNFAIR_LOCK_INIT;
static PXNetworkCoverageState PXNetworkCoverageProcessState = {0};

bool PXNetworkCoverageStateRecord(PXNetworkCoverageState *state,
                                  PXNetworkCoverageCategory category,
                                  bool applied) {
    if (!state || category < 0 || category >= PXNetworkCoverageCategoryCount) {
        return false;
    }
    uint64_t categoryBit = UINT64_C(1) << (uint64_t)category;
    uint64_t *recordedCategories = applied
        ? &state->appliedCategories
        : &state->invokedCategories;
    bool firstRecord = (*recordedCategories & categoryBit) == 0;
    state->invokedCategories |= categoryBit;
    if (applied) {
        state->appliedCategories |= categoryBit;
    }
    return firstRecord;
}

void PXNetworkCoverageStateReset(PXNetworkCoverageState *state) {
    if (state) {
        state->invokedCategories = 0;
        state->appliedCategories = 0;
    }
}

static void PXNetworkCoverageChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    os_unfair_lock_lock(&PXNetworkCoverageLock);
    PXNetworkCoverageStateReset(&PXNetworkCoverageProcessState);
    os_unfair_lock_unlock(&PXNetworkCoverageLock);
}

static void PXObserveNetworkCoverageChanges(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *names = @[
            @"com.hydra.projectx.profileChanged",
            @"com.hydra.projectx.profileGenerationChanged",
            @"com.hydra.projectx.scopedAppsChanged",
            @"com.hydra.projectx.networkConnectionTypeChanged",
            @"com.hydra.projectx.carrierDetailsChanged",
            @"com.hydra.projectx.vpnDetectionBypassChanged"
        ];
        for (NSString *name in names) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL,
                                            PXNetworkCoverageChanged,
                                            (__bridge CFStringRef)name,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    });
}

static NSString *PXNetworkCoverageCategoryName(PXNetworkCoverageCategory category) {
    switch (category) {
        case PXNetworkCoverageCategoryReachability:
            return @"reachability";
        case PXNetworkCoverageCategoryCarrier:
            return @"carrier";
        case PXNetworkCoverageCategoryRadioTechnology:
            return @"radio-technology";
        case PXNetworkCoverageCategoryInterfaces:
            return @"interfaces";
        case PXNetworkCoverageCategoryNetworkFramework:
            return @"network-framework";
        case PXNetworkCoverageCategoryWiFiInformation:
            return @"wifi-information";
        case PXNetworkCoverageCategoryProxyCFNetwork:
            return @"proxy-cfnetwork";
        case PXNetworkCoverageCategoryProxySystemConfiguration:
            return @"proxy-system-configuration";
        case PXNetworkCoverageCategoryProxyURLSession:
            return @"proxy-url-session";
        case PXNetworkCoverageCategoryVPNStatus:
            return @"vpn-status";
        case PXNetworkCoverageCategoryCount:
            return @"invalid";
    }
    return @"invalid";
}

void PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategory category, bool applied) {
    if (category < 0 || category >= PXNetworkCoverageCategoryCount) {
        return;
    }
    PXObserveNetworkCoverageChanges();
    os_unfair_lock_lock(&PXNetworkCoverageLock);
    bool shouldLog = PXNetworkCoverageStateRecord(
        &PXNetworkCoverageProcessState,
        category,
        applied);
    os_unfair_lock_unlock(&PXNetworkCoverageLock);
    if (shouldLog) {
        PXLog(@"[NetworkCoverage] category=%@ disposition=%@",
              PXNetworkCoverageCategoryName(category),
              applied ? @"applied" : @"original");
    }
}
