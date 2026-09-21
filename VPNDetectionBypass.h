#ifndef VPN_DETECTION_BYPASS_H
#define VPN_DETECTION_BYPASS_H

#include <ifaddrs.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "NetworkInterfacePolicy.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PXVPNProxyKeyDispositionPreserve = 0,
    PXVPNProxyKeyDispositionRemove,
    PXVPNProxyKeyDispositionSanitizeContainer
} PXVPNProxyKeyDisposition;

typedef enum {
    PXVPNDetectionGateStateUnknown = 0,
    PXVPNDetectionGateStatePreferenceDisabled,
    PXVPNDetectionGateStateTargetUnselected,
    PXVPNDetectionGateStateReady
} PXVPNDetectionGateState;

typedef struct {
    bool preferenceValid;
    bool preferenceEnabled;
    bool scopeValid;
    bool scopeEnabled;
} PXVPNDetectionGateCache;

typedef enum {
    PXVPNDetectionHookBackendUnavailable = 0,
    PXVPNDetectionHookBackendElleKit,
    PXVPNDetectionHookBackendSubstrate
} PXVPNDetectionHookBackend;

static inline void PXVPNDetectionInvalidateScopeCache(PXVPNDetectionGateCache *cache) {
    if (cache) {
        cache->scopeValid = false;
    }
}

static inline PXVPNDetectionGateState PXVPNDetectionGateStateForCache(
    const PXVPNDetectionGateCache *cache
) {
    if (!cache || !cache->preferenceValid || !cache->scopeValid) {
        return PXVPNDetectionGateStateUnknown;
    }
    if (!cache->preferenceEnabled) {
        return PXVPNDetectionGateStatePreferenceDisabled;
    }
    if (!cache->scopeEnabled) {
        return PXVPNDetectionGateStateTargetUnselected;
    }
    return PXVPNDetectionGateStateReady;
}

static inline bool PXVPNDetectionShouldApplyForCacheAndNetworkIdentity(
    const PXVPNDetectionGateCache *cache,
    bool networkIdentityAvailable
) {
    return cache && cache->preferenceValid && cache->preferenceEnabled &&
           networkIdentityAvailable;
}

static inline PXVPNDetectionHookBackend PXVPNDetectionHookBackendForAvailability(
    bool elleKitHookAvailable,
    bool substrateHookAvailable
) {
    if (elleKitHookAvailable) {
        return PXVPNDetectionHookBackendElleKit;
    }
    if (substrateHookAvailable) {
        return PXVPNDetectionHookBackendSubstrate;
    }
    return PXVPNDetectionHookBackendUnavailable;
}

static inline bool PXVPNDetectionIsTunnelInterfaceName(const char *name) {
    if (!name) {
        return false;
    }

    return strncmp(name, "utun", 4) == 0 ||
           strncmp(name, "tun", 3) == 0 ||
           strncmp(name, "tap", 3) == 0 ||
           strncmp(name, "ppp", 3) == 0 ||
           strncmp(name, "ipsec", 5) == 0;
}

static inline PXVPNProxyKeyDisposition PXVPNDetectionProxyKeyDisposition(const char *key) {
    if (!key) {
        return PXVPNProxyKeyDispositionPreserve;
    }

    static const char *const removableKeys[] = {
        "HTTPEnable",
        "HTTPProxy",
        "HTTPPort",
        "HTTPSEnable",
        "HTTPSProxy",
        "HTTPSPort",
        "SOCKSEnable",
        "SOCKSProxy",
        "SOCKSPort",
        "ProxyAutoConfigEnable",
        "ProxyAutoConfigURLString",
        "ProxyAutoConfigJavaScript",
        "ProxyAutoDiscoveryEnable"
    };

    for (size_t index = 0; index < sizeof(removableKeys) / sizeof(removableKeys[0]); index++) {
        if (strcmp(key, removableKeys[index]) == 0) {
            return PXVPNProxyKeyDispositionRemove;
        }
    }

    if (strcmp(key, "__SCOPED__") == 0 || strcmp(key, "__MATCHES__") == 0) {
        return PXVPNProxyKeyDispositionSanitizeContainer;
    }

    return PXVPNProxyKeyDispositionPreserve;
}

static inline bool PXVPNDetectionShouldHidePathInterfaceType(long interfaceType) {
    return interfaceType == 0;
}

bool PXVPNDetectionBypassShouldApply(void);
void PXVPNDetectionSanitizeInterfaces(struct ifaddrs **interfaces);
bool PXVPNDetectionApplyInterfacePolicy(struct ifaddrs **interfaces,
                                        const PXNetworkInterfacePolicy *policy);

#ifdef __cplusplus
}
#endif

#endif
