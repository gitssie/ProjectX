#include "NetworkInterfacePolicy.h"

#include <assert.h>
#include <net/if.h>
#include <stdlib.h>
#include <string.h>

static struct sockaddr_in ipv4Address(const char *value) {
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    assert(inet_pton(AF_INET, value, &address.sin_addr) == 1);
    return address;
}

static struct ifaddrs interfaceNode(char *name,
                                    struct sockaddr_in *address,
                                    struct sockaddr_in *netmask,
                                    struct ifaddrs *next) {
    struct ifaddrs interface;
    memset(&interface, 0, sizeof(interface));
    interface.ifa_next = next;
    interface.ifa_name = name;
    interface.ifa_flags = IFF_UP | IFF_RUNNING;
    interface.ifa_addr = (struct sockaddr *)address;
    interface.ifa_netmask = (struct sockaddr *)netmask;
    return interface;
}

static const struct ifaddrs *interfaceNamed(const struct ifaddrs *interfaces,
                                            const char *name,
                                            sa_family_t family) {
    for (const struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
        if (interface->ifa_name && strcmp(interface->ifa_name, name) == 0 &&
            interface->ifa_addr && interface->ifa_addr->sa_family == family) {
            return interface;
        }
    }
    return NULL;
}

static void testCellularViewUsesProfileAddressesAndRemovesWiFiAndTunnels(void) {
    struct sockaddr_in loopbackAddress = ipv4Address("127.0.0.1");
    struct sockaddr_in loopbackMask = ipv4Address("255.0.0.0");
    struct sockaddr_in wifiAddress = ipv4Address("192.168.1.25");
    struct sockaddr_in wifiMask = ipv4Address("255.255.255.0");
    struct sockaddr_in tunnelAddress = ipv4Address("10.8.0.2");
    struct sockaddr_in tunnelMask = ipv4Address("255.255.255.255");
    struct sockaddr_in zeroAddress = ipv4Address("0.0.0.0");
    struct sockaddr_in cellularMask = ipv4Address("255.255.255.255");

    struct ifaddrs cellular = interfaceNode("pdp_ip0", &zeroAddress, &cellularMask, NULL);
    struct ifaddrs tunnel = interfaceNode("utun2", &tunnelAddress, &tunnelMask, &cellular);
    struct ifaddrs wifi = interfaceNode("en0", &wifiAddress, &wifiMask, &tunnel);
    struct ifaddrs loopback = interfaceNode("lo0", &loopbackAddress, &loopbackMask, &wifi);

    PXNetworkInterfacePolicy policy;
    memset(&policy, 0, sizeof(policy));
    policy.transport = PXNetworkInterfaceTransportCellular;
    policy.hideTunnelInterfaces = true;
    policy.hasIPv4Address = inet_pton(AF_INET, "10.23.45.67", &policy.ipv4Address) == 1;
    policy.hasIPv6Address = inet_pton(AF_INET6, "fe80::1234:5678", &policy.ipv6Address) == 1;

    struct ifaddrs *view = NULL;
    assert(PXNetworkInterfacePolicyCreateView(&loopback, &policy, &view));
    assert(view != NULL);
    assert(interfaceNamed(view, "lo0", AF_INET) != NULL);
    assert(interfaceNamed(view, "en0", AF_INET) == NULL);
    assert(interfaceNamed(view, "utun2", AF_INET) == NULL);

    const struct ifaddrs *cellularIPv4 = interfaceNamed(view, "pdp_ip0", AF_INET);
    const struct ifaddrs *cellularIPv6 = interfaceNamed(view, "pdp_ip0", AF_INET6);
    assert(cellularIPv4 != NULL);
    assert(cellularIPv6 != NULL);
    assert(cellularIPv4->ifa_netmask != NULL);
    assert((cellularIPv4->ifa_flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING));
    assert(((const struct sockaddr_in *)cellularIPv4->ifa_addr)->sin_addr.s_addr ==
           policy.ipv4Address.s_addr);
    assert(memcmp(&((const struct sockaddr_in6 *)cellularIPv6->ifa_addr)->sin6_addr,
                  &policy.ipv6Address,
                  sizeof(policy.ipv6Address)) == 0);

    assert(strcmp(loopback.ifa_name, "lo0") == 0);
    assert(((struct sockaddr_in *)cellular.ifa_addr)->sin_addr.s_addr == INADDR_ANY);
    PXNetworkInterfacePolicyFreeView(view);
}

static void testTunnelOnlyPolicyPreservesOrdinaryInterfaces(void) {
    struct sockaddr_in wifiAddress = ipv4Address("192.168.1.25");
    struct sockaddr_in wifiMask = ipv4Address("255.255.255.0");
    struct sockaddr_in tunnelAddress = ipv4Address("10.8.0.2");
    struct sockaddr_in tunnelMask = ipv4Address("255.255.255.255");
    struct ifaddrs tunnel = interfaceNode("ipsec0", &tunnelAddress, &tunnelMask, NULL);
    struct ifaddrs wifi = interfaceNode("en0", &wifiAddress, &wifiMask, &tunnel);
    PXNetworkInterfacePolicy policy;
    memset(&policy, 0, sizeof(policy));
    policy.transport = PXNetworkInterfaceTransportOriginal;
    policy.hideTunnelInterfaces = true;

    struct ifaddrs *view = NULL;
    assert(PXNetworkInterfacePolicyCreateView(&wifi, &policy, &view));
    assert(interfaceNamed(view, "en0", AF_INET) != NULL);
    assert(interfaceNamed(view, "ipsec0", AF_INET) == NULL);
    PXNetworkInterfacePolicyFreeView(view);
}

static void testDisabledVPNFilteringPreservesTunnelEvidence(void) {
    struct sockaddr_in tunnelAddress = ipv4Address("10.8.0.2");
    struct sockaddr_in tunnelMask = ipv4Address("255.255.255.255");
    struct ifaddrs tunnel = interfaceNode("utun2", &tunnelAddress, &tunnelMask, NULL);
    PXNetworkInterfacePolicy policy;
    memset(&policy, 0, sizeof(policy));
    policy.transport = PXNetworkInterfaceTransportOriginal;
    policy.hideTunnelInterfaces = false;

    struct ifaddrs *view = NULL;
    assert(PXNetworkInterfacePolicyCreateView(&tunnel, &policy, &view));
    assert(interfaceNamed(view, "utun2", AF_INET) != NULL);
    PXNetworkInterfacePolicyFreeView(view);
}

int main(void) {
    testCellularViewUsesProfileAddressesAndRemovesWiFiAndTunnels();
    testTunnelOnlyPolicyPreservesOrdinaryInterfaces();
    testDisabledVPNFilteringPreservesTunnelEvidence();
    return 0;
}
