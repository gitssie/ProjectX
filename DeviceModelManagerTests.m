#import <Foundation/Foundation.h>

#include <assert.h>

#import "DeviceModelManager.h"
#import "GraphicsIdentity.h"

static NSDictionary<NSString *, id> *CatalogA10HostCapabilities(void) {
    return @{
        @"metalFamilies": @[@1001, @1002, @1003],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9,
                                @10, @12, @13, @14],
        @"maxTextureSize": @16384,
        @"maxRenderbufferSize": @16384,
        @"supportsOpenGLES3": @YES
    };
}

static void testProductionCatalogContainsOnlyIPhoneRecords(void) {
    DeviceModelManager *manager = [[DeviceModelManager alloc] init];
    NSArray<NSDictionary<NSString *, id> *> *records =
        [manager allDeviceSpecificationRecords];
    BOOL foundIPhoneFourteenPro = NO;

    assert(records.count > 0);
    for (NSDictionary<NSString *, id> *record in records) {
        NSString *identifier = [record[@"identifier"] isKindOfClass:[NSString class]]
            ? record[@"identifier"]
            : @"";
        NSString *name = [record[@"name"] isKindOfClass:[NSString class]]
            ? record[@"name"]
            : @"";
        assert([identifier hasPrefix:@"iPhone"]);
        assert([name rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location == NSNotFound);
        foundIPhoneFourteenPro = foundIPhoneFourteenPro ||
            [identifier isEqualToString:@"iPhone15,2"];
    }
    assert(foundIPhoneFourteenPro);
    assert([manager deviceSpecificationsForModel:@"iPad7,5"] == nil);
    assert(![manager isValidDeviceModel:@"iPad7,5"]);
}

static void testEveryCatalogRecordHasStructuredCompatibilityClassification(void) {
    DeviceModelManager *manager = [[DeviceModelManager alloc] init];
    NSDictionary<NSString *, id> *physical =
        [manager deviceSpecificationsForModel:@"iPhone9,2"];
    NSSet<NSString *> *compatibleIdentifiers =
        [NSSet setWithObjects:@"iPhone9,2", @"iPhone9,4", nil];

    for (NSDictionary<NSString *, id> *record in [manager allDeviceSpecificationRecords]) {
        NSError *error = nil;
        BOOL compatible = PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
            record,
            physical,
            CatalogA10HostCapabilities(),
            &error);
        NSString *identifier = record[@"identifier"];
        assert(compatible == [compatibleIdentifiers containsObject:identifier]);
        if (compatible) {
            assert(error == nil);
        } else {
            assert([error.domain isEqualToString:PXModelCompatibilityErrorDomain]);
            assert([error.userInfo[PXModelCompatibilityReasonErrorKey] length] > 0);
            assert([error.userInfo[PXModelCompatibilityMismatchFieldsErrorKey] count] > 0);
        }
    }
}

int main(void) {
    @autoreleasepool {
        testProductionCatalogContainsOnlyIPhoneRecords();
        testEveryCatalogRecordHasStructuredCompatibilityClassification();
    }
    return 0;
}
