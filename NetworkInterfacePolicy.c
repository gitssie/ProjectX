#include "NetworkInterfacePolicy.h"

#include <net/if.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static bool PXNetworkInterfaceNameHasPrefix(const char *name, const char *prefix) {
    return name && prefix && strncmp(name, prefix, strlen(prefix)) == 0;
}

static bool PXNetworkInterfaceIsTunnel(const char *name) {
    return PXNetworkInterfaceNameHasPrefix(name, "utun") ||
           PXNetworkInterfaceNameHasPrefix(name, "tun") ||
           PXNetworkInterfaceNameHasPrefix(name, "tap") ||
           PXNetworkInterfaceNameHasPrefix(name, "ipsec") ||
           PXNetworkInterfaceNameHasPrefix(name, "ppp");
}

static bool PXNetworkInterfaceIsLoopback(const char *name) {
    return PXNetworkInterfaceNameHasPrefix(name, "lo");
}

static bool PXNetworkInterfaceIsWiFi(const char *name) {
    return (name && strcmp(name, "en0") == 0) ||
           PXNetworkInterfaceNameHasPrefix(name, "awdl") ||
           PXNetworkInterfaceNameHasPrefix(name, "llw");
}

static bool PXNetworkInterfaceIsCellular(const char *name) {
    return PXNetworkInterfaceNameHasPrefix(name, "pdp_ip");
}

static size_t PXNetworkSockaddrSize(const struct sockaddr *address) {
    if (!address) {
        return 0;
    }
#if defined(__APPLE__)
    if (address->sa_len > 0) {
        return address->sa_len;
    }
#endif
    switch (address->sa_family) {
        case AF_INET:
            return sizeof(struct sockaddr_in);
        case AF_INET6:
            return sizeof(struct sockaddr_in6);
        default:
            return sizeof(struct sockaddr);
    }
}

static char *PXNetworkDuplicateString(const char *value) {
    if (!value) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    char *copy = malloc(length);
    if (copy) {
        memcpy(copy, value, length);
    }
    return copy;
}

static struct sockaddr *PXNetworkDuplicateSockaddr(const struct sockaddr *address) {
    size_t size = PXNetworkSockaddrSize(address);
    if (size == 0) {
        return NULL;
    }
    struct sockaddr *copy = malloc(size);
    if (copy) {
        memcpy(copy, address, size);
    }
    return copy;
}

static void PXNetworkInterfaceFreeNode(struct ifaddrs *interface) {
    if (!interface) {
        return;
    }
    free(interface->ifa_name);
    free(interface->ifa_addr);
    free(interface->ifa_netmask);
    free(interface->ifa_dstaddr);
    free(interface);
}

void PXNetworkInterfacePolicyFreeView(struct ifaddrs *viewInterfaces) {
    while (viewInterfaces) {
        struct ifaddrs *next = viewInterfaces->ifa_next;
        PXNetworkInterfaceFreeNode(viewInterfaces);
        viewInterfaces = next;
    }
}

static struct ifaddrs *PXNetworkInterfaceCloneNode(const struct ifaddrs *original) {
    struct ifaddrs *copy = calloc(1, sizeof(*copy));
    if (!copy) {
        return NULL;
    }
    copy->ifa_name = PXNetworkDuplicateString(original->ifa_name);
    copy->ifa_flags = original->ifa_flags;
    copy->ifa_addr = PXNetworkDuplicateSockaddr(original->ifa_addr);
    copy->ifa_netmask = PXNetworkDuplicateSockaddr(original->ifa_netmask);
    copy->ifa_dstaddr = PXNetworkDuplicateSockaddr(original->ifa_dstaddr);
    copy->ifa_data = original->ifa_data;
    if ((original->ifa_name && !copy->ifa_name) ||
        (original->ifa_addr && !copy->ifa_addr) ||
        (original->ifa_netmask && !copy->ifa_netmask) ||
        (original->ifa_dstaddr && !copy->ifa_dstaddr)) {
        PXNetworkInterfaceFreeNode(copy);
        return NULL;
    }
    return copy;
}

static bool PXNetworkInterfacePolicyKeepsName(const PXNetworkInterfacePolicy *policy,
                                              const char *name) {
    if (policy->hideTunnelInterfaces && PXNetworkInterfaceIsTunnel(name)) {
        return false;
    }
    switch (policy->transport) {
        case PXNetworkInterfaceTransportWiFi:
            return !PXNetworkInterfaceIsCellular(name);
        case PXNetworkInterfaceTransportCellular:
            return !PXNetworkInterfaceIsWiFi(name);
        case PXNetworkInterfaceTransportOffline:
            return PXNetworkInterfaceIsLoopback(name);
        case PXNetworkInterfaceTransportOriginal:
            return true;
    }
    return false;
}

static bool PXNetworkInterfaceAddressIsUnspecified(const struct sockaddr *address) {
    if (!address) {
        return false;
    }
    if (address->sa_family == AF_INET) {
        return ((const struct sockaddr_in *)address)->sin_addr.s_addr == INADDR_ANY;
    }
    if (address->sa_family == AF_INET6) {
        return IN6_IS_ADDR_UNSPECIFIED(&((const struct sockaddr_in6 *)address)->sin6_addr);
    }
    return false;
}

static bool PXNetworkInterfacePolicyHasValidAddresses(const PXNetworkInterfacePolicy *policy) {
    if (policy->transport != PXNetworkInterfaceTransportWiFi &&
        policy->transport != PXNetworkInterfaceTransportCellular) {
        return true;
    }
    return policy->hasIPv4Address && policy->ipv4Address.s_addr != INADDR_ANY &&
           policy->hasIPv6Address && !IN6_IS_ADDR_UNSPECIFIED(&policy->ipv6Address);
}

static bool PXNetworkInterfaceReplaceAddress(struct ifaddrs *interface,
                                             const PXNetworkInterfacePolicy *policy) {
    if (!interface->ifa_addr) {
        return true;
    }
    if (interface->ifa_addr->sa_family == AF_INET) {
        ((struct sockaddr_in *)interface->ifa_addr)->sin_addr = policy->ipv4Address;
    } else if (interface->ifa_addr->sa_family == AF_INET6) {
        ((struct sockaddr_in6 *)interface->ifa_addr)->sin6_addr = policy->ipv6Address;
    }
    return true;
}

static struct ifaddrs *PXNetworkInterfaceCreateSynthetic(const char *name,
                                                         sa_family_t family,
                                                         const PXNetworkInterfacePolicy *policy) {
    struct ifaddrs *interface = calloc(1, sizeof(*interface));
    if (!interface) {
        return NULL;
    }
    interface->ifa_name = PXNetworkDuplicateString(name);
    interface->ifa_flags = IFF_UP | IFF_RUNNING;
#if defined(IFF_POINTOPOINT)
    if (policy->transport == PXNetworkInterfaceTransportCellular) {
        interface->ifa_flags |= IFF_POINTOPOINT;
    }
#endif
    if (family == AF_INET) {
        struct sockaddr_in *address = calloc(1, sizeof(*address));
        struct sockaddr_in *netmask = calloc(1, sizeof(*netmask));
        interface->ifa_addr = (struct sockaddr *)address;
        interface->ifa_netmask = (struct sockaddr *)netmask;
        if (address) {
#if defined(__APPLE__)
            address->sin_len = sizeof(*address);
#endif
            address->sin_family = AF_INET;
            address->sin_addr = policy->ipv4Address;
        }
        if (netmask) {
#if defined(__APPLE__)
            netmask->sin_len = sizeof(*netmask);
#endif
            netmask->sin_family = AF_INET;
            netmask->sin_addr.s_addr = policy->transport == PXNetworkInterfaceTransportCellular
                ? UINT32_MAX
                : htonl(0xFFFFFF00U);
        }
    } else {
        struct sockaddr_in6 *address = calloc(1, sizeof(*address));
        struct sockaddr_in6 *netmask = calloc(1, sizeof(*netmask));
        interface->ifa_addr = (struct sockaddr *)address;
        interface->ifa_netmask = (struct sockaddr *)netmask;
        if (address) {
#if defined(__APPLE__)
            address->sin6_len = sizeof(*address);
#endif
            address->sin6_family = AF_INET6;
            address->sin6_addr = policy->ipv6Address;
        }
        if (netmask) {
#if defined(__APPLE__)
            netmask->sin6_len = sizeof(*netmask);
#endif
            netmask->sin6_family = AF_INET6;
            memset(&netmask->sin6_addr, 0xFF, 8);
        }
    }
    if (!interface->ifa_name || !interface->ifa_addr || !interface->ifa_netmask) {
        PXNetworkInterfaceFreeNode(interface);
        return NULL;
    }
    return interface;
}

static void PXNetworkInterfaceAppend(struct ifaddrs **head,
                                     struct ifaddrs **tail,
                                     struct ifaddrs *interface) {
    if (*tail) {
        (*tail)->ifa_next = interface;
    } else {
        *head = interface;
    }
    *tail = interface;
}

bool PXNetworkInterfacePolicyCreateView(const struct ifaddrs *originalInterfaces,
                                        const PXNetworkInterfacePolicy *policy,
                                        struct ifaddrs **viewInterfaces) {
    if (!policy || !viewInterfaces || !PXNetworkInterfacePolicyHasValidAddresses(policy)) {
        return false;
    }

    *viewInterfaces = NULL;
    struct ifaddrs *tail = NULL;
    bool hasTargetIPv4 = false;
    bool hasTargetIPv6 = false;
    for (const struct ifaddrs *original = originalInterfaces; original; original = original->ifa_next) {
        if (!PXNetworkInterfacePolicyKeepsName(policy, original->ifa_name)) {
            continue;
        }
        bool isTarget = policy->transport == PXNetworkInterfaceTransportWiFi
            ? PXNetworkInterfaceIsWiFi(original->ifa_name)
            : (policy->transport == PXNetworkInterfaceTransportCellular &&
               PXNetworkInterfaceIsCellular(original->ifa_name));
        if (!isTarget && !PXNetworkInterfaceIsLoopback(original->ifa_name) &&
            PXNetworkInterfaceAddressIsUnspecified(original->ifa_addr)) {
            continue;
        }

        struct ifaddrs *copy = PXNetworkInterfaceCloneNode(original);
        if (!copy) {
            PXNetworkInterfacePolicyFreeView(*viewInterfaces);
            *viewInterfaces = NULL;
            return false;
        }
        if (isTarget) {
            PXNetworkInterfaceReplaceAddress(copy, policy);
            hasTargetIPv4 |= copy->ifa_addr && copy->ifa_addr->sa_family == AF_INET;
            hasTargetIPv6 |= copy->ifa_addr && copy->ifa_addr->sa_family == AF_INET6;
        }
        PXNetworkInterfaceAppend(viewInterfaces, &tail, copy);
    }

    if (policy->transport == PXNetworkInterfaceTransportWiFi ||
        policy->transport == PXNetworkInterfaceTransportCellular) {
        const char *name = policy->transport == PXNetworkInterfaceTransportWiFi ? "en0" : "pdp_ip0";
        for (sa_family_t family = AF_INET; family <= AF_INET6; family = AF_INET6) {
            bool present = family == AF_INET ? hasTargetIPv4 : hasTargetIPv6;
            if (!present) {
                struct ifaddrs *synthetic = PXNetworkInterfaceCreateSynthetic(name, family, policy);
                if (!synthetic) {
                    PXNetworkInterfacePolicyFreeView(*viewInterfaces);
                    *viewInterfaces = NULL;
                    return false;
                }
                PXNetworkInterfaceAppend(viewInterfaces, &tail, synthetic);
            }
            if (family == AF_INET6) {
                break;
            }
        }
    }
    return true;
}
