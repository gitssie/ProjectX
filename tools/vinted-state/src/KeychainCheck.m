#import "VSTContext.h"
// Sanitized from the 2026-10-05 device experiment; see docs/VALIDATION.md.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <dlfcn.h>
static CFDataRef (*CopyACL)(SecAccessControlRef);
static SecAccessControlRef (*DecodeACL)(CFAllocatorRef, CFDataRef, CFErrorRef *);
static NSString *const Group = @"4Y2CNF6C99.com.vinted.keychain-group";
static NSDictionary *Query(id cls) {
    LAContext *context = [LAContext new];
    context.interactionNotAllowed = YES;
    return @{(__bridge id)kSecClass:cls, (__bridge id)kSecAttrAccessGroup:Group,
             (__bridge id)kSecAttrSynchronizable:@NO, (__bridge id)kSecUseAuthenticationContext:context};
}
static NSArray *ReadItems(id cls, BOOL data, OSStatus *status) {
    NSMutableDictionary *query = [Query(cls) mutableCopy];
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    if (data) query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    *status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (*status != errSecSuccess) { if (result) CFRelease(result); return @[]; }
    id object = CFBridgingRelease(result);
    return [object isKindOfClass:[NSArray class]] ? object : @[object];
}
static NSArray *ArchiveRecords(NSArray *items, id cls) {
    NSMutableArray *records = [NSMutableArray array];
    NSArray *keys = @[(__bridge id)kSecAttrAccount, (__bridge id)kSecAttrService,
        (__bridge id)kSecAttrServer, (__bridge id)kSecAttrPort, (__bridge id)kSecAttrProtocol,
        (__bridge id)kSecAttrAuthenticationType, (__bridge id)kSecAttrSecurityDomain,
        (__bridge id)kSecAttrPath, (__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrAccessible,
        (__bridge id)kSecAttrSynchronizable, (__bridge id)kSecAttrLabel, (__bridge id)kSecAttrDescription,
        (__bridge id)kSecAttrComment, (__bridge id)kSecAttrGeneric, (__bridge id)kSecAttrCreator,
        (__bridge id)kSecAttrType, (__bridge id)kSecAttrIsInvisible, (__bridge id)kSecAttrIsNegative,
        (__bridge id)kSecValueData];
    for (NSDictionary *item in items) {
        NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObject:cls forKey:(__bridge id)kSecClass];
        for (id key in keys) if (item[key]) record[key] = item[key];
        id acl = item[(__bridge id)kSecAttrAccessControl];
        if (acl && CopyACL) {
            CFDataRef data = CopyACL((__bridge SecAccessControlRef)acl);
            if (data) record[@"PXArchivedACL"] = CFBridgingRelease(data);
        }
        [records addObject:record];
    }
    return records;
}
static NSDictionary *TestRestore(id cls) {
    NSString *nonce = [NSUUID UUID].UUIDString;
    NSMutableDictionary *identity = [Query(cls) mutableCopy];
    identity[(__bridge id)kSecAttrAccount] = nonce;
    if ([cls isEqual:(__bridge id)kSecClassGenericPassword]) identity[(__bridge id)kSecAttrService] = [@"com.cazer.keychain-verification." stringByAppendingString:nonce];
    else {
        identity[(__bridge id)kSecAttrServer] = @"keychain-verification.invalid";
        identity[(__bridge id)kSecAttrPath] = nonce;
        identity[(__bridge id)kSecAttrProtocol] = (__bridge id)kSecAttrProtocolHTTPS;
        identity[(__bridge id)kSecAttrPort] = @443;
    }
    NSMutableDictionary *payload = [identity mutableCopy];
    [payload removeObjectForKey:(__bridge id)kSecUseAuthenticationContext];
    unsigned char bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return @{@"randomFailed":@YES};
    NSData *secret = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    payload[(__bridge id)kSecValueData] = secret;
    payload[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    OSStatus add = SecItemAdd((__bridge CFDictionaryRef)payload, NULL);
    report[@"createStatus"] = @(add);
    if (add != errSecSuccess) return report;
    @try {
        NSMutableDictionary *read = [identity mutableCopy];
        read[(__bridge id)kSecReturnAttributes] = @YES;
        read[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef object = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &object);
        report[@"backupReadStatus"] = @(status);
        if (status != errSecSuccess) { if (object) CFRelease(object); return report; }
        NSDictionary *item = CFBridgingRelease(object);
        NSArray *records = ArchiveRecords(@[item], cls);
        NSData *archive = [NSPropertyListSerialization dataWithPropertyList:records format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        NSArray *decoded = archive ? [NSPropertyListSerialization propertyListWithData:archive options:0 format:NULL error:NULL] : nil;
        if (decoded.count != 1) { report[@"archiveFailed"] = @YES; return report; }
        status = SecItemDelete((__bridge CFDictionaryRef)identity);
        report[@"deleteStatus"] = @(status);
        if (status != errSecSuccess) return report;
        NSMutableDictionary *restore = [decoded[0] mutableCopy];
        NSData *aclData = restore[@"PXArchivedACL"];
        [restore removeObjectForKey:@"PXArchivedACL"];
        if (aclData) {
            SecAccessControlRef acl = DecodeACL ? DecodeACL(kCFAllocatorDefault, (__bridge CFDataRef)aclData, NULL) : NULL;
            if (!acl) { report[@"aclDecodeFailed"] = @YES; return report; }
            restore[(__bridge id)kSecAttrAccessControl] = CFBridgingRelease(acl);
            [restore removeObjectForKey:(__bridge id)kSecAttrAccessible];
        }
        report[@"aclRestored"] = @(aclData != nil);
        report[@"restoreStatus"] = @(SecItemAdd((__bridge CFDictionaryRef)restore, NULL));
        NSMutableDictionary *verify = [identity mutableCopy];
        verify[(__bridge id)kSecReturnData] = @YES;
        object = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)verify, &object);
        report[@"verifyStatus"] = @(status);
        NSData *restored = object ? CFBridgingRelease(object) : nil;
        report[@"secretBytesEqual"] = @([secret isEqual:restored]);
    } @finally {
        report[@"cleanupStatus"] = @(SecItemDelete((__bridge CFDictionaryRef)identity));
    }
    return report;
}
int main(void) {
    @autoreleasepool {
        CopyACL = dlsym(RTLD_DEFAULT, "SecAccessControlCopyData");
        DecodeACL = dlsym(RTLD_DEFAULT, "SecAccessControlCreateFromData");
        NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:@{@"accessGroup":Group, @"synchronizableIncluded":@NO, @"existingItemsDeleted":@NO, @"secretsWrittenToDisk":@NO}];
        NSArray *classes = @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword, (__bridge id)kSecClassCertificate, (__bridge id)kSecClassKey, (__bridge id)kSecClassIdentity];
        NSMutableDictionary *classReports = [NSMutableDictionary dictionary];
        for (id cls in classes) {
            OSStatus status;
            NSArray *attributes = ReadItems(cls, NO, &status);
            NSMutableDictionary *summary = [NSMutableDictionary dictionaryWithDictionary:@{@"queryStatus":@(status), @"count":@(attributes.count)}];
            if ([cls isEqual:(__bridge id)kSecClassGenericPassword] || [cls isEqual:(__bridge id)kSecClassInternetPassword]) {
                OSStatus dataStatus;
                NSArray *items = ReadItems(cls, YES, &dataStatus);
                summary[@"dataReadStatus"] = @(dataStatus);
                NSUInteger accessControl = 0, dataCount = 0, aclRoundTrip = 0;
                for (NSDictionary *item in items) {
                    id acl = item[(__bridge id)kSecAttrAccessControl];
                    if (acl) {
                        accessControl++;
                        CFDataRef encoded = CopyACL ? CopyACL((__bridge SecAccessControlRef)acl) : NULL;
                        SecAccessControlRef decodedACL = encoded && DecodeACL ? DecodeACL(kCFAllocatorDefault, encoded, NULL) : NULL;
                        CFDataRef encodedAgain = decodedACL && CopyACL ? CopyACL(decodedACL) : NULL;
                        if (encoded && encodedAgain && CFEqual(encoded, encodedAgain)) aclRoundTrip++;
                        if (encodedAgain) CFRelease(encodedAgain);
                        if (decodedACL) CFRelease(decodedACL);
                        if (encoded) CFRelease(encoded);
                    }
                    if ([item[(__bridge id)kSecValueData] isKindOfClass:[NSData class]]) dataCount++;
                }
                summary[@"aclSerializationRoundTripCount"] = @(aclRoundTrip);
                summary[@"readableSecretCount"] = @(dataCount);
                summary[@"accessControlItemCount"] = @(accessControl);
                NSArray *records = ArchiveRecords(items, cls);
                NSData *archive = [NSPropertyListSerialization dataWithPropertyList:records format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
                NSArray *decoded = archive ? [NSPropertyListSerialization propertyListWithData:archive options:0 format:NULL error:NULL] : nil;
                summary[@"memoryArchiveBytes"] = @(archive.length);
                summary[@"memoryRoundTripEqual"] = @([records isEqual:decoded]);
                summary[@"testItemRoundTrip"] = TestRestore(cls);
                OSStatus afterStatus;
                NSArray *after = ReadItems(cls, YES, &afterStatus);
                summary[@"afterReadStatus"] = @(afterStatus);
                summary[@"existingItemsUnchanged"] = @([[NSSet setWithArray:items] isEqual:[NSSet setWithArray:after]]);
            }
            classReports[cls] = summary;
        }
        report[@"classes"] = classReports;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
        fwrite(json.bytes,1,json.length,stdout); puts("");
    }
    return 0;
}
