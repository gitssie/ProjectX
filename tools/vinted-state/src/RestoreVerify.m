#import "VSTContext.h"
// Sanitized from the 2026-10-05 device experiment; see docs/VALIDATION.md.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/stat.h>
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

int main(){@autoreleasepool{
 CopyACL=dlsym(RTLD_DEFAULT,"SecAccessControlCopyData");DecodeACL=dlsym(RTLD_DEFAULT,"SecAccessControlCreateFromData");if(!CopyACL||!DecodeACL)return 1;
 NSString *backup=VSTBackupPath();
 for(id cls in @[(__bridge id)kSecClassGenericPassword,(__bridge id)kSecClassInternetPassword,(__bridge id)kSecClassCertificate,(__bridge id)kSecClassKey,(__bridge id)kSecClassIdentity]){OSStatus status;BOOL pw=[cls isEqual:(__bridge id)kSecClassGenericPassword]||[cls isEqual:(__bridge id)kSecClassInternetPassword];NSArray *now=ReadItems(cls,pw,&status);if(status!=0&&status!=errSecItemNotFound)return 2;NSArray *desired=[NSArray arrayWithContentsOfFile:[backup stringByAppendingPathComponent:[NSString stringWithFormat:@"keychain/%@.plist",cls]]];if(!desired||![[NSSet setWithArray:ArchiveRecords(now,cls)] isEqual:[NSSet setWithArray:desired]])return 3;}
 dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW);Class cls=NSClassFromString(@"LSApplicationProxy");id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,NSSelectorFromString(@"applicationProxyForIdentifier:"),@"lt.manodrabuziai.fr");id value=((id(*)(id,SEL))objc_msgSend)(proxy,NSSelectorFromString(@"deviceIdentifierForVendor"));NSDictionary *identity=[NSDictionary dictionaryWithContentsOfFile:[backup stringByAppendingPathComponent:@"identity/idfv.plist"]];if(![[value description] isEqual:identity[@"IDFV"]])return 4;
 puts("restore_status=complete; keychain_content_and_ACL_match=true; IDFV_matches_backup=true");
}return 0;}
