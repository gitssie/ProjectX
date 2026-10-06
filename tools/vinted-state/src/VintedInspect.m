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

static id Value(id object,NSString *key){SEL sel=NSSelectorFromString(key);return [object respondsToSelector:sel]?((id(*)(id,SEL))objc_msgSend)(object,sel):nil;}
static NSDictionary *Tree(NSString *path){
 NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
 NSArray *paths=[fm subpathsOfDirectoryAtPath:path error:&error];if(!paths)return @{@"path":path,@"error":[error description]};
 NSMutableArray *dirs=[NSMutableArray array],*files=[NSMutableArray array];unsigned long long total=0;NSUInteger count=0;
 for(NSString *rel in [paths sortedArrayUsingSelector:@selector(compare:)]){
 struct stat st;if(lstat([path stringByAppendingPathComponent:rel].fileSystemRepresentation,&st))continue;
 if(S_ISDIR(st.st_mode)){if([rel componentsSeparatedByString:@"/"].count<=3)[dirs addObject:rel];}
 else if(S_ISREG(st.st_mode)){total+=st.st_size;count++;if(files.count<90)[files addObject:@{@"path":rel,@"bytes":@(st.st_size)}];}
 }
 return @{@"path":path,@"directories":dirs,@"files":files,@"fileCount":@(count),@"bytes":@(total)};
}
int main(){@autoreleasepool{
 CopyACL=dlsym(RTLD_DEFAULT,"SecAccessControlCopyData");DecodeACL=dlsym(RTLD_DEFAULT,"SecAccessControlCreateFromData");
 dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW);
 Class cls=NSClassFromString(@"LSApplicationProxy");id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,NSSelectorFromString(@"applicationProxyForIdentifier:"),@"lt.manodrabuziai.fr");
 NSMutableDictionary *report=[NSMutableDictionary dictionary];
 for(NSString *key in @[@"bundleURL",@"dataContainerURL",@"deviceIdentifierForVendor",@"vendorName",@"shortVersionString",@"bundleVersion"]){id v=Value(proxy,key);report[key]=v?[v description]:@"unavailable";}
 NSURL *data=Value(proxy,@"dataContainerURL");if(data)report[@"dataTree"]=Tree(data.path);
 NSDictionary *groups=Value(proxy,@"groupContainerURLs");NSMutableDictionary *trees=[NSMutableDictionary dictionary];for(NSString *key in groups){NSURL *url=groups[key];trees[key]=Tree(url.path);}report[@"groups"]=trees;
 NSMutableDictionary *kc=[NSMutableDictionary dictionary];
 for(id cls in @[(__bridge id)kSecClassGenericPassword,(__bridge id)kSecClassInternetPassword,(__bridge id)kSecClassCertificate,(__bridge id)kSecClassKey,(__bridge id)kSecClassIdentity]){
 OSStatus status;BOOL password=[cls isEqual:(__bridge id)kSecClassGenericPassword]||[cls isEqual:(__bridge id)kSecClassInternetPassword];NSArray *items=ReadItems(cls,password,&status);
 NSArray *old=[NSArray arrayWithContentsOfFile:[VSTBackupPath() stringByAppendingPathComponent:[NSString stringWithFormat:@"keychain/%@.plist",cls]]];
 NSArray *records=password?ArchiveRecords(items,cls):@[];
 kc[cls]=@{@"count":@(items.count),@"queryStatus":@(status),@"sameAsOldBackup":@(old && [[NSSet setWithArray:records] isEqual:[NSSet setWithArray:old]])};
 }
 report[@"keychain"]=kc;
 NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];fwrite(json.bytes,1,json.length,stdout);puts("");
}return 0;}
