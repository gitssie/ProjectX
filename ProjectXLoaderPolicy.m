#import "ProjectXLoaderPolicy.h"

static BOOL PXLoaderWildcardMatches(NSString *value, NSString *pattern) {
    if (value.length == 0 || pattern.length == 0) return NO;
    NSString *escaped = [NSRegularExpression escapedPatternForString:pattern];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\\*" withString:@".*"];
    NSString *expression = [NSString stringWithFormat:@"^%@$", escaped];
    return [value rangeOfString:expression
                       options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound;
}

BOOL PXPayloadShouldLoadForIdentity(NSString *bundleIdentifier,
                                    NSString *processName,
                                    NSDictionary *scopePropertyList) {
    NSString *normalizedBundleIdentifier = bundleIdentifier.lowercaseString;
    if ([processName.lowercaseString isEqualToString:@"springboard"] ||
        [normalizedBundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        return YES;
    }
    if (normalizedBundleIdentifier.length == 0 ||
        [normalizedBundleIdentifier isEqualToString:@"com.hydra.projectx"] ||
        [normalizedBundleIdentifier hasPrefix:@"com.hydra.projectx."]) {
        return NO;
    }

    NSDictionary *scopedApps = [scopePropertyList[@"ScopedApps"] isKindOfClass:NSDictionary.class]
        ? scopePropertyList[@"ScopedApps"] : nil;
    if (!scopedApps) return NO;

    __block BOOL directlyEnabled = NO;
    __block BOOL extensionEnabled = NO;
    [scopedApps enumerateKeysAndObjectsUsingBlock:^(id key, id rawValue, BOOL *stop) {
        NSDictionary *value = [rawValue isKindOfClass:NSDictionary.class] ? rawValue : nil;
        if (![key isKindOfClass:NSString.class] || ![value[@"enabled"] boolValue]) return;
        if ([normalizedBundleIdentifier isEqualToString:[key lowercaseString]]) {
            directlyEnabled = YES;
            *stop = YES;
            return;
        }
        NSString *pattern = [value[@"extensionPattern"] isKindOfClass:NSString.class]
            ? value[@"extensionPattern"] : nil;
        if (PXLoaderWildcardMatches(bundleIdentifier, pattern)) {
            extensionEnabled = YES;
            *stop = YES;
        }
    }];

    if ([normalizedBundleIdentifier hasPrefix:@"com.apple."]) {
        static NSSet<NSString *> *supportedAppleApplications;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            supportedAppleApplications = [NSSet setWithArray:@[
                @"com.apple.mobilesafari", @"com.apple.mobileslideshow"
            ]];
        });
        return directlyEnabled &&
            [supportedAppleApplications containsObject:normalizedBundleIdentifier];
    }
    return directlyEnabled || extensionEnabled;
}
