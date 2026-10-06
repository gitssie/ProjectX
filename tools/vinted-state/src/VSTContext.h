#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

// These standalone native helpers use physical paths returned by LaunchServices.
// Bootstrap shell callers must convert physical paths using RootHide's rootfs tool.
static inline void VSTStop(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(2);
}
static inline NSString *VSTRequiredPath(const char *key, NSString *prefix, NSUInteger componentCount) {
    const char *value = getenv(key);
    if (!value || !*value) VSTStop("required device path environment variable is missing");
    NSString *path = @(value);
    if (![path hasPrefix:prefix] || [path containsString:@".."] ||
        ![path.stringByStandardizingPath isEqual:path] ||
        path.pathComponents.count != componentCount) VSTStop("invalid device path environment variable");
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (!resolved) VSTStop("device input path does not exist");
    NSString *canonical = @(resolved);
    free(resolved);
    if (![canonical isEqual:path]) VSTStop("device input path must be canonical and not a symlink");
    return path;
}
static inline NSString *VSTBackupPath(void) {
    const char *value = getenv("VST_BACKUP");
    if (value && [@(value) hasPrefix:@"/private/var/mobile/Media/AppStateBackups/"]) {
        NSString *prefix=[@(value) hasPrefix:@"/private/var/mobile/Media/AppStateBackups/lt.manodrabuziai.fr/baselines/"]
            ? @"/private/var/mobile/Media/AppStateBackups/lt.manodrabuziai.fr/baselines/"
            : @"/private/var/mobile/Media/AppStateBackups/lt.manodrabuziai.fr/snapshots/";
        return VSTRequiredPath("VST_BACKUP", prefix, 9);
    }
    return VSTRequiredPath("VST_BACKUP", @"/private/var/mobile/Media/VintedBackups/", 7);
}
static inline NSString *VSTSystemIdentifiersPath(void) {
    NSString *path = VSTRequiredPath("VST_LSD_PLIST", @"/private/var/containers/Shared/SystemGroup/", 10);
    if (![path hasSuffix:@"/Library/Caches/com.apple.lsdidentifiers.plist"]) VSTStop("invalid LaunchServices file");
    return path;
}
static inline NSString *VSTSourcePath(NSString *kind) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!cls || ![cls respondsToSelector:lookup]) VSTStop("LaunchServices proxy unavailable");
    id proxy = ((id(*)(id, SEL, id))objc_msgSend)(cls, lookup, @"lt.manodrabuziai.fr");
    NSString *property = [kind isEqual:@"bundle"] ? @"bundleURL" :
        ([kind isEqual:@"data"] ? @"dataContainerURL" : @"groupContainerURLs");
    SEL selector = NSSelectorFromString(property);
    if (![proxy respondsToSelector:selector]) VSTStop("container property unavailable");
    id value = ((id(*)(id, SEL))objc_msgSend)(proxy, selector);
    NSURL *url = [kind isEqual:@"group"] ? value[@"group.lt.vinted.vinted"] : value;
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL) VSTStop("container URL unavailable");
    NSString *path = url.path;
    NSString *prefix = [kind isEqual:@"bundle"] ? @"/private/var/containers/Bundle/Application/" :
        ([kind isEqual:@"data"] ? @"/private/var/mobile/Containers/Data/Application/" :
         @"/private/var/mobile/Containers/Shared/AppGroup/");
    if (![path hasPrefix:prefix] || [path containsString:@".."])
        VSTStop("container path outside target root");
    return path;
}
