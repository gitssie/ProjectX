#import "PXTargetAppEligibility.h"

#import "AppIdentity.h"

BOOL PXTargetBundleIdentifierIsValid(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:[NSString class]] ||
        bundleIdentifier.length == 0 || bundleIdentifier.length > 255) {
        return NO;
    }
    NSArray<NSString *> *components = [bundleIdentifier componentsSeparatedByString:@"."];
    if (components.count < 2) {
        return NO;
    }
    NSCharacterSet *validCharacters = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    for (NSString *component in components) {
        if (component.length == 0 ||
            [component rangeOfCharacterFromSet:validCharacters.invertedSet].location != NSNotFound) {
            return NO;
        }
    }
    return YES;
}

BOOL PXTargetAppCandidateIsMobileSafari(NSDictionary<NSString *, id> *candidate) {
    NSString *bundleIdentifier = [candidate[@"bundleIdentifier"] isKindOfClass:[NSString class]]
        ? candidate[@"bundleIdentifier"]
        : nil;
    return [bundleIdentifier isEqualToString:@"com.apple.mobilesafari"];
}

BOOL PXTargetAppCandidateIsEligible(NSDictionary<NSString *, id> *candidate) {
    NSString *bundleIdentifier = [candidate[@"bundleIdentifier"] isKindOfClass:[NSString class]]
        ? candidate[@"bundleIdentifier"]
        : nil;
    NSString *displayName = [candidate[@"displayName"] isKindOfClass:[NSString class]]
        ? candidate[@"displayName"]
        : nil;
    NSString *bundlePathExtension = [candidate[@"bundlePathExtension"] isKindOfClass:[NSString class]]
        ? candidate[@"bundlePathExtension"]
        : nil;
    NSString *executableName = [candidate[@"executableName"] isKindOfClass:[NSString class]]
        ? candidate[@"executableName"]
        : nil;
    if (!PXTargetBundleIdentifierIsValid(bundleIdentifier) || displayName.length == 0 ||
        ![bundlePathExtension.lowercaseString isEqualToString:@"app"] ||
        executableName.length == 0 || [executableName containsString:@"/"] ||
        ![candidate[@"installed"] boolValue] || [candidate[@"hidden"] boolValue] ||
        [candidate[@"plugin"] boolValue] || [candidate[@"appClip"] boolValue] ||
        [candidate[@"placeholder"] boolValue] || [candidate[@"launchProhibited"] boolValue]) {
        return NO;
    }
    return PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO);
}

NSArray<NSDictionary<NSString *, id> *> *PXEligibleTargetAppCandidates(
    NSArray<NSDictionary<NSString *, id> *> *candidates
) {
    NSMutableArray<NSDictionary<NSString *, id> *> *eligible = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *candidate in candidates) {
        if (PXTargetAppCandidateIsEligible(candidate)) {
            [eligible addObject:candidate];
        }
    }
    [eligible sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *left,
                                                       NSDictionary<NSString *, id> *right) {
        NSComparisonResult nameResult = [left[@"displayName"]
            localizedCaseInsensitiveCompare:right[@"displayName"]];
        if (nameResult != NSOrderedSame) {
            return nameResult;
        }
        return [left[@"bundleIdentifier"] compare:right[@"bundleIdentifier"]];
    }];
    return [eligible copy];
}
