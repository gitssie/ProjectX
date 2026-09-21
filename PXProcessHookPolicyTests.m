#import <Foundation/Foundation.h>

#include <assert.h>

#import "PXProcessHookPolicy.h"

static void testAppleAuthenticationProcessesAreRejected(void) {
    NSArray<NSString *> *bundleIdentifiers = @[
        @"com.apple.AppStore",
        @"com.apple.Preferences",
        @"com.apple.AuthKitUIService",
        @"com.apple.CoreAuthUI",
        @"com.apple.AppleAccountUI.AAUIFollowUpExtension"
    ];
    for (NSString *bundleIdentifier in bundleIdentifiers) {
        assert(PXProcessHookScopeForIdentity(bundleIdentifier, @"ignored") ==
               PXProcessHookScopeNone);
    }
}

static void testProjectXDoesNotInjectIntoItself(void) {
    assert(PXProcessHookScopeForIdentity(@"com.hydra.projectx", @"ProjectX") ==
           PXProcessHookScopeNone);
    assert(PXProcessHookScopeForIdentity(@"com.hydra.projectx.helper", @"helper") ==
           PXProcessHookScopeNone);
}

static void testSpringBoardUsesOnlyItsDedicatedScope(void) {
    assert(PXProcessHookScopeForIdentity(@"com.apple.springboard", @"SpringBoard") ==
           PXProcessHookScopeSpringBoard);
    assert(PXProcessHookScopeForIdentity(nil, @"SpringBoard") ==
           PXProcessHookScopeSpringBoard);
    assert(!PXProcessMayInstallApplicationHooksForSelection(
        @"com.apple.springboard", @"SpringBoard", YES, YES));
}

static void testSupportedAppsRemainEligibleForApplicationHooks(void) {
    assert(PXProcessMayInstallApplicationHooksForSelection(
        @"lt.manodrabuziai.fr", @"Vinted", YES, NO));
    assert(PXProcessMayInstallApplicationHooksForSelection(
        @"lt.manodrabuziai.fr.ShareExtension", @"ShareExtension", NO, YES));
    assert(PXProcessMayInstallApplicationHooksForSelection(
        @"com.apple.mobilesafari", @"MobileSafari", YES, NO));
    assert(PXProcessMayInstallApplicationHooksForSelection(
        @"com.apple.mobileslideshow", @"MobileSlideShow", YES, NO));
}

static void testUnselectedAppsAndSystemExtensionsAreRejected(void) {
    assert(!PXProcessMayInstallApplicationHooksForSelection(
        @"lt.manodrabuziai.fr", @"Vinted", NO, NO));
    assert(!PXProcessMayInstallApplicationHooksForSelection(
        @"com.apple.mobilesafari", @"MobileSafari", NO, NO));
    assert(!PXProcessMayInstallApplicationHooksForSelection(
        @"com.apple.mobilesafari.ShareExtension", @"ShareExtension", NO, YES));
    assert(!PXProcessMayInstallApplicationHooksForSelection(
        @"com.apple.AppStore", @"AppStore", YES, YES));
}

static void testUnknownOrUnsupportedAppleProcessesFailClosed(void) {
    assert(PXProcessHookScopeForIdentity(nil, nil) == PXProcessHookScopeNone);
    assert(PXProcessHookScopeForIdentity(@"", @"") == PXProcessHookScopeNone);
    assert(PXProcessHookScopeForIdentity(@"com.apple.weather.widget", @"WeatherWidget") ==
           PXProcessHookScopeNone);
}

int main(void) {
    @autoreleasepool {
        testAppleAuthenticationProcessesAreRejected();
        testProjectXDoesNotInjectIntoItself();
        testSpringBoardUsesOnlyItsDedicatedScope();
        testSupportedAppsRemainEligibleForApplicationHooks();
        testUnselectedAppsAndSystemExtensionsAreRejected();
        testUnknownOrUnsupportedAppleProcessesFailClosed();
    }
    return 0;
}
