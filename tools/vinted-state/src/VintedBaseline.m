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
    if (argc!=2) Fail(@"destination missing");
    NSString *base=@(argv[1]);
    if (!([base hasPrefix:@"/private/var/mobile/Media/VintedBackups/baselines/"] && ![base containsString:@".."] && [base componentsSeparatedByString:@"/"].count == 8)) Fail(@"invalid destination");
    NSFileManager *fm=[NSFileManager defaultManager]; NSError *error=nil;
    if ([fm fileExistsAtPath:base]) Fail(@"destination already exists");
    if (![fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) Fail([error description]);
    for (NSString *dir in @[@"application",@"containers"]) if (![fm createDirectoryAtPath:[base stringByAppendingPathComponent:dir] withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error]) Fail([error description]);
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

    if (![info[@"CFBundleShortVersionString"] isEqual:base.lastPathComponent]) Fail(@"baseline version mismatch");
    NSDictionary *policy=@{@"keychain":@{@"included":@NO,@"desiredState":@"empty",@"accessGroup":@"4Y2CNF6C99.com.vinted.keychain-group",@"existingDeviceRecordsModified":@NO,@"scope":@"nonsynchronizable items only",@"firstLaunch":@"App may create its own items; actual behavior has not been observed"},@"IDFV":@{@"included":@NO,@"restoreSavedValue":@NO,@"policy":@"manage separately for each initialization; not a fixed value from this baseline"},@"containerUUIDs":@"resolve current target bundle and app-group containers; never restore UUID metadata blindly"};
    NSDictionary *manifest=@{@"formatVersion":@1,@"type":@"pre-first-launch-baseline",@"name":info[@"CFBundleShortVersionString"],@"status":@"complete",@"createdUTC":[[NSDate date] description],@"bundleID":@"lt.manodrabuziai.fr",@"version":info[@"CFBundleShortVersionString"],@"build":info[@"CFBundleVersion"],@"copies":copyReports,@"inventories":inventories,@"initializationPolicy":policy,@"keychainIncluded":@NO,@"identityValuesIncluded":@NO,@"originalItemsModified":@NO,@"firstLaunchState":@"user confirmed app has never been launched since reinstall; no Vinted process found",@"scope":@"installed application bundle, pristine data container and shared container; excludes keychain, IDFV values and server state",@"verificationPolicy":@"core hashes and container identities; other files inventory only"};
    WritePlist(manifest,[base stringByAppendingPathComponent:@"manifest.plist"]);
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"baseline":base,@"keychainIncluded":@NO,@"fixedIdentityIncluded":@NO,@"copies":copyReports} options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes,1,json.length,stdout); puts("");
 }
 return 0;
}
