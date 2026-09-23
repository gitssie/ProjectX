#import "NetworkIdentity.h"
#import "TrustedCarrierPolicy.h"
#import "PXRootHidePath.h"
#include <assert.h>

static NSString *TestJBRoot(NSString *path) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"trusted-carrier-single-profile" stringByAppendingPathComponent:[path substringFromIndex:1]]];
}

static NSString *TestRootFS(NSString *path) { return path; }

int main(void) {
    @autoreleasepool {
        PXSetRootHidePathConvertersForTesting(TestJBRoot, TestRootFS);
        NSString *dataDirectory = PXWeaponXDataPath();
        [[NSFileManager defaultManager] removeItemAtPath:dataDirectory error:nil];
        assert([[NSFileManager defaultManager] createDirectoryAtPath:dataDirectory
            withIntermediateDirectories:YES attributes:nil error:nil]);
        PXTrustedCarrierPolicyStore *store = [[PXTrustedCarrierPolicyStore alloc] init];
        NSArray<NSString *> *knownIDs = [PXAllCarrierIDs().allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        NSString *carrierID = knownIDs.firstObject;
        assert([[store trustedCarrierIDsWithError:nil] isEqualToSet:[NSSet setWithObject:carrierID]]);
        assert([store saveTrustedCarrierIDs:[NSSet setWithObject:carrierID] error:nil]);
        NSDictionary *profile = [NSDictionary dictionaryWithContentsOfFile:PXCurrentProfileInfoPath()];
        assert([profile[@"values"][@"trustedCarriers"][@"trustedCarrierIDs"]
            isEqualToArray:@[carrierID]]);
        assert(![[NSFileManager defaultManager] fileExistsAtPath:[PXWeaponXDataPath() stringByAppendingPathComponent:@"Profiles"]]);
        [[NSFileManager defaultManager] removeItemAtPath:dataDirectory error:nil];
    }
    return 0;
}
