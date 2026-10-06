#import "VSTContext.h"
// Sanitized from the 2026-10-05 device experiment; see docs/VALIDATION.md.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
#import <copyfile.h>
#import <sys/stat.h>
#import <unistd.h>
#import <objc/message.h>
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

static void Fail(NSString *message) { fprintf(stderr,"%s\n",message.UTF8String); exit(1); }
static void WritePlist(id object, NSString *path) {
    NSError *error=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:object format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) Fail([NSString stringWithFormat:@"write failed: %@ %@",path,error]);
    if (chmod(path.fileSystemRepresentation,0600)) Fail(@"chmod failed");
    id decoded=[NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:path] options:0 format:NULL error:&error];
    if (![object isEqual:decoded]) Fail(@"plist readback mismatch");
}
static NSArray *Inventory(NSString *base) {
    NSFileManager *fm=[NSFileManager defaultManager];
    NSError *error=nil;
    NSArray *all=[fm subpathsOfDirectoryAtPath:base error:&error];
    if (!all) Fail([NSString stringWithFormat:@"enumerate failed %@",error]);
    NSMutableArray *entries=[NSMutableArray array];
    for (NSString *relative in [all sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path=[base stringByAppendingPathComponent:relative];
        struct stat st;
        if (lstat(path.fileSystemRepresentation,&st)) Fail(@"stat failed");
        NSMutableDictionary *entry=[@{@"path":relative,@"mode":@(st.st_mode & 07777),@"uid":@(st.st_uid),@"gid":@(st.st_gid)} mutableCopy];
        if (S_ISREG(st.st_mode)) {
            entry[@"type"]=@"file"; entry[@"size"]=@(st.st_size);
            BOOL core = [relative.lastPathComponent isEqual:@"Info.plist"] || [relative.lastPathComponent isEqual:@"Vinted"] || [relative.lastPathComponent isEqual:@".com.apple.mobile_container_manager.metadata.plist"] || [relative isEqual:@"Library/Preferences/lt.manodrabuziai.fr.plist"] || [relative.pathExtension isEqual:@"sqlite"] || [relative.pathExtension isEqual:@"db"];
            if (!core) { [entries addObject:entry]; continue; }
            NSInputStream *stream=[NSInputStream inputStreamWithFileAtPath:path];
            [stream open]; CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
            uint8_t buf[65536]; NSInteger n; unsigned long long size=0;
            while ((n=[stream read:buf maxLength:sizeof(buf)])>0) { CC_SHA256_Update(&ctx,buf,(CC_LONG)n); size+=(unsigned long long)n; }
            [stream close]; if (n<0 || size!=(unsigned long long)st.st_size) Fail(@"hash read failed");
            uint8_t hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(hash,&ctx);
            NSMutableString *hex=[NSMutableString string]; for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hex appendFormat:@"%02x",hash[i]];
            entry[@"type"]=@"file"; entry[@"size"]=@(size); entry[@"sha256"]=hex;
        } else if (S_ISDIR(st.st_mode)) entry[@"type"]=@"directory";
        else if (S_ISLNK(st.st_mode)) { entry[@"type"]=@"symlink"; entry[@"target"]=[fm destinationOfSymbolicLinkAtPath:path error:&error]; if (!entry[@"target"]) Fail(@"readlink failed"); }
        else Fail(@"unsupported file type");
        [entries addObject:entry];
    }
    return entries;
}
static NSArray *ContentOnly(NSArray *entries) {
    NSMutableArray *result=[NSMutableArray array];
    for (NSDictionary *entry in entries) { NSMutableDictionary *copy=[entry mutableCopy]; [copy removeObjectsForKeys:@[@"uid",@"gid"]]; [result addObject:copy]; }
    return result;
}
int main(int argc,const char **argv) {
 @autoreleasepool {
    umask(0077);
    CopyACL=dlsym(RTLD_DEFAULT,"SecAccessControlCopyData"); DecodeACL=dlsym(RTLD_DEFAULT,"SecAccessControlCreateFromData");
    if (!CopyACL || !DecodeACL || argc!=2) Fail(@"required ACL functions or destination missing");
    NSString *base=@(argv[1]);
    if (![base hasPrefix:@"/private/var/mobile/Media/VintedBackups/"] || [base containsString:@".."] || [base componentsSeparatedByString:@"/"].count!=7) Fail(@"invalid destination");
    NSFileManager *fm=[NSFileManager defaultManager]; NSError *error=nil;
    if ([fm fileExistsAtPath:base]) Fail(@"destination already exists");
    if (![fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) Fail([error description]);
    for (NSString *dir in @[@"application",@"containers",@"keychain",@"identity"]) if (![fm createDirectoryAtPath:[base stringByAppendingPathComponent:dir] withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error]) Fail([error description]);
    NSArray *sources=@[
        @[VSTSourcePath(@"bundle"),@"application/Vinted.app"],
        @[VSTSourcePath(@"data"),@"containers/data"],
        @[VSTSourcePath(@"group"),@"containers/app-group"]];
    NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[sources[0][0] stringByAppendingPathComponent:@"Info.plist"]];
    if (![info[@"CFBundleIdentifier"] isEqual:@"lt.manodrabuziai.fr"]) Fail(@"bundle mismatch");
    NSDictionary *dataMeta=[NSDictionary dictionaryWithContentsOfFile:[sources[1][0] stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    NSDictionary *groupMeta=[NSDictionary dictionaryWithContentsOfFile:[sources[2][0] stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    if (![dataMeta[@"MCMMetadataIdentifier"] isEqual:@"lt.manodrabuziai.fr"] || ![groupMeta[@"MCMMetadataIdentifier"] isEqual:@"group.lt.vinted.vinted"]) Fail([NSString stringWithFormat:@"container identity mismatch data=%@ group=%@",dataMeta.allKeys,groupMeta[@"MCMMetadataIdentifier"]]);
    NSMutableArray *copyReports=[NSMutableArray array];
    NSMutableDictionary *inventories=[NSMutableDictionary dictionary];
    for (NSArray *pair in sources) {
        NSString *source=pair[0], *dest=[base stringByAppendingPathComponent:pair[1]];
        NSArray *before=Inventory(source);
        if (copyfile(source.fileSystemRepresentation,dest.fileSystemRepresentation,NULL,COPYFILE_ALL|COPYFILE_RECURSIVE|COPYFILE_NOFOLLOW)) Fail([NSString stringWithFormat:@"copy failed %@ errno=%d",pair[1],errno]);
        NSArray *after=Inventory(source),*copied=Inventory(dest);
        if (![before isEqual:after] || ![ContentOnly(before) isEqual:ContentOnly(copied)]) Fail([NSString stringWithFormat:@"copy verification failed %@",pair[1]]);
        inventories[pair[1]]=before;
        unsigned long long bytes=0; NSUInteger files=0;
        for (NSDictionary *entry in before) if ([entry[@"type"] isEqual:@"file"]) { bytes+=[entry[@"size"] unsignedLongLongValue]; files++; }
        [copyReports addObject:@{@"source":source,@"destination":pair[1],@"regularFiles":@(files),@"bytes":@(bytes),@"coreFilesSHA256Verified":@YES,@"sourceStable":@YES,@"ownershipStoredInInventory":@YES}];
    }
    NSMutableDictionary *counts=[NSMutableDictionary dictionary];
    for (id cls in @[(__bridge id)kSecClassGenericPassword,(__bridge id)kSecClassInternetPassword,(__bridge id)kSecClassCertificate,(__bridge id)kSecClassKey,(__bridge id)kSecClassIdentity]) {
        OSStatus status; BOOL passwords=[cls isEqual:(__bridge id)kSecClassGenericPassword]||[cls isEqual:(__bridge id)kSecClassInternetPassword];
        NSArray *items=ReadItems(cls,passwords,&status);
        if (status!=0 && status!=errSecItemNotFound) Fail([NSString stringWithFormat:@"keychain query failed %@ %d",cls,(int)status]);
        if (!passwords && items.count) Fail(@"non-password items require separate export support");
        NSArray *records=ArchiveRecords(items,cls);
        for (NSUInteger i=0;i<items.count;i++) {
            NSDictionary *item=items[i],*record=records[i];
            if (![record[(__bridge id)kSecValueData] isKindOfClass:NSData.class]) Fail(@"missing keychain bytes");
            if (item[(__bridge id)kSecAttrAccessControl] && !record[@"PXArchivedACL"]) Fail(@"ACL not archived");
        }
        WritePlist(records,[base stringByAppendingPathComponent:[NSString stringWithFormat:@"keychain/%@.plist",cls]]);
        NSArray *again=ReadItems(cls,passwords,&status);
        if (![[NSSet setWithArray:items] isEqual:[NSSet setWithArray:again]]) Fail(@"keychain changed while backing up");
        counts[cls]=@(items.count);
    }
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW);
    Class proxyClass=NSClassFromString(@"LSApplicationProxy");
    id proxy=((id(*)(id,SEL,id))objc_msgSend)(proxyClass,NSSelectorFromString(@"applicationProxyForIdentifier:"),@"lt.manodrabuziai.fr");
    id idfv=((id(*)(id,SEL))objc_msgSend)(proxy,NSSelectorFromString(@"deviceIdentifierForVendor"));
    if (!idfv) Fail(@"IDFV read failed");
    WritePlist(@{@"bundleID":@"lt.manodrabuziai.fr",@"vendor":@"Vinted Limited",@"IDFV":[idfv description]},[base stringByAppendingPathComponent:@"identity/idfv.plist"]);
    NSDictionary *manifest=@{@"formatVersion":@1,@"status":@"payload-verified-awaiting-system-record",@"createdUTC":[[NSDate date] description],@"bundleID":@"lt.manodrabuziai.fr",@"version":info[@"CFBundleShortVersionString"],@"build":info[@"CFBundleVersion"],@"accessGroup":Group,@"keychainCounts":counts,@"copies":copyReports,@"inventories":inventories,@"synchronizableIncluded":@NO,@"keychainACLFormat":@"SecAccessControlCopyData; decode before SecItemAdd and omit kSecAttrAccessible when using kSecAttrAccessControl",@"originalItemsModified":@NO,@"scope":@"local application bundle, containers, nonsynchronizable password keychain and vendor identity; excludes cloud/server state and Secure Enclave secrets"};
    WritePlist(manifest,[base stringByAppendingPathComponent:@"manifest.plist"]);
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"backup":base,@"keychainCounts":counts,@"copies":copyReports,@"inventories":inventories,@"IDFV":[idfv description]} options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes,1,json.length,stdout); puts("");
 }
 return 0;
}
