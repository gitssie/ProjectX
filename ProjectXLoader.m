#import <Foundation/Foundation.h>
#import <dlfcn.h>

#import "PXRootHidePath.h"
#import "ProjectXLoaderPolicy.h"

__attribute__((constructor)) static void PXLoadScopedPayload(void) {
    @autoreleasepool {
        NSDictionary *scope = [NSDictionary dictionaryWithContentsOfFile:
            PXGlobalScopePreferencesPath()];
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        NSString *processName = NSProcessInfo.processInfo.processName;
        if (!PXPayloadShouldLoadForIdentity(bundleIdentifier, processName, scope ?: @{})) {
            return;
        }

        NSString *payloadPath = PXJBRootPath(
            @"/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.dylib");
        void *handle = dlopen(payloadPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            NSLog(@"[ProjectXLoader] Unable to load scoped payload for %@: %s",
                  bundleIdentifier ?: processName,
                  dlerror());
        }
    }
}
