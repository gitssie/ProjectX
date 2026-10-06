#import "PXASNative.h"
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <libkern/OSByteOrder.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;

static BOOL Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:PXAppStateErrorDomain code:10 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static id Property(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    return [object respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(object,sel) : nil;
}
static NSString *Physical(NSString *path) {
    char *p = realpath(path.fileSystemRepresentation,NULL); if (!p) return nil;
    NSString *result = @(p); free(p); return result;
}
static BOOL Name(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length > 0 && value.length < 200 &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"].invertedSet].location == NSNotFound;
}
NSArray<NSString *> *PXASKeychainGroupsFromEntitlements(NSDictionary *ent, NSString *bundleID, NSError **error) {
    NSString *appID=ent[@"application-identifier"] ?: ent[@"com.apple.application-identifier"];
    if(!Name(appID) || !Name(bundleID)){Fail(error,@"Invalid signed App identifier");return nil;}
    NSString *team=[appID componentsSeparatedByString:@"."].firstObject;
    if(![appID isEqual:[NSString stringWithFormat:@"%@.%@",team,bundleID]]){Fail(error,@"Signed Team/App identifier mismatch");return nil;}
    NSArray *explicit=ent[@"keychain-access-groups"] ?: @[], *shared=ent[@"com.apple.security.application-groups"] ?: @[];
    if(![explicit isKindOfClass:NSArray.class] || ![shared isKindOfClass:NSArray.class]){Fail(error,@"Invalid signed access groups");return nil;}
    NSMutableOrderedSet *scope=[NSMutableOrderedSet orderedSet];
    for(id group in explicit){
        if(!Name(group) || ![group hasPrefix:[team stringByAppendingString:@"."]]){Fail(error,@"Unsupported signed keychain group");return nil;}
        [scope addObject:group];
    }
    [scope addObject:appID];
    for(id group in shared){
        if(!Name(group) || ![group hasPrefix:@"group."]){Fail(error,@"Unsupported signed App Group");return nil;}
        [scope addObject:group];
    }
    return scope.array;
}
static uint32_t BE32(const unsigned char *bytes) { uint32_t result; memcpy(&result,bytes,4); return OSSwapBigToHostInt32(result); }
// Parse the embedded signed XML entitlement slot, not an Info.plist or caller-supplied group list.
// Installed iOS thin arm64 Mach-O only; unsupported fat/DER-only files fail closed.
static NSDictionary *SignedEntitlements(NSString *executable, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:executable options:NSDataReadingMappedIfSafe error:error];
    if (data.length < sizeof(struct mach_header_64)) { Fail(error,@"Missing signed Mach-O header"); return nil; }
    const unsigned char *bytes = data.bytes; struct mach_header_64 header; memcpy(&header,bytes,sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.sizeofcmds > data.length - sizeof(header)) {
        Fail(error,@"Unsupported installed executable format"); return nil;
    }
    size_t offset = sizeof(header), end = offset + header.sizeofcmds; uint32_t sigOffset = 0, sigSize = 0;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (offset > end || end - offset < sizeof(struct load_command)) { Fail(error,@"Invalid load commands"); return nil; }
        struct load_command command; memcpy(&command,bytes+offset,sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > end-offset) { Fail(error,@"Invalid load command size"); return nil; }
        if (command.cmd == LC_CODE_SIGNATURE && command.cmdsize >= sizeof(struct linkedit_data_command)) {
            struct linkedit_data_command signature; memcpy(&signature,bytes+offset,sizeof(signature)); sigOffset = signature.dataoff; sigSize = signature.datasize;
        }
        offset += command.cmdsize;
    }
    if (sigSize < 12 || sigOffset > data.length || sigSize > data.length-sigOffset) { Fail(error,@"Missing code signature"); return nil; }
    const unsigned char *sig = bytes+sigOffset;
    uint32_t length = BE32(sig+4), count = BE32(sig+8);
    if (BE32(sig) != 0xfade0cc0 || length > sigSize || length < 12 || count > (length-12)/8) { Fail(error,@"Invalid signature superblob"); return nil; }
    for (uint32_t i = 0; i < count; i++) {
        uint32_t type = BE32(sig+12+i*8), at = BE32(sig+16+i*8);
        if (type != 5) continue;
        if (at > length || length-at < 8) break;
        uint32_t size = BE32(sig+at+4);
        if (BE32(sig+at) != 0xfade7171 || size < 8 || size > length-at) break;
        NSData *xml = [NSData dataWithBytes:sig+at+8 length:size-8];
        id object = [NSPropertyListSerialization propertyListWithData:xml options:NSPropertyListImmutable format:NULL error:error];
        if ([object isKindOfClass:NSDictionary.class]) return object;
        break;
    }
    Fail(error,@"Signed XML entitlements unavailable"); return nil;
}
@implementation PXASLaunchServicesResolver
- (NSDictionary *)resolve:(NSString *)bundleID error:(NSError **)error {
    if (!Name(bundleID)) { Fail(error,@"Invalid Bundle ID"); return nil; }
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW);
    Class cls = NSClassFromString(@"LSApplicationProxy"); SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!cls || ![cls respondsToSelector:sel]) { Fail(error,@"LaunchServices proxy unavailable"); return nil; }
    id proxy = ((id(*)(id,SEL,id))objc_msgSend)(cls,sel,bundleID);
    NSString *bundle = Physical([Property(proxy,@"bundleURL") path]);
    NSString *data = Physical([Property(proxy,@"dataContainerURL") path]);
    if (![bundle hasPrefix:@"/private/var/containers/Bundle/Application/"] ||
        ![data hasPrefix:@"/private/var/mobile/Containers/Data/Application/"]) { Fail(error,@"Target containers unavailable"); return nil; }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exe = info[@"CFBundleExecutable"];
    if (![info[@"CFBundleIdentifier"] isEqual:bundleID] || !Name(exe)) { Fail(error,@"Bundle identity mismatch"); return nil; }
    NSDictionary *ent = SignedEntitlements([bundle stringByAppendingPathComponent:exe],error); if (!ent) return nil;
    NSString *appID = ent[@"application-identifier"] ?: ent[@"com.apple.application-identifier"];
    NSString *team = [[appID componentsSeparatedByString:@"."] firstObject];
    if (!Name(team) || ![appID isEqual:[NSString stringWithFormat:@"%@.%@",team,bundleID]]) { Fail(error,@"Signed Team/App identifier mismatch"); return nil; }
    NSArray *groups=PXASKeychainGroupsFromEntitlements(ent,bundleID,error);if(!groups)return nil;
    NSMutableDictionary *containers = [NSMutableDictionary dictionaryWithObject:data forKey:@"data"];
    NSDictionary *urls = Property(proxy,@"groupContainerURLs") ?: @{};
    NSArray *appGroups = ent[@"com.apple.security.application-groups"] ?: @[];
    if (![appGroups isKindOfClass:NSArray.class]) { Fail(error,@"Invalid signed App Groups"); return nil; }
    for (NSString *group in appGroups) {
        NSString *path = Physical([urls[group] path]);
        if (!Name(group) || ![path hasPrefix:@"/private/var/mobile/Containers/Shared/AppGroup/"]) { Fail(error,@"Declared App Group cannot be resolved"); return nil; }
        containers[[ @"group-" stringByAppendingString:group]] = path;
    }
    return @{@"bundleID":bundleID,@"version":info[@"CFBundleShortVersionString"] ?: @"",@"build":info[@"CFBundleVersion"] ?: @"",
        @"executable":exe,@"bundlePath":bundle,@"containers":containers,@"keychainGroups":groups,@"applicationIdentifier":appID,
        @"signedEntitlements":ent,@"vendorName":Property(proxy,@"vendorName") ?: @"",@"IDFV":[Property(proxy,@"deviceIdentifierForVendor") description] ?: @""};
}
- (BOOL)assertStopped:(NSDictionary *)target error:(NSError **)error {
    int mib[] = {CTL_KERN,KERN_PROC,KERN_PROC_ALL,0}; size_t size = 0;
    if (sysctl(mib,4,NULL,&size,NULL,0) != 0) return Fail(error,@"Cannot enumerate processes");
    NSMutableData *data = [NSMutableData dataWithLength:size+sizeof(struct kinfo_proc)*64]; size = data.length;
    if (sysctl(mib,4,data.mutableBytes,&size,NULL,0) != 0) return Fail(error,@"Process list changed; retry inspection");
    int (*processPath)(int,void *,uint32_t) = dlsym(RTLD_DEFAULT,"proc_pidpath");
    if (!processPath) return Fail(error,@"Process path API unavailable");
    const struct kinfo_proc *processes = data.bytes; NSString *bundle = target[@"bundlePath"];
    for (NSUInteger i = 0; i < size/sizeof(struct kinfo_proc); i++) {
        if (processes[i].kp_proc.p_pid <= 0 || processes[i].kp_eproc.e_ucred.cr_uid != 501) continue;
        char path[4096] = {0};
        if (processPath(processes[i].kp_proc.p_pid,path,sizeof(path)) <= 0) {
            // A disappearing process is harmless; an inaccessible extant process cannot be proven outside scope.
            if (kill(processes[i].kp_proc.p_pid,0) == 0) return Fail(error,@"Cannot inspect a live process path");
            continue;
        }
        NSString *physical = Physical(@(path));
        if ([physical hasPrefix:[bundle stringByAppendingString:@"/"]]) return Fail(error,@"Target app or extension is running");
    }
    return YES;
}
@end

@interface PXASVendorIdentity ()
@property (nonatomic, copy, nullable) NSArray<NSString *> *command;
@property (nonatomic, copy, nullable) NSString *systemPlist;
@end
@implementation PXASVendorIdentity
- (instancetype)initWithPrivilegedCommand:(NSArray<NSString *> *)command systemPlist:(NSString *)systemPlist {
    self = [super init]; if (self) { _command = [command copy]; _systemPlist = [systemPlist copy]; } return self;
}
- (NSDictionary *)capture:(NSDictionary *)target error:(NSError **)error {
    PXASLaunchServicesResolver *resolver = [PXASLaunchServicesResolver new];
    NSDictionary *fresh = [resolver resolve:target[@"bundleID"] error:error];
    if (!fresh || ![[NSUUID alloc] initWithUUIDString:fresh[@"IDFV"]] || [fresh[@"vendorName"] length] == 0) {
        Fail(error,@"Cannot capture current vendor identity"); return nil;
    }
    return @{@"bundleID":fresh[@"bundleID"],@"vendorName":fresh[@"vendorName"],@"IDFV":fresh[@"IDFV"]};
}
- (BOOL)validateState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error {
    if (![state[@"bundleID"] isEqual:target[@"bundleID"]] || ![state[@"vendorName"] isEqual:target[@"vendorName"]] ||
        ![[NSUUID alloc] initWithUUIDString:state[@"IDFV"]]) return Fail(error,@"Vendor identity scope differs");
    if (self.command.count == 0 || ![self.command[0] isAbsolutePath] || !self.systemPlist ||
        ![self.systemPlist hasPrefix:@"/private/var/containers/Shared/SystemGroup/"] ||
        ![self.systemPlist hasSuffix:@"/Library/Caches/com.apple.lsdidentifiers.plist"] ||
        [self.systemPlist containsString:@".."] || access(self.command[0].fileSystemRepresentation,X_OK) != 0)
        return Fail(error,@"IDFV restore requires an explicit signed worker command and system plist");
    return [self invokeWorker:state target:target checkOnly:YES error:error];
}
- (BOOL)invokeWorker:(NSDictionary *)state target:(NSDictionary *)target checkOnly:(BOOL)checkOnly error:(NSError **)error {
    NSDictionary *before = [self capture:target error:error]; if (!before) return NO;
    NSMutableArray *args = [self.command mutableCopy];
    if (checkOnly) [args addObject:@"--check"];
    [args addObjectsFromArray:@[self.systemPlist,state[@"vendorName"],state[@"bundleID"],before[@"IDFV"],state[@"IDFV"]]];
    char **argv = calloc(args.count+1,sizeof(char *)); if (!argv) return Fail(error,@"Cannot allocate worker arguments");
    for (NSUInteger i=0;i<args.count;i++) argv[i]=strdup([args[i] UTF8String]);
    pid_t pid = 0; int status = posix_spawn(&pid,argv[0],NULL,NULL,argv,environ);
    for(NSUInteger i=0;i<args.count;i++)free(argv[i]); free(argv);
    if(status!=0)return Fail(error,@"IDFV worker could not start");
    int result=0; pid_t waited; do { waited=waitpid(pid,&result,0); } while(waited<0&&errno==EINTR);
    if(waited!=pid)return Fail(error,@"Cannot wait for the IDFV helper");
    if(WIFSIGNALED(result))return Fail(error,[NSString stringWithFormat:@"IDFV helper terminated by signal %d",WTERMSIG(result)]);
    if(!WIFEXITED(result)||WEXITSTATUS(result)!=0) {
        int code=WIFEXITED(result)?WEXITSTATUS(result):-1;
        NSString *detail=code==1?@"noninteractive root authorization failed; reinstall ProjectX to refresh the helper rule":
            (code==64?@"helper arguments or root identity invalid":(code==65?@"identity path or UUID invalid":
            (code==66?@"mobile lsd process unavailable":(code==67?@"vendor membership or current IDFV changed":@"helper execution failed"))));
        return Fail(error,[NSString stringWithFormat:@"IDFV helper failed (%d): %@",code,detail]);
    }
    if (checkOnly) return YES;
    // The worker terminates mobile lsd after writing. Its replacement and the
    // LaunchServices connection may not be ready when waitpid returns.
    // Require the API to converge; never accept the disk value alone.
    for (NSUInteger attempt=0;attempt<20;attempt++) {
        NSError *readError=nil;
        NSDictionary *readback=[self capture:target error:&readError];
        if ([readback isEqual:state]) return YES;
        if (attempt<19) usleep(100000);
    }
    return Fail(error,@"System IDFV readback differs");
}
- (BOOL)restoreState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error {
    if (![self validateState:state target:target error:error]) return NO;
    return [self invokeWorker:state target:target checkOnly:NO error:error];
}
@end

@interface PXASSecurityKeychain ()
@property (nonatomic, copy) NSString *applicationIdentifier;
@end
@implementation PXASSecurityKeychain
- (instancetype)initWithApplicationIdentifier:(NSString *)applicationIdentifier {
    self = [super init]; if (self) _applicationIdentifier = [applicationIdentifier copy]; return self;
}
- (BOOL)authority:(NSArray *)groups error:(NSError **)error {
    CFTypeRef (*create)(CFAllocatorRef) = dlsym(RTLD_DEFAULT,"SecTaskCreateFromSelf");
    CFTypeRef (*copy)(CFTypeRef,CFStringRef,CFErrorRef *) = dlsym(RTLD_DEFAULT,"SecTaskCopyValueForEntitlement");
    if (!create || !copy) return Fail(error,@"Cannot inspect worker authority");
    CFTypeRef task = create(kCFAllocatorDefault); if (!task) return Fail(error,@"Cannot create entitlement task");
    CFTypeRef app = copy(task,CFSTR("application-identifier"),NULL);
    CFTypeRef grps = copy(task,CFSTR("keychain-access-groups"),NULL);
    CFTypeRef shared = copy(task,CFSTR("com.apple.security.application-groups"),NULL); CFRelease(task);
    id appID = app?CFBridgingRelease(app):nil; id actual = grps?CFBridgingRelease(grps):@[];
    id appGroups=shared?CFBridgingRelease(shared):@[];
    if(![appGroups isKindOfClass:NSArray.class])return Fail(error,@"Invalid worker App Groups");
    if (groups.count == 0) return [actual count] == 0 || Fail(error,@"Unexpected worker groups");
    NSString *team = [self.applicationIdentifier componentsSeparatedByString:@"."].firstObject;
    for (NSString *group in groups) if (!Name(group) ||
        !([group hasPrefix:[team stringByAppendingString:@"."]] ||
          ([group hasPrefix:@"group."] && [appGroups containsObject:group]))) return Fail(error,@"Unsafe group scope");
    return ([appID isEqual:self.applicationIdentifier] && [actual isKindOfClass:NSArray.class] &&
        [actual count] == groups.count && [[NSSet setWithArray:actual] isEqual:[NSSet setWithArray:groups]]) || Fail(error,@"Worker must have exactly the signed target authority");
}
- (NSArray *)classes { return @[(__bridge id)kSecClassGenericPassword,(__bridge id)kSecClassInternetPassword,
    (__bridge id)kSecClassCertificate,(__bridge id)kSecClassKey,(__bridge id)kSecClassIdentity]; }
- (NSArray *)writableKeys { return @[(__bridge id)kSecClass,(__bridge id)kSecAttrAccount,(__bridge id)kSecAttrService,
    (__bridge id)kSecAttrServer,(__bridge id)kSecAttrPort,(__bridge id)kSecAttrProtocol,(__bridge id)kSecAttrAuthenticationType,
    (__bridge id)kSecAttrSecurityDomain,(__bridge id)kSecAttrPath,(__bridge id)kSecAttrAccessGroup,(__bridge id)kSecAttrAccessible,
    (__bridge id)kSecAttrSynchronizable,(__bridge id)kSecAttrLabel,(__bridge id)kSecAttrDescription,(__bridge id)kSecAttrComment,
    (__bridge id)kSecAttrGeneric,(__bridge id)kSecAttrCreator,(__bridge id)kSecAttrType,(__bridge id)kSecAttrIsInvisible,
    (__bridge id)kSecAttrIsNegative,(__bridge id)kSecValueData,@"PXArchivedACL"]; }
- (NSMutableDictionary *)query:(id)cls group:(NSString *)group {
    LAContext *context = [LAContext new]; context.interactionNotAllowed = YES;
    return [@{(__bridge id)kSecClass:cls,(__bridge id)kSecAttrAccessGroup:group,
        (__bridge id)kSecAttrSynchronizable:@NO,(__bridge id)kSecUseAuthenticationContext:context} mutableCopy];
}
// Small system-call boundary also used by deterministic adapter tests.
- (OSStatus)copyMatching:(NSDictionary *)query result:(CFTypeRef *)result {
    return SecItemCopyMatching((__bridge CFDictionaryRef)query,result);
}
- (OSStatus)addItem:(NSDictionary *)item { return SecItemAdd((__bridge CFDictionaryRef)item,NULL); }
- (OSStatus)deleteQuery:(NSDictionary *)query { return SecItemDelete((__bridge CFDictionaryRef)query); }
- (OSStatus)updateQuery:(NSDictionary *)query attributes:(NSDictionary *)attributes {
    return SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)attributes);
}
- (NSArray *)identityKeys:(NSDictionary *)record {
    if ([record[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword])
        return @[(__bridge id)kSecAttrService,(__bridge id)kSecAttrAccount];
    return @[(__bridge id)kSecAttrAccount,(__bridge id)kSecAttrSecurityDomain,(__bridge id)kSecAttrServer,
        (__bridge id)kSecAttrProtocol,(__bridge id)kSecAttrAuthenticationType,(__bridge id)kSecAttrPort,(__bridge id)kSecAttrPath];
}
- (NSDictionary *)recordIdentity:(NSDictionary *)record {
    NSMutableDictionary *result=[@{(__bridge id)kSecClass:record[(__bridge id)kSecClass],
        (__bridge id)kSecAttrAccessGroup:record[(__bridge id)kSecAttrAccessGroup],
        (__bridge id)kSecAttrSynchronizable:@([record[(__bridge id)kSecAttrSynchronizable] boolValue])} mutableCopy];
    for (id key in [self identityKeys:record]) result[key]=record[key] ?: ([key isEqual:(__bridge id)kSecAttrPort]?@0:@"");
    return result;
}
- (NSArray *)exportGroups:(NSArray *)groups error:(NSError **)error {
    if (![self authority:groups error:error]) return nil;
    CFDataRef (*copyACL)(SecAccessControlRef) = dlsym(RTLD_DEFAULT,"SecAccessControlCopyData");
    NSMutableArray *records = [NSMutableArray array];
    for (NSString *group in groups) for (id cls in self.classes) {
        BOOL password = [cls isEqual:(__bridge id)kSecClassGenericPassword] || [cls isEqual:(__bridge id)kSecClassInternetPassword];
        NSMutableDictionary *q = [self query:cls group:group];
        q[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        q[(__bridge id)kSecReturnAttributes] = @YES;
        q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll; if (password) q[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef result = NULL; OSStatus status = [self copyMatching:q result:&result];
        if (status == errSecItemNotFound) continue;
        if (status != errSecSuccess) { if(result)CFRelease(result); Fail(error,[NSString stringWithFormat:@"Keychain read failed (%d)",(int)status]); return nil; }
        id objects = CFBridgingRelease(result); NSArray *items = [objects isKindOfClass:NSArray.class]?objects:@[objects];
        if (!password && items.count) { Fail(error,@"Non-password keychain records are unsupported"); return nil; }
        for (NSDictionary *item in items) {
            NSMutableDictionary *record = [NSMutableDictionary dictionary];
            for (id key in self.writableKeys) if (item[key]) record[key] = item[key];
            record[(__bridge id)kSecClass] = cls; record[(__bridge id)kSecAttrAccessGroup] = group;
            id synchronizable=item[(__bridge id)kSecAttrSynchronizable];
            record[(__bridge id)kSecAttrSynchronizable] = synchronizable ?: @NO;
            id acl = item[(__bridge id)kSecAttrAccessControl];
            if (acl) { CFDataRef bytes = copyACL?copyACL((__bridge SecAccessControlRef)acl):NULL;
                if (!bytes) { Fail(error,@"Cannot archive access-control protection"); return nil; } record[@"PXArchivedACL"] = CFBridgingRelease(bytes); }
            [records addObject:record];
        }
    }
    return [self validateRecords:records groups:groups error:error]?records:nil;
}
- (NSDictionary *)decode:(NSDictionary *)record error:(NSError **)error {
    NSMutableDictionary *item = [record mutableCopy]; NSData *bytes = item[@"PXArchivedACL"]; [item removeObjectForKey:@"PXArchivedACL"];
    // Keep archive representation intact; Security input uses CFBoolean values.
    for(id key in @[(__bridge id)kSecAttrSynchronizable,(__bridge id)kSecAttrIsInvisible,(__bridge id)kSecAttrIsNegative])
        if(item[key])item[key]=@([item[key] boolValue]);
    if (bytes) {
        SecAccessControlRef (*decode)(CFAllocatorRef,CFDataRef,CFErrorRef *) = dlsym(RTLD_DEFAULT,"SecAccessControlCreateFromData");
        SecAccessControlRef acl = decode?decode(kCFAllocatorDefault,(__bridge CFDataRef)bytes,NULL):NULL;
        if (!acl) { Fail(error,@"Cannot decode archived access control"); return nil; }
        item[(__bridge id)kSecAttrAccessControl] = CFBridgingRelease(acl); [item removeObjectForKey:(__bridge id)kSecAttrAccessible];
    }
    return item;
}
- (BOOL)validateRecords:(NSArray *)records groups:(NSArray *)groups error:(NSError **)error {
    if (![records isKindOfClass:NSArray.class] || ![self authority:groups error:error]) return NO;
    NSMutableSet *identities=[NSMutableSet set];
    for (NSDictionary *record in records) {
        if (![record isKindOfClass:NSDictionary.class] || ![groups containsObject:record[(__bridge id)kSecAttrAccessGroup]] ||
            ![record[(__bridge id)kSecAttrSynchronizable] isKindOfClass:NSNumber.class] ||
            ![@[@NO,@YES] containsObject:record[(__bridge id)kSecAttrSynchronizable]] ||
            ![@[(__bridge id)kSecClassGenericPassword,(__bridge id)kSecClassInternetPassword] containsObject:record[(__bridge id)kSecClass]] ||
            ![record[(__bridge id)kSecValueData] isKindOfClass:NSData.class]) return Fail(error,@"Keychain record scope or class is invalid");
        for (id key in record) if (![self.writableKeys containsObject:key]) return Fail(error,@"Unexpected keychain archive attribute");
        for(id key in @[(__bridge id)kSecAttrAccount,(__bridge id)kSecAttrService,(__bridge id)kSecAttrServer,
            (__bridge id)kSecAttrSecurityDomain,(__bridge id)kSecAttrPath,(__bridge id)kSecAttrProtocol,
            (__bridge id)kSecAttrAuthenticationType,(__bridge id)kSecAttrAccessible,(__bridge id)kSecAttrLabel,
            (__bridge id)kSecAttrDescription,(__bridge id)kSecAttrComment])
            if(record[key] && ![record[key] isKindOfClass:NSString.class])return Fail(error,@"Invalid keychain string attribute");
        for(id key in @[(__bridge id)kSecAttrPort,(__bridge id)kSecAttrCreator,(__bridge id)kSecAttrType]){
            id value=record[key];if(!value)continue;
            if(![value isKindOfClass:NSNumber.class] || [value doubleValue]!=[value unsignedIntValue] ||
                ([key isEqual:(__bridge id)kSecAttrPort] && [value unsignedIntValue]>65535))
                return Fail(error,@"Invalid keychain numeric attribute");
        }
        for(id key in @[(__bridge id)kSecAttrIsInvisible,(__bridge id)kSecAttrIsNegative])
            if(record[key] && (![record[key] isKindOfClass:NSNumber.class] || ![@[@NO,@YES] containsObject:record[key]]))
                return Fail(error,@"Invalid keychain boolean attribute");
        // Existing device records may store a string here; preserve it exactly.
        if(record[(__bridge id)kSecAttrGeneric] && ![record[(__bridge id)kSecAttrGeneric] isKindOfClass:NSData.class] &&
            ![record[(__bridge id)kSecAttrGeneric] isKindOfClass:NSString.class])
            return Fail(error,@"Invalid keychain generic attribute");
        NSString *accessible=record[(__bridge id)kSecAttrAccessible];
        if(accessible && ![@[@"ak",@"ck",@"dk",@"aku",@"cku",@"dku",@"akpu"] containsObject:accessible])
            return Fail(error,@"Unsupported keychain accessibility");
        if([record[(__bridge id)kSecAttrSynchronizable] boolValue] && [accessible hasSuffix:@"u"])
            return Fail(error,@"Synchronizable records cannot use ThisDeviceOnly protection");
        BOOL generic=[record[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword];
        for(id key in @[(__bridge id)kSecAttrServer,(__bridge id)kSecAttrPort,(__bridge id)kSecAttrProtocol,
            (__bridge id)kSecAttrAuthenticationType,(__bridge id)kSecAttrSecurityDomain,(__bridge id)kSecAttrPath])
            if(generic && record[key])return Fail(error,@"Internet attribute on generic-password record");
        if(!generic && (record[(__bridge id)kSecAttrService] || record[(__bridge id)kSecAttrGeneric]))
            return Fail(error,@"Generic attribute on internet-password record");
        if (record[@"PXArchivedACL"] && ![record[@"PXArchivedACL"] isKindOfClass:NSData.class]) return Fail(error,@"Invalid ACL archive");
        if (![self decode:record error:error]) return NO;
        NSDictionary *identity=[self recordIdentity:record];
        if ([identities containsObject:identity]) return Fail(error,@"Duplicate keychain record identity");
        [identities addObject:identity];
    }
    return YES;
}
- (BOOL)validateReplacement:(NSArray *)records groups:(NSArray *)groups error:(NSError **)error {
    if (![self validateRecords:records groups:groups error:error]) return NO;
    NSArray *current=[self exportGroups:groups error:error]; if(!current)return NO;
    NSMutableDictionary *desired=[NSMutableDictionary dictionary];
    for(NSDictionary *record in records)desired[[self recordIdentity:record]]=record;
    for(NSDictionary *record in current){
        if(![record[(__bridge id)kSecAttrSynchronizable] boolValue])continue;
        NSDictionary *saved=desired[[self recordIdentity:record]];
        if(!saved)continue; // Explicit snapshot restore removes target-scope items absent from its archive.
        for(id key in @[(__bridge id)kSecAttrAccessible,@"PXArchivedACL"])
            if((record[key] || saved[key]) && ![record[key] isEqual:saved[key]])
                return Fail(error,@"Synchronizable keychain protection differs; refusing destructive replacement");
        NSMutableDictionary *item=[[self decode:saved error:error] mutableCopy];if(!item)return NO;
        NSDictionary *identity=[self recordIdentity:record];
        for(id key in record)if(!item[key] && ![key isEqual:@"PXArchivedACL"] && !identity[key] &&
            ![key isEqual:(__bridge id)kSecAttrAccessible])
            return Fail(error,@"Synchronizable keychain attribute removal is unsupported");
    }
    return YES;
}
- (NSArray *)supplementSynchronizableRecords:(NSArray *)records groups:(NSArray *)groups error:(NSError **)error {
    if(![self validateRecords:records groups:groups error:error])return nil;
    NSArray *current=[self exportGroups:groups error:error];if(!current)return nil;
    NSMutableArray *oldLocal=[NSMutableArray array],*liveLocal=[NSMutableArray array],*merged=[NSMutableArray array];
    for(NSDictionary *record in records)if(![record[(__bridge id)kSecAttrSynchronizable] boolValue])[oldLocal addObject:record];
    for(NSDictionary *record in current){
        if([record[(__bridge id)kSecAttrSynchronizable] boolValue])[merged addObject:record];
        else [liveLocal addObject:record];
    }
    if(oldLocal.count!=liveLocal.count || ![[NSSet setWithArray:oldLocal] isEqual:[NSSet setWithArray:liveLocal]]){
        Fail(error,@"Current nonsynchronizable records differ from snapshot; capture a new snapshot instead");return nil;
    }
    [merged addObjectsFromArray:oldLocal];return [self validateRecords:merged groups:groups error:error]?merged:nil;
}
- (BOOL)replaceGroups:(NSArray *)groups records:(NSArray *)records error:(NSError **)error {
    if (![self validateReplacement:records groups:groups error:error]) return NO;
    NSArray *current=[self exportGroups:groups error:error]; if(!current)return NO;
    NSMutableDictionary *live=[NSMutableDictionary dictionary];
    for(NSDictionary *record in current)live[[self recordIdentity:record]]=record;
    NSMutableSet *desired=[NSMutableSet set];for(NSDictionary *record in records)[desired addObject:[self recordIdentity:record]];
    for(NSDictionary *record in current){
        NSDictionary *identity=[self recordIdentity:record];
        if(![record[(__bridge id)kSecAttrSynchronizable] boolValue] || [desired containsObject:identity])continue;
        NSMutableDictionary *query=[identity mutableCopy];
        query[(__bridge id)kSecUseAuthenticationContext]=[self query:record[(__bridge id)kSecClass] group:record[(__bridge id)kSecAttrAccessGroup]][(__bridge id)kSecUseAuthenticationContext];
        OSStatus status=[self deleteQuery:query];
        if(status!=errSecSuccess && status!=errSecItemNotFound)return Fail(error,[NSString stringWithFormat:@"Snapshot extra synchronizable keychain clear failed (%d)",(int)status]);
    }
    for (NSString *group in groups) for (id cls in self.classes) {
        OSStatus status = [self deleteQuery:[self query:cls group:group]];
        if (status != 0 && status != errSecItemNotFound) return Fail(error,@"Keychain clear failed");
    }
    NSArray *empty = [self exportGroups:groups error:error]; if (!empty)return NO;
    for(NSDictionary *record in empty)if(![record[(__bridge id)kSecAttrSynchronizable] boolValue])return Fail(error,@"Keychain clear verification failed");
    for(NSDictionary *record in empty)if(![desired containsObject:[self recordIdentity:record]])return Fail(error,@"Extra synchronizable keychain record remains after clear");
    for (NSDictionary *record in records) {
        NSDictionary *item = [self decode:record error:error]; if (!item) return NO;
        NSDictionary *old=live[[self recordIdentity:record]];
        OSStatus status;
        if([record[(__bridge id)kSecAttrSynchronizable] boolValue] && old){
            if([old isEqual:record])continue;
            NSMutableDictionary *query=[[self recordIdentity:record] mutableCopy];
            query[(__bridge id)kSecUseAuthenticationContext]=[self query:record[(__bridge id)kSecClass] group:record[(__bridge id)kSecAttrAccessGroup]][(__bridge id)kSecUseAuthenticationContext];
            NSMutableDictionary *attributes=[item mutableCopy];
            for(id key in query)[attributes removeObjectForKey:key];
            [attributes removeObjectForKey:(__bridge id)kSecAttrAccessible];
            [attributes removeObjectForKey:(__bridge id)kSecAttrAccessControl];
            status=[self updateQuery:query attributes:attributes];
        }else status=[self addItem:item];
        if (status != 0) return Fail(error,[NSString stringWithFormat:@"Keychain restore failed (%d)",(int)status]);
    }
    NSArray *readback = [self exportGroups:groups error:error];
    return (readback && readback.count == records.count && [[NSSet setWithArray:readback] isEqual:[NSSet setWithArray:records]]) || Fail(error,@"Keychain content/ACL readback differs");
}
- (BOOL)validateBaselineResetGroups:(NSArray *)groups error:(NSError **)error {
    return [self exportGroups:groups error:error]!=nil;
}
- (BOOL)resetGroupsForBaseline:(NSArray *)groups error:(NSError **)error {
    NSArray *current=[self exportGroups:groups error:error];if(!current)return NO;
    // Synchronizable deletion is explicit baseline behavior, never a broad query.
    for(NSDictionary *record in current){
        if(![record[(__bridge id)kSecAttrSynchronizable] boolValue])continue;
        NSMutableDictionary *query=[[self recordIdentity:record] mutableCopy];
        query[(__bridge id)kSecUseAuthenticationContext]=[self query:record[(__bridge id)kSecClass] group:record[(__bridge id)kSecAttrAccessGroup]][(__bridge id)kSecUseAuthenticationContext];
        OSStatus status=[self deleteQuery:query];
        if(status!=errSecSuccess && status!=errSecItemNotFound)
            return Fail(error,[NSString stringWithFormat:@"Baseline synchronizable keychain clear failed (%d)",(int)status]);
    }
    for(NSString *group in groups)for(id cls in self.classes){
        OSStatus status=[self deleteQuery:[self query:cls group:group]];
        if(status!=errSecSuccess && status!=errSecItemNotFound)return Fail(error,@"Baseline keychain clear failed");
    }
    NSArray *after=[self exportGroups:groups error:error];
    return (after && after.count==0) || Fail(error,@"Baseline keychain readback is not empty");
}
@end

@interface PXASBlockIdentity ()
@property (nonatomic, copy) NSDictionary * (^captureBlock)(NSDictionary *,NSError **);
@property (nonatomic, copy) BOOL (^validateBlock)(NSDictionary *,NSDictionary *,NSError **);
@property (nonatomic, copy) BOOL (^restoreBlock)(NSDictionary *,NSDictionary *,NSError **);
@end
@implementation PXASBlockIdentity
- (instancetype)initWithCapture:(NSDictionary *(^)(NSDictionary *,NSError **))capture
    validate:(BOOL (^)(NSDictionary *,NSDictionary *,NSError **))validate restore:(BOOL (^)(NSDictionary *,NSDictionary *,NSError **))restore {
    self = [super init]; if (self) { _captureBlock = [capture copy]; _validateBlock = [validate copy]; _restoreBlock = [restore copy]; } return self;
}
- (NSDictionary *)capture:(NSDictionary *)target error:(NSError **)error { return self.captureBlock(target,error); }
- (BOOL)validateState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error { return self.validateBlock(state,target,error); }
- (BOOL)restoreState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error { return self.restoreBlock(state,target,error); }
@end
