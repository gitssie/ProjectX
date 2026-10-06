#import "VSTContext.h"
// Sanitized from the 2026-10-05 device experiment; see docs/VALIDATION.md.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>

static int SetTargetRecord(int argc, const char **argv) {
    if (argc != 5 || strcmp(argv[1], "set") != 0 || getuid() != 0) return 10;
    NSString *path = @(argv[2]);
    NSString *expected = @(argv[3]);
    NSString *replacement = @(argv[4]);
    if (![[NSUUID alloc] initWithUUIDString:expected] || ![[NSUUID alloc] initWithUUIDString:replacement]) return 11;
    if (![path hasPrefix:@"/private/var/containers/Shared/SystemGroup/"] || [path containsString:@".."] || ![path hasSuffix:@"/Library/Caches/com.apple.lsdidentifiers.plist"]) return 12;
    struct stat original;
    if (lstat(path.fileSystemRepresentation, &original) || !S_ISREG(original.st_mode)) return 13;
    NSError *error = nil;
    NSData *input = [NSData dataWithContentsOfFile:path options:0 error:&error];
    NSMutableDictionary *root = [NSPropertyListSerialization propertyListWithData:input options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
    if (![root isKindOfClass:[NSMutableDictionary class]]) return 14;
    NSMutableDictionary *vendors = root[@"LSVendors"];
    NSMutableDictionary *target = vendors[@"Vinted Limited"];
    if (![target[@"LSApplications"] isEqual:@[@"lt.manodrabuziai.fr"]] || ![target[@"LSVendorIdentifier"] isEqual:expected]) return 15;
    target[@"LSVendorIdentifier"] = replacement;
    NSData *output = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!output) return 16;
    NSString *template = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".cazer-idfv-XXXXXX"];
    char *temporary = strdup(template.fileSystemRepresentation);
    int fd = mkstemp(temporary);
    if (fd < 0) { free(temporary); return 17; }
    BOOL success = fchown(fd, original.st_uid, original.st_gid) == 0 && fchmod(fd, original.st_mode & 0777) == 0;
    const char *bytes = output.bytes;
    size_t offset = 0;
    while (success && offset < output.length) {
        ssize_t amount = write(fd, bytes + offset, output.length - offset);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) success = NO;
        else offset += (size_t)amount;
    }
    if (success) success = fsync(fd) == 0;
    close(fd);
    struct stat current;
    if (success) success = lstat(path.fileSystemRepresentation, &current) == 0 && current.st_dev == original.st_dev && current.st_ino == original.st_ino && current.st_size == original.st_size && current.st_mtime == original.st_mtime;
    if (success) success = rename(temporary, path.fileSystemRepresentation) == 0;
    if (!success) unlink(temporary);
    free(temporary);
    if (!success) return 18;
    printf("target_record_changed=%s -> %s\n", expected.UTF8String, replacement.UTF8String);
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1) return SetTargetRecord(argc, argv);
        void *framework = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
        if (!framework) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
        Class cls = NSClassFromString(@"LSApplicationProxy");
        SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (!cls || ![cls respondsToSelector:lookup]) { fprintf(stderr, "LSApplicationProxy unavailable\n"); return 2; }
        id proxy = ((id(*)(id,SEL,id))objc_msgSend)(cls,lookup,@"lt.manodrabuziai.fr");
        NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:@{@"uid": @(getuid()), @"bundleID": @"lt.manodrabuziai.fr"}];
        for (NSString *key in @[@"deviceIdentifierForVendor", @"vendorName", @"bundleURL", @"isInstalled"]) {
            SEL sel = NSSelectorFromString(key);
            if (![proxy respondsToSelector:sel]) { report[key] = @"unavailable"; continue; }
            if ([key isEqualToString:@"isInstalled"]) report[key] = @(((BOOL(*)(id,SEL))objc_msgSend)(proxy,sel));
            else { id value = ((id(*)(id,SEL))objc_msgSend)(proxy,sel); report[key] = value ? [value description] : @"nil"; }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
        fwrite(json.bytes,1,json.length,stdout); puts("");
    }
    return 0;
}
