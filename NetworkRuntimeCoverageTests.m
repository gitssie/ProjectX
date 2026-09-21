#import <Foundation/Foundation.h>

#import "NetworkRuntimeCoverage.h"

#include <assert.h>

void PXLog(NSString *format, ...) {
    (void)format;
}

static void testCoverageIsBoundedPerCategoryAndDisposition(void) {
    PXNetworkCoverageState state = {0};
    assert(PXNetworkCoverageStateRecord(
        &state, PXNetworkCoverageCategoryInterfaces, false));
    assert(!PXNetworkCoverageStateRecord(
        &state, PXNetworkCoverageCategoryInterfaces, false));
    assert(PXNetworkCoverageStateRecord(
        &state, PXNetworkCoverageCategoryInterfaces, true));
    assert(!PXNetworkCoverageStateRecord(
        &state, PXNetworkCoverageCategoryInterfaces, true));
    assert(PXNetworkCoverageStateRecord(
        &state, PXNetworkCoverageCategoryCarrier, true));

    PXNetworkCoverageStateReset(&state);
    assert(PXNetworkCoverageStateRecord(
        &state, PXNetworkCoverageCategoryInterfaces, true));
}

int main(void) {
    testCoverageIsBoundedPerCategoryAndDisposition();
    return 0;
}
