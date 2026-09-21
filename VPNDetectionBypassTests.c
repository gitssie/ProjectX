#include "VPNDetectionBypass.h"

#include <assert.h>

static void testTunnelInterfaceClassification(void) {
    assert(PXVPNDetectionIsTunnelInterfaceName("utun0"));
    assert(PXVPNDetectionIsTunnelInterfaceName("tun12"));
    assert(PXVPNDetectionIsTunnelInterfaceName("tap1"));
    assert(PXVPNDetectionIsTunnelInterfaceName("ppp0"));
    assert(PXVPNDetectionIsTunnelInterfaceName("ipsec4"));

    assert(!PXVPNDetectionIsTunnelInterfaceName("en0"));
    assert(!PXVPNDetectionIsTunnelInterfaceName("pdp_ip0"));
    assert(!PXVPNDetectionIsTunnelInterfaceName("lo0"));
    assert(!PXVPNDetectionIsTunnelInterfaceName(""));
    assert(!PXVPNDetectionIsTunnelInterfaceName(NULL));
}

static void testProxyKeyClassification(void) {
    assert(PXVPNDetectionProxyKeyDisposition("HTTPEnable") == PXVPNProxyKeyDispositionRemove);
    assert(PXVPNDetectionProxyKeyDisposition("HTTPSProxy") == PXVPNProxyKeyDispositionRemove);
    assert(PXVPNDetectionProxyKeyDisposition("SOCKSPort") == PXVPNProxyKeyDispositionRemove);
    assert(PXVPNDetectionProxyKeyDisposition("ProxyAutoConfigURLString") == PXVPNProxyKeyDispositionRemove);
    assert(PXVPNDetectionProxyKeyDisposition("ProxyAutoDiscoveryEnable") == PXVPNProxyKeyDispositionRemove);
    assert(PXVPNDetectionProxyKeyDisposition("__SCOPED__") == PXVPNProxyKeyDispositionSanitizeContainer);
    assert(PXVPNDetectionProxyKeyDisposition("__MATCHES__") == PXVPNProxyKeyDispositionSanitizeContainer);

    assert(PXVPNDetectionProxyKeyDisposition("ExceptionsList") == PXVPNProxyKeyDispositionPreserve);
    assert(PXVPNDetectionProxyKeyDisposition("ExcludeSimpleHostnames") == PXVPNProxyKeyDispositionPreserve);
    assert(PXVPNDetectionProxyKeyDisposition(NULL) == PXVPNProxyKeyDispositionPreserve);
}

static void testNetworkPathClassification(void) {
    assert(PXVPNDetectionShouldHidePathInterfaceType(0));
    assert(!PXVPNDetectionShouldHidePathInterfaceType(1));
    assert(!PXVPNDetectionShouldHidePathInterfaceType(2));
    assert(!PXVPNDetectionShouldHidePathInterfaceType(3));
}

static void testGateRequiresPreferenceAndSelectedTarget(void) {
    PXVPNDetectionGateCache cache = { true, false, true, true };
    assert(PXVPNDetectionGateStateForCache(&cache) == PXVPNDetectionGateStatePreferenceDisabled);

    cache.preferenceEnabled = true;
    cache.scopeEnabled = false;
    assert(PXVPNDetectionGateStateForCache(&cache) == PXVPNDetectionGateStateTargetUnselected);

    cache.scopeEnabled = true;
    assert(PXVPNDetectionGateStateForCache(&cache) == PXVPNDetectionGateStateReady);
}

static void testGateRequiresProfileBackedNetworkIdentity(void) {
    PXVPNDetectionGateCache cache = { true, true, true, true };
    assert(!PXVPNDetectionShouldApplyForCacheAndNetworkIdentity(&cache, false));
    assert(PXVPNDetectionShouldApplyForCacheAndNetworkIdentity(&cache, true));
}

static void testScopeNotificationInvalidatesStaleGateState(void) {
    PXVPNDetectionGateCache cache = { true, true, true, true };
    assert(PXVPNDetectionGateStateForCache(&cache) == PXVPNDetectionGateStateReady);

    PXVPNDetectionInvalidateScopeCache(&cache);
    assert(!cache.scopeValid);
    assert(PXVPNDetectionGateStateForCache(&cache) == PXVPNDetectionGateStateUnknown);

    cache.scopeEnabled = false;
    cache.scopeValid = true;
    assert(PXVPNDetectionGateStateForCache(&cache) == PXVPNDetectionGateStateTargetUnselected);
}

static void testElleKitHookSymbolSelectsReachableFunctionHookBackend(void) {
    assert(PXVPNDetectionHookBackendForAvailability(true, false) ==
           PXVPNDetectionHookBackendElleKit);
    assert(PXVPNDetectionHookBackendForAvailability(false, true) ==
           PXVPNDetectionHookBackendSubstrate);
    assert(PXVPNDetectionHookBackendForAvailability(false, false) ==
           PXVPNDetectionHookBackendUnavailable);
}

int main(void) {
    testTunnelInterfaceClassification();
    testProxyKeyClassification();
    testNetworkPathClassification();
    testGateRequiresPreferenceAndSelectedTarget();
    testGateRequiresProfileBackedNetworkIdentity();
    testScopeNotificationInvalidatesStaleGateState();
    testElleKitHookSymbolSelectsReachableFunctionHookBackend();
    return 0;
}
