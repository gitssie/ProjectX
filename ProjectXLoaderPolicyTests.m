#import <Foundation/Foundation.h>
#include <assert.h>

#import "ProjectXLoaderPolicy.h"

int main(void) {
    @autoreleasepool {
        NSDictionary *scope = @{
            @"ScopedApps": @{
                @"com.vinted": @{
                    @"enabled": @YES,
                    @"extensionPattern": @"com.vinted.*"
                },
                @"com.apple.mobilesafari": @{ @"enabled": @YES },
                @"com.apple.mobileslideshow": @{ @"enabled": @NO }
            }
        };

        assert(PXPayloadShouldLoadForIdentity(@"com.vinted", @"Vinted", scope));
        assert(PXPayloadShouldLoadForIdentity(@"com.vinted.share", @"ShareExtension", scope));
        assert(PXPayloadShouldLoadForIdentity(@"com.apple.mobilesafari", @"MobileSafari", scope));
        assert(!PXPayloadShouldLoadForIdentity(@"com.apple.AppStore", @"AppStore", scope));
        assert(!PXPayloadShouldLoadForIdentity(@"com.apple.AuthKitUIService", @"AuthKitUIService", scope));
        assert(!PXPayloadShouldLoadForIdentity(@"com.apple.mobileslideshow", @"Photos", scope));
        assert(!PXPayloadShouldLoadForIdentity(@"com.hydra.projectx", @"ProjectX", scope));
        assert(!PXPayloadShouldLoadForIdentity(@"com.example.other", @"Other", scope));
        assert(PXPayloadShouldLoadForIdentity(@"com.apple.springboard", @"SpringBoard", @{}));
    }
    return 0;
}
