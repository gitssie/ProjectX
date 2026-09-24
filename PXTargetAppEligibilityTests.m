#import <Foundation/Foundation.h>
#include <assert.h>

#import "PXTargetAppEligibility.h"

static NSDictionary<NSString *, id> *Candidate(NSString *bundleIdentifier,
                                                NSString *applicationType) {
    return @{
        @"bundleIdentifier": bundleIdentifier,
        @"displayName": @"Visible App",
        @"bundlePathExtension": @"app",
        @"executableName": @"VisibleApp",
        @"applicationType": applicationType,
        @"installed": @YES,
        @"hidden": @NO,
        @"plugin": @NO,
        @"appClip": @NO,
        @"placeholder": @NO,
        @"launchProhibited": @NO
    };
}

static void testEligibleCatalogIncludesUserAndSupportedVisibleSystemApps(void) {
    assert(PXTargetAppCandidateIsEligible(Candidate(@"com.example.visible", @"User")));
    assert(PXTargetAppCandidateIsEligible(Candidate(@"com.apple.mobilesafari", @"System")));
}

static void testCatalogExcludesJailbreakToolsPackageManagersAndPhotos(void) {
    NSArray<NSString *> *excludedBundleIdentifiers = @[
        @"com.example.RootHide.utility",
        @"com.DoPaMiNe.launcher",
        @"org.coolstar.SileoStore",
        @"com.saurik.Cydia",
        @"com.apple.mobileslideshow"
    ];
    for (NSString *bundleIdentifier in excludedBundleIdentifiers) {
        assert(!PXTargetAppCandidateIsEligible(Candidate(bundleIdentifier, @"User")));
    }
    NSArray<NSDictionary<NSString *, id> *> *eligible = PXEligibleTargetAppCandidates(@[
        Candidate(@"com.example.visible", @"User"),
        Candidate(@"com.apple.mobilesafari", @"System"),
        Candidate(@"com.example.RootHide.utility", @"User"),
        Candidate(@"com.DoPaMiNe.launcher", @"User"),
        Candidate(@"org.coolstar.SileoStore", @"User"),
        Candidate(@"com.saurik.Cydia", @"User"),
        Candidate(@"com.apple.mobileslideshow", @"System")
    ]);
    assert(eligible.count == 2);
}

static void testCatalogExcludesSelfExtensionsHiddenServicesAndNonInjectableRecords(void) {
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates = [NSMutableArray array];
    [candidates addObject:Candidate(@"com.example.visible", @"User")];
    [candidates addObject:Candidate(@"com.hydra.projectx", @"User")];
    [candidates addObject:Candidate(@"com.apple.Preferences", @"System")];

    NSMutableDictionary<NSString *, id> *extension = [Candidate(@"com.example.visible.widget", @"User") mutableCopy];
    extension[@"bundlePathExtension"] = @"appex";
    extension[@"plugin"] = @YES;
    [candidates addObject:extension];

    NSMutableDictionary<NSString *, id> *hidden = [Candidate(@"com.example.hidden", @"User") mutableCopy];
    hidden[@"hidden"] = @YES;
    [candidates addObject:hidden];

    NSMutableDictionary<NSString *, id> *daemon = [Candidate(@"com.example.daemon", @"User") mutableCopy];
    daemon[@"bundlePathExtension"] = @"";
    [candidates addObject:daemon];

    NSMutableDictionary<NSString *, id> *nonInjectable = [Candidate(@"com.example.missing-binary", @"User") mutableCopy];
    nonInjectable[@"executableName"] = @"";
    [candidates addObject:nonInjectable];

    NSArray<NSDictionary<NSString *, id> *> *eligible = PXEligibleTargetAppCandidates(candidates);
    assert(eligible.count == 1);
    assert([eligible.firstObject[@"bundleIdentifier"] isEqualToString:@"com.example.visible"]);
}

static void testCatalogSortsDeterministicallyByDisplayNameThenBundleIdentifier(void) {
    NSMutableDictionary<NSString *, id> *zulu = [Candidate(@"com.example.zulu", @"User") mutableCopy];
    zulu[@"displayName"] = @"Zulu";
    NSMutableDictionary<NSString *, id> *alphaB = [Candidate(@"com.example.alpha-b", @"User") mutableCopy];
    alphaB[@"displayName"] = @"Alpha";
    NSMutableDictionary<NSString *, id> *alphaA = [Candidate(@"com.example.alpha-a", @"User") mutableCopy];
    alphaA[@"displayName"] = @"Alpha";
    NSArray<NSDictionary<NSString *, id> *> *eligible = PXEligibleTargetAppCandidates(@[zulu, alphaB, alphaA]);
    NSArray<NSString *> *bundleIdentifiers = [eligible valueForKey:@"bundleIdentifier"];
    NSArray<NSString *> *expectedBundleIdentifiers = @[
        @"com.example.alpha-a",
        @"com.example.alpha-b",
        @"com.example.zulu"
    ];
    assert([bundleIdentifiers isEqualToArray:expectedBundleIdentifiers]);
}

static void testCatalogRejectsMalformedBundleIdentifiers(void) {
    assert(PXTargetBundleIdentifierIsValid(@"com.example.valid-app"));
    assert(!PXTargetBundleIdentifierIsValid(@"not a bundle/id"));
    assert(!PXTargetBundleIdentifierIsValid(@"com..example"));
    assert(!PXTargetAppCandidateIsEligible(Candidate(@"not a bundle/id", @"User")));
}

int main(void) {
    @autoreleasepool {
        testEligibleCatalogIncludesUserAndSupportedVisibleSystemApps();
        testCatalogExcludesJailbreakToolsPackageManagersAndPhotos();
        testCatalogExcludesSelfExtensionsHiddenServicesAndNonInjectableRecords();
        testCatalogSortsDeterministicallyByDisplayNameThenBundleIdentifier();
        testCatalogRejectsMalformedBundleIdentifiers();
    }
    return 0;
}
