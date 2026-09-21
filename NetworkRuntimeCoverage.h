#ifndef PROJECTX_NETWORK_RUNTIME_COVERAGE_H
#define PROJECTX_NETWORK_RUNTIME_COVERAGE_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    PXNetworkCoverageCategoryReachability = 0,
    PXNetworkCoverageCategoryCarrier,
    PXNetworkCoverageCategoryRadioTechnology,
    PXNetworkCoverageCategoryInterfaces,
    PXNetworkCoverageCategoryNetworkFramework,
    PXNetworkCoverageCategoryWiFiInformation,
    PXNetworkCoverageCategoryProxyCFNetwork,
    PXNetworkCoverageCategoryProxySystemConfiguration,
    PXNetworkCoverageCategoryProxyURLSession,
    PXNetworkCoverageCategoryVPNStatus,
    PXNetworkCoverageCategoryCount
} PXNetworkCoverageCategory;

typedef struct {
    uint64_t invokedCategories;
    uint64_t appliedCategories;
} PXNetworkCoverageState;

bool PXNetworkCoverageStateRecord(PXNetworkCoverageState *state,
                                  PXNetworkCoverageCategory category,
                                  bool applied);
void PXNetworkCoverageStateReset(PXNetworkCoverageState *state);
void PXNetworkRuntimeCoverageRecord(PXNetworkCoverageCategory category, bool applied);

#endif
