#ifndef PROJECTX_NETWORK_INTERFACE_POLICY_H
#define PROJECTX_NETWORK_INTERFACE_POLICY_H

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <stdbool.h>

typedef enum {
    PXNetworkInterfaceTransportOriginal = 0,
    PXNetworkInterfaceTransportWiFi,
    PXNetworkInterfaceTransportCellular,
    PXNetworkInterfaceTransportOffline
} PXNetworkInterfaceTransport;

typedef struct {
    PXNetworkInterfaceTransport transport;
    bool hideTunnelInterfaces;
    bool hasIPv4Address;
    bool hasIPv6Address;
    struct in_addr ipv4Address;
    struct in6_addr ipv6Address;
} PXNetworkInterfacePolicy;

bool PXNetworkInterfacePolicyCreateView(const struct ifaddrs *originalInterfaces,
                                        const PXNetworkInterfacePolicy *policy,
                                        struct ifaddrs **viewInterfaces);
void PXNetworkInterfacePolicyFreeView(struct ifaddrs *viewInterfaces);

#endif
