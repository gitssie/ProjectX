#import "AppIdentity.h"

#include <assert.h>
#include <limits.h>
#include <stdlib.h>

static void testApplicationIdentityIsStableAndProfileBundleScoped(void) {
    PXAppIdentityRecord *first = [PXAppIdentityRecord identityForProfileSeed:@"profile-a"
                                                            bundleIdentifier:@"com.example.app"
                                                        installIdentifierKeys:nil];
    PXAppIdentityRecord *same = [PXAppIdentityRecord identityForProfileSeed:@"profile-a"
                                                           bundleIdentifier:@"com.example.app"
                                                       installIdentifierKeys:nil];
    PXAppIdentityRecord *otherBundle = [PXAppIdentityRecord identityForProfileSeed:@"profile-a"
                                                                  bundleIdentifier:@"com.example.app.extension"
                                                              installIdentifierKeys:nil];
    PXAppIdentityRecord *otherProfile = [PXAppIdentityRecord identityForProfileSeed:@"profile-b"
                                                                   bundleIdentifier:@"com.example.app"
                                                               installIdentifierKeys:nil];

    assert([first.installUUID isEqualToString:same.installUUID]);
    assert([first.containerUUID isEqualToString:same.containerUUID]);
    assert(![first.installUUID isEqualToString:otherBundle.installUUID]);
    assert(![first.containerUUID isEqualToString:otherBundle.containerUUID]);
    assert(![first.installUUID isEqualToString:otherProfile.installUUID]);
    assert(![first.containerUUID isEqualToString:otherProfile.containerUUID]);
    assert([[NSUUID alloc] initWithUUIDString:first.installUUID] != nil);
    assert([[NSUUID alloc] initWithUUIDString:first.containerUUID] != nil);
}

static void testGroupIdentityIsSharedByEntitlementWithinProfile(void) {
    PXAppGroupIdentityRecord *mainAppGroup = [PXAppGroupIdentityRecord
        identityForProfileSeed:@"profile-a"
        groupIdentifier:@"group.com.example.shared"];
    PXAppGroupIdentityRecord *extensionGroup = [PXAppGroupIdentityRecord
        identityForProfileSeed:@"profile-a"
        groupIdentifier:@"group.com.example.shared"];
    PXAppGroupIdentityRecord *otherGroup = [PXAppGroupIdentityRecord
        identityForProfileSeed:@"profile-a"
        groupIdentifier:@"group.com.example.other"];
    PXAppGroupIdentityRecord *otherProfile = [PXAppGroupIdentityRecord
        identityForProfileSeed:@"profile-b"
        groupIdentifier:@"group.com.example.shared"];

    assert([mainAppGroup.containerUUID isEqualToString:extensionGroup.containerUUID]);
    assert(![mainAppGroup.containerUUID isEqualToString:otherGroup.containerUUID]);
    assert(![mainAppGroup.containerUUID isEqualToString:otherProfile.containerUUID]);
}

static void testInstallIdentifierPolicyMatchesOnlyInstallationSemantics(void) {
    NSSet<NSString *> *configuredKeys = [NSSet setWithObject:@"vendor_first_launch_token"];
    assert(PXInstallIdentifierKeyMatches(@"installation-id", configuredKeys));
    assert(PXInstallIdentifierKeyMatches(@"APP.INSTANCE.ID", configuredKeys));
    assert(PXInstallIdentifierKeyMatches(@"vendor_first_launch_token", configuredKeys));
    assert(!PXInstallIdentifierKeyMatches(@"device_uuid", configuredKeys));
    assert(!PXInstallIdentifierKeyMatches(@"session_id", configuredKeys));
    assert(!PXInstallIdentifierKeyMatches(@"transaction_uuid", configuredKeys));
}

static void testPathMappingIsBidirectionalAndExactPrefixSafe(void) {
    NSString *fixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:fixtureRoot
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    NSString *virtualRoot = @"/var/mobile/Containers/Data/Application/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    PXAppPathMapper *mapper = [[PXAppPathMapper alloc] initWithRealDataRoot:fixtureRoot
                                                           virtualDataRoot:virtualRoot];
    NSString *realDocument = [fixtureRoot stringByAppendingPathComponent:@"Documents/file.txt"];
    NSString *virtualDocument = [virtualRoot stringByAppendingPathComponent:@"Documents/file.txt"];

    assert([[mapper translatedRealPathForPath:virtualDocument] isEqualToString:realDocument]);
    assert([[mapper translatedObservablePathForPath:realDocument] isEqualToString:virtualDocument]);
    assert([[NSFileManager defaultManager] createDirectoryAtPath:[realDocument stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil]);
    assert([@"resolved" writeToFile:realDocument atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    char resolvedPath[PATH_MAX];
    assert(realpath(realDocument.fileSystemRepresentation, resolvedPath) != NULL);
    NSString *resolvedRealDocument = [NSString stringWithUTF8String:resolvedPath];
    assert([[mapper translatedObservablePathForPath:resolvedRealDocument] isEqualToString:virtualDocument]);
    assert([[mapper translatedRealPathForPath:[virtualRoot stringByAppendingString:@"-sibling/file.txt"]]
        isEqualToString:[virtualRoot stringByAppendingString:@"-sibling/file.txt"]]);
    assert([[mapper translatedRealPathForPath:[virtualRoot stringByAppendingPathComponent:@"../escape"]]
        isEqualToString:[virtualRoot stringByAppendingPathComponent:@"../escape"]]);
    [[NSFileManager defaultManager] removeItemAtPath:fixtureRoot error:nil];
}

static void testVirtualFixtureOperationsReachRealRootAndRejectSymlinkEscape(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *fixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *outsideRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([fileManager createDirectoryAtPath:fixtureRoot withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fileManager createDirectoryAtPath:outsideRoot withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *virtualRoot = @"/var/mobile/Containers/Data/Application/11111111-2222-4333-8444-555555555555";
    PXAppPathMapper *mapper = [[PXAppPathMapper alloc] initWithRealDataRoot:fixtureRoot
                                                           virtualDataRoot:virtualRoot];

    NSString *virtualDocuments = [virtualRoot stringByAppendingPathComponent:@"Documents"];
    assert([fileManager createDirectoryAtPath:[mapper translatedRealPathForPath:virtualDocuments]
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:nil]);
    NSString *virtualSource = [virtualDocuments stringByAppendingPathComponent:@"source.txt"];
    NSData *payload = [@"payload" dataUsingEncoding:NSUTF8StringEncoding];
    assert([payload writeToFile:[mapper translatedRealPathForPath:virtualSource] atomically:YES]);
    assert([[NSData dataWithContentsOfFile:[mapper translatedRealPathForPath:virtualSource]] isEqualToData:payload]);
    NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:
        [mapper translatedRealPathForPath:virtualSource]
        error:nil];
    assert([attributes[NSFileSize] unsignedIntegerValue] == payload.length);

    NSString *virtualCopy = [virtualDocuments stringByAppendingPathComponent:@"copy.txt"];
    assert([fileManager copyItemAtPath:[mapper translatedRealPathForPath:virtualSource]
                               toPath:[mapper translatedRealPathForPath:virtualCopy]
                                error:nil]);
    NSString *virtualDestination = [virtualDocuments stringByAppendingPathComponent:@"destination.txt"];
    assert([fileManager moveItemAtPath:[mapper translatedRealPathForPath:virtualCopy]
                                toPath:[mapper translatedRealPathForPath:virtualDestination]
                                 error:nil]);
    NSArray<NSString *> *contents = [fileManager contentsOfDirectoryAtPath:
        [mapper translatedRealPathForPath:virtualDocuments]
        error:nil];
    assert([contents containsObject:@"destination.txt"]);
    assert([fileManager removeItemAtPath:[mapper translatedRealPathForPath:virtualSource] error:nil]);
    assert([fileManager removeItemAtPath:[mapper translatedRealPathForPath:virtualDestination] error:nil]);

    NSString *escapeLink = [fixtureRoot stringByAppendingPathComponent:@"escape"];
    assert([fileManager createSymbolicLinkAtPath:escapeLink withDestinationPath:outsideRoot error:nil]);
    NSString *virtualEscape = [virtualRoot stringByAppendingPathComponent:@"escape/secret.txt"];
    assert([[mapper translatedRealPathForPath:virtualEscape] isEqualToString:virtualEscape]);
    NSString *danglingLink = [fixtureRoot stringByAppendingPathComponent:@"dangling"];
    NSString *missingOutsideTarget = [outsideRoot stringByAppendingPathComponent:@"missing"];
    assert([fileManager createSymbolicLinkAtPath:danglingLink
                             withDestinationPath:missingOutsideTarget
                                          error:nil]);
    NSString *virtualDanglingEscape = [virtualRoot stringByAppendingPathComponent:@"dangling/new.txt"];
    assert([[mapper translatedRealPathForPath:virtualDanglingEscape]
        isEqualToString:virtualDanglingEscape]);
    [fileManager removeItemAtPath:fixtureRoot error:nil];
    [fileManager removeItemAtPath:outsideRoot error:nil];
}

static void testInstallIdentityPolicyKeepsConfiguredDefaultsStableAndUnrelatedValuesUntouched(void) {
    PXAppIdentityRecord *identity = [PXAppIdentityRecord identityForProfileSeed:@"profile-a"
                                                               bundleIdentifier:@"com.example.app"
                                                           installIdentifierKeys:[NSSet setWithObject:@"vendor_install_token"]];
    PXAppInstallIdentityPolicy *policy = [[PXAppInstallIdentityPolicy alloc] initWithIdentity:identity];
    NSString *suiteName = [@"com.hydra.projectx.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    [defaults setObject:[policy valueForWrite:@"original" key:@"vendor_install_token"]
                 forKey:@"vendor_install_token"];
    assert([[policy valueForRead:[defaults objectForKey:@"vendor_install_token"]
                            key:@"vendor_install_token"
                 requestedClass:[NSString class]] isEqualToString:identity.installUUID]);

    PXAppInstallIdentityPolicy *restartedPolicy = [[PXAppInstallIdentityPolicy alloc] initWithIdentity:identity];
    assert([[restartedPolicy valueForRead:[defaults objectForKey:@"vendor_install_token"]
                                     key:@"vendor_install_token"
                          requestedClass:[NSString class]] isEqualToString:identity.installUUID]);
    NSDictionary *nestedValue = @{@"device_uuid": NSUUID.UUID.UUIDString};
    assert([[policy valueForRead:nestedValue key:@"session_id" requestedClass:[NSDictionary class]]
        isEqualToDictionary:nestedValue]);
    NSData *genericUUIDData = [NSMutableData dataWithLength:16];
    assert([[policy valueForRead:genericUUIDData key:@"binary_uuid" requestedClass:[NSData class]]
        isEqualToData:genericUUIDData]);
    [defaults removePersistentDomainForName:suiteName];
}

static void testMappingInitializationFailurePassesThroughAndGroupMappingIsIndependent(void) {
    NSString *missingRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[PXAppPathMapper alloc] initWithRealDataRoot:missingRoot
                                        virtualDataRoot:@"/var/mobile/Containers/Data/Application/invalid"] == nil);

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *dataRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *groupRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([fileManager createDirectoryAtPath:dataRoot withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fileManager createDirectoryAtPath:groupRoot withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *virtualDataRoot = @"/var/mobile/Containers/Data/Application/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    NSString *virtualGroupRoot = @"/var/mobile/Containers/Shared/AppGroup/11111111-2222-4333-8444-555555555555";
    PXAppPathMapper *dataMapper = [[PXAppPathMapper alloc] initWithRealDataRoot:dataRoot
                                                               virtualDataRoot:virtualDataRoot];
    PXAppPathMapper *groupMapper = [dataMapper mapperByAddingRealGroupRoot:groupRoot
                                                          virtualGroupRoot:virtualGroupRoot];
    NSString *virtualGroupFile = [virtualGroupRoot stringByAppendingPathComponent:@"shared.plist"];
    assert([[groupMapper translatedRealPathForPath:virtualGroupFile]
        isEqualToString:[groupRoot stringByAppendingPathComponent:@"shared.plist"]]);
    assert([[groupMapper translatedRealPathForPath:@"relative/path"] isEqualToString:@"relative/path"]);
    [fileManager removeItemAtPath:dataRoot error:nil];
    [fileManager removeItemAtPath:groupRoot error:nil];
}

static void testOnlyDataAndAppGroupContainerRootsAreEligibleForVirtualization(void) {
    NSString *uuid = @"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    assert(PXIsValidRealDataContainerRoot(
        [@"/var/mobile/Containers/Data/Application" stringByAppendingPathComponent:uuid]));
    assert(PXIsValidRealDataContainerRoot(
        [@"/var/mobile/Containers/Data/PluginKitPlugin" stringByAppendingPathComponent:uuid]));
    assert(PXIsValidRealAppGroupRoot(
        [@"/var/mobile/Containers/Shared/AppGroup" stringByAppendingPathComponent:uuid]));
    assert(!PXIsValidRealDataContainerRoot(
        [@"/var/mobile/Containers/Bundle/Application" stringByAppendingPathComponent:uuid]));
    assert(!PXIsValidRealDataContainerRoot(
        [@"/tmp/Containers/Data/Application" stringByAppendingPathComponent:uuid]));
    assert(!PXIsValidRealDataContainerRoot(
        [[@"/var/mobile/Containers/Data/Application" stringByAppendingPathComponent:uuid]
            stringByAppendingPathComponent:@"Documents"]));
}

static void testOnlyEnabledScopedThirdPartyAndSupportedVisibleSystemBundlesAreEligible(void) {
    assert(PXAppIdentityBundleIsEligible(@"com.example.app", YES, NO));
    assert(PXAppIdentityBundleIsEligible(@"com.example.app.extension", NO, YES));
    assert(!PXAppIdentityBundleIsEligible(@"com.example.app", NO, NO));
    assert(!PXAppIdentityBundleIsEligible(@"com.hydra.projectx", YES, NO));
    assert(!PXAppIdentityBundleIsEligible(@"com.hydra.projectx.extension", NO, YES));
    assert(PXAppIdentityBundleIsEligible(@"com.apple.mobilesafari", YES, NO));
    assert(PXAppIdentityBundleIsEligible(@"com.apple.mobileslideshow", YES, NO));
    assert(!PXAppIdentityBundleIsEligible(@"com.apple.mobilesafari.ShareExtension", NO, YES));
    assert(!PXAppIdentityBundleIsEligible(@"com.apple.Preferences", YES, NO));
    assert(!PXAppIdentityBundleIsEligible(nil, YES, YES));
}

static void testGenerationTargetsOnlyCurrentEnabledEligibleAppScope(void) {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scope = @{
        @"com.example.enabled": @{@"enabled": @YES},
        @"com.example.disabled": @{@"enabled": @NO},
        @"com.apple.mobilesafari": @{@"enabled": @YES},
        @"com.apple.Preferences": @{@"enabled": @YES},
        @"com.hydra.projectx": @{@"enabled": @YES}
    };
    NSSet<NSString *> *targets = PXEnabledEligibleAppBundleIdentifiers(scope);
    NSSet<NSString *> *expected = [NSSet setWithArray:@[
        @"com.example.enabled",
        @"com.apple.mobilesafari"
    ]];
    assert([targets isEqualToSet:expected]);
}

static void testDeviceIdentifierSpoofingRejectsStaleAppleSystemScope(void) {
    assert(!PXDeviceIdentifierSpoofingIsAllowedForBundle(@"com.apple.Preferences", YES));
    assert(!PXDeviceIdentifierSpoofingIsAllowedForBundle(@"com.apple.AppStore", YES));
    assert(!PXDeviceIdentifierSpoofingIsAllowedForBundle(@"COM.APPLE.PREFERENCES", YES));
    assert(PXDeviceIdentifierSpoofingIsAllowedForBundle(@"com.apple.mobilesafari", YES));
    assert(PXDeviceIdentifierSpoofingIsAllowedForBundle(@"com.example.target", YES));
    assert(!PXDeviceIdentifierSpoofingIsAllowedForBundle(@"com.example.target", NO));
}

static void testScopeSanitizationDropsIneligibleAppleSystemEntries(void) {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scope = @{
        @"com.example.enabled": @{@"enabled": @YES},
        @"com.example.disabled": @{@"enabled": @NO},
        @"com.apple.mobilesafari": @{@"enabled": @YES},
        @"com.apple.Preferences": @{@"enabled": @YES},
        @"com.apple.AppStore": @{@"enabled": @YES},
        @"COM.APPLE.PREFERENCES": @{@"enabled": @YES},
        @"com.hydra.projectx": @{@"enabled": @YES}
    };
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *sanitized =
        PXEligibleScopedApplications(scope);
    NSSet<NSString *> *actual = [NSSet setWithArray:sanitized.allKeys];
    NSSet<NSString *> *expected = [NSSet setWithArray:@[
        @"com.example.enabled",
        @"com.example.disabled",
        @"com.apple.mobilesafari"
    ]];
    assert([actual isEqualToSet:expected]);
}

static void testScopeSanitizationTreatsMalformedRecordsAsDisabled(void) {
    NSDictionary *malformedScope = @{
        @"com.example.string-enabled": @{@"enabled": @"YES"},
        @"com.example.missing-enabled": @{},
        @"com.example.invalid-record": @"not-a-dictionary"
    };
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *sanitized =
        PXEligibleScopedApplications((id)malformedScope);
    assert(sanitized.count == 2);
    assert([sanitized[@"com.example.string-enabled"][@"enabled"] isEqual:@NO]);
    assert([sanitized[@"com.example.missing-enabled"][@"enabled"] isEqual:@NO]);
    assert(PXEligibleScopedApplications((id)@[]).count == 0);
}

int main(void) {
    @autoreleasepool {
        testApplicationIdentityIsStableAndProfileBundleScoped();
        testGroupIdentityIsSharedByEntitlementWithinProfile();
        testInstallIdentifierPolicyMatchesOnlyInstallationSemantics();
        testPathMappingIsBidirectionalAndExactPrefixSafe();
        testVirtualFixtureOperationsReachRealRootAndRejectSymlinkEscape();
        testInstallIdentityPolicyKeepsConfiguredDefaultsStableAndUnrelatedValuesUntouched();
        testMappingInitializationFailurePassesThroughAndGroupMappingIsIndependent();
        testOnlyDataAndAppGroupContainerRootsAreEligibleForVirtualization();
        testOnlyEnabledScopedThirdPartyAndSupportedVisibleSystemBundlesAreEligible();
        testGenerationTargetsOnlyCurrentEnabledEligibleAppScope();
        testDeviceIdentifierSpoofingRejectsStaleAppleSystemScope();
        testScopeSanitizationDropsIneligibleAppleSystemEntries();
        testScopeSanitizationTreatsMalformedRecordsAsDisabled();
    }
    return 0;
}
