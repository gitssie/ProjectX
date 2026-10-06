#import "VSTContext.h"
// Sanitized from the 2026-10-05 device experiment; see docs/VALIDATION.md.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <copyfile.h>
#import <sys/stat.h>
#import <unistd.h>
#import <CommonCrypto/CommonDigest.h>
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

static void Require(BOOL ok,NSString *why){if(!ok)@throw [NSException exceptionWithName:@"RestoreError" reason:why userInfo:nil];}
static id Value(id object,NSString *key){SEL sel=NSSelectorFromString(key);return [object respondsToSelector:sel]?((id(*)(id,SEL))objc_msgSend)(object,sel):nil;}
static NSArray *Classes(){return @[(__bridge id)kSecClassGenericPassword,(__bridge id)kSecClassInternetPassword,(__bridge id)kSecClassCertificate,(__bridge id)kSecClassKey,(__bridge id)kSecClassIdentity];}
static NSMutableDictionary *RecordsNow(){NSMutableDictionary *result=[NSMutableDictionary dictionary];for(id cls in Classes()){OSStatus status;BOOL pw=[cls isEqual:(__bridge id)kSecClassGenericPassword]||[cls isEqual:(__bridge id)kSecClassInternetPassword];NSArray *items=ReadItems(cls,pw,&status);Require(status==0||status==errSecItemNotFound,@"keychain read failed");Require(pw||items.count==0,@"unexpected non-password item");result[cls]=ArchiveRecords(items,cls);}return result;}
static NSDictionary *DecodeRecord(NSDictionary *record){Require([record[(__bridge id)kSecAttrAccessGroup] isEqual:Group]&&! [record[(__bridge id)kSecAttrSynchronizable] boolValue],@"record group/sync mismatch");NSMutableDictionary *item=[record mutableCopy];NSData *aclData=item[@"PXArchivedACL"];[item removeObjectForKey:@"PXArchivedACL"];if(aclData){SecAccessControlRef acl=DecodeACL(kCFAllocatorDefault,(__bridge CFDataRef)aclData,NULL);Require(acl!=NULL,@"ACL decode failed");item[(__bridge id)kSecAttrAccessControl]=CFBridgingRelease(acl);[item removeObjectForKey:(__bridge id)kSecAttrAccessible];}return item;}
static void Clear(){for(id cls in Classes()){OSStatus status=SecItemDelete((__bridge CFDictionaryRef)Query(cls));Require(status==0||status==errSecItemNotFound,[NSString stringWithFormat:@"clear failed %d",(int)status]);}for(NSArray *items in RecordsNow().allValues)Require(items.count==0,@"clear verification failed");}
static void AddAll(NSDictionary *records){for(id cls in Classes())for(NSDictionary *r in records[cls]){OSStatus status=SecItemAdd((__bridge CFDictionaryRef)DecodeRecord(r),NULL);Require(status==0,[NSString stringWithFormat:@"restore item failed %d",(int)status]);}}
static BOOL Same(NSDictionary *a,NSDictionary *b){for(id cls in Classes())if(![[NSSet setWithArray:a[cls]] isEqual:[NSSet setWithArray:b[cls]]])return NO;return YES;}
static NSString *Hash(NSString *path){NSInputStream *stream=[NSInputStream inputStreamWithFileAtPath:path];[stream open];CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);uint8_t buf[65536],digest[CC_SHA256_DIGEST_LENGTH];NSInteger n;while((n=[stream read:buf maxLength:sizeof(buf)])>0)CC_SHA256_Update(&ctx,buf,(CC_LONG)n);[stream close];Require(n==0,@"core file unreadable");CC_SHA256_Final(digest,&ctx);NSMutableString *hex=[NSMutableString string];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];return hex;}
static void VerifyCore(NSString *path,NSArray *inventory){NSFileManager *fm=NSFileManager.defaultManager;for(NSDictionary *entry in inventory){NSString *relative=entry[@"path"];if([relative isEqual:@".com.apple.mobile_container_manager.metadata.plist"])continue;NSString *target=[path stringByAppendingPathComponent:relative];Require([fm fileExistsAtPath:target]||[entry[@"type"] isEqual:@"symlink"],@"missing restored path");if(entry[@"sha256"])Require([Hash(target) isEqual:entry[@"sha256"]],@"core hash mismatch");}}
int main(int argc,const char **argv){@autoreleasepool{
 umask(0077);CopyACL=dlsym(RTLD_DEFAULT,"SecAccessControlCopyData");DecodeACL=dlsym(RTLD_DEFAULT,"SecAccessControlCreateFromData");
 NSString *backup=VSTBackupPath();
 NSFileManager *fm=NSFileManager.defaultManager;BOOL changed=NO;
 @try{
 Require(argc<=2,@"unexpected arguments");
 Require(CopyACL&&DecodeACL,@"ACL functions missing");
 NSDictionary *manifest=[NSDictionary dictionaryWithContentsOfFile:[backup stringByAppendingPathComponent:@"manifest.plist"]];Require([manifest[@"status"] isEqual:@"complete"]&&[manifest[@"bundleID"] isEqual:@"lt.manodrabuziai.fr"]&&[manifest[@"accessGroup"] isEqual:Group],@"backup manifest mismatch");
 dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW);Class cls=NSClassFromString(@"LSApplicationProxy");id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,NSSelectorFromString(@"applicationProxyForIdentifier:"),@"lt.manodrabuziai.fr");
 Require([Value(proxy,@"shortVersionString") isEqual:manifest[@"version"]]&&[Value(proxy,@"bundleVersion") isEqual:manifest[@"build"]],@"installed app version differs");
 NSString *data=[Value(proxy,@"dataContainerURL") path],*group=[Value(proxy,@"groupContainerURLs")[@"group.lt.vinted.vinted"] path];
 Require([data hasPrefix:@"/private/var/mobile/Containers/Data/Application/"]&&[group hasPrefix:@"/private/var/mobile/Containers/Shared/AppGroup/"]&&[[NSUUID alloc] initWithUUIDString:data.lastPathComponent]!=nil&&[[NSUUID alloc] initWithUUIDString:group.lastPathComponent]!=nil&&([data.stringByResolvingSymlinksInPath hasPrefix:@"/var/mobile/Containers/Data/Application/"]||[data.stringByResolvingSymlinksInPath hasPrefix:@"/private/var/mobile/Containers/Data/Application/"])&&([group.stringByResolvingSymlinksInPath hasPrefix:@"/var/mobile/Containers/Shared/AppGroup/"]||[group.stringByResolvingSymlinksInPath hasPrefix:@"/private/var/mobile/Containers/Shared/AppGroup/"]),@"container path invalid");
 NSDictionary *dm=[NSDictionary dictionaryWithContentsOfFile:[data stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];NSDictionary *gm=[NSDictionary dictionaryWithContentsOfFile:[group stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];Require([dm[@"MCMMetadataIdentifier"] isEqual:@"lt.manodrabuziai.fr"]&&[gm[@"MCMMetadataIdentifier"] isEqual:@"group.lt.vinted.vinted"],@"container metadata mismatch");
 if(argc==2){Require(strcmp(argv[1],"check")==0,@"expected check argument");for(NSArray *pair in @[@[@"data",data],@[@"app-group",group]]){NSArray *inv=manifest[@"inventories"][[NSString stringWithFormat:@"containers/%@",pair[0]]];Require(inv!=nil,@"inventory missing");VerifyCore(pair[1],inv);}puts("restored_core_files_match=true");return 0;}
 NSMutableDictionary *desired=[NSMutableDictionary dictionary];for(id c in Classes()){NSArray *r=[NSArray arrayWithContentsOfFile:[backup stringByAppendingPathComponent:[NSString stringWithFormat:@"keychain/%@.plist",c]]];Require(r!=nil,@"keychain archive missing");for(NSDictionary *item in r){Require([item[(__bridge id)kSecClass] isEqual:c],@"class mismatch");(void)DecodeRecord(item);}desired[c]=r;}
 NSArray *pairs=@[@[@"data",data],@[@"app-group",group]];
 for(NSArray *pair in pairs){NSString *name=pair[0];NSString *source=[backup stringByAppendingPathComponent:[@"containers/" stringByAppendingString:name]];NSArray *inv=manifest[@"inventories"][[NSString stringWithFormat:@"containers/%@",name]];Require([inv isKindOfClass:NSArray.class],@"inventory missing");struct stat payloadStat;Require(lstat(source.fileSystemRepresentation,&payloadStat)==0&&S_ISDIR(payloadStat.st_mode)&&[fm contentsOfDirectoryAtPath:source error:NULL]!=nil,@"snapshot container missing or unreadable");VerifyCore(source,inv);}
 changed=YES;Clear();puts("keychain_clear_verified=true");
 for(NSArray *pair in pairs){NSString *name=pair[0],*target=pair[1],*source=[backup stringByAppendingPathComponent:[@"containers/" stringByAppendingString:name]];
 NSArray *children=[fm contentsOfDirectoryAtPath:target error:NULL];Require(children!=nil,@"cannot enumerate current container");
 for(NSString *child in children){if([child isEqual:@".com.apple.mobile_container_manager.metadata.plist"])continue;Require([fm removeItemAtPath:[target stringByAppendingPathComponent:child] error:NULL],@"remove current contents failed");}
 children=[fm contentsOfDirectoryAtPath:source error:NULL];Require(children!=nil,@"cannot enumerate snapshot container");
 for(NSString *child in children){if([child isEqual:@".com.apple.mobile_container_manager.metadata.plist"])continue;Require(copyfile([source stringByAppendingPathComponent:child].fileSystemRepresentation,[target stringByAppendingPathComponent:child].fileSystemRepresentation,NULL,COPYFILE_ALL|COPYFILE_RECURSIVE|COPYFILE_NOFOLLOW)==0,@"restore copy failed");}
 NSArray *inv=manifest[@"inventories"][[NSString stringWithFormat:@"containers/%@",name]];VerifyCore(target,inv);
 }
 AddAll(desired);Require(Same(desired,RecordsNow()),@"restored keychain archive mismatch");
 Require([dm isEqual:[NSDictionary dictionaryWithContentsOfFile:[data stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]]]&&[gm isEqual:[NSDictionary dictionaryWithContentsOfFile:[group stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]]],@"container registration changed");
 puts("restore_status=containers-and-keychain-restored-awaiting-IDFV; core_files_verified=true");
 }@catch(NSException *e){fprintf(stderr,"restore failed: %s; state_may_be_partial=%s\n",e.reason.UTF8String,changed?"true":"false");return 1;}
}return 0;}
