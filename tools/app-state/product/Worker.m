#import "../core/PXAppStateSession.h"
#import "../adapters/PXASNative.h"
#import "../../../PXRootHidePath.h"
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>

static BOOL Failed(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:PXAppStateErrorDomain code:40 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *Physical(NSString *path) {
    char *p=realpath(path.fileSystemRepresentation,NULL); if (!p) return nil;
    NSString *result=@(p); free(p); return result;
}
static BOOL Stop(PXASLaunchServicesResolver *resolver, NSDictionary *target, NSError **error) {
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0}; size_t length=0;
    if (sysctl(mib,4,NULL,&length,NULL,0)!=0) return Failed(error,@"Cannot enumerate target processes");
    NSMutableData *data=[NSMutableData dataWithLength:length+sizeof(struct kinfo_proc)*64]; length=data.length;
    if (sysctl(mib,4,data.mutableBytes,&length,NULL,0)!=0) return Failed(error,@"Process list changed; retry");
    int (*pathfn)(int,void *,uint32_t)=dlsym(RTLD_DEFAULT,"proc_pidpath");
    if (!pathfn) return Failed(error,@"Process path API unavailable");
    const struct kinfo_proc *ps=data.bytes; NSString *prefix=[target[@"bundlePath"] stringByAppendingString:@"/"];
    for (NSUInteger i=0;i<length/sizeof(struct kinfo_proc);i++) {
        pid_t pid=ps[i].kp_proc.p_pid;
        if (ps[i].kp_eproc.e_ucred.cr_uid!=501 || pid<=0) continue;
        char path[4096]={0};
        if (pathfn(pid,path,sizeof(path))<=0) {
            if (kill(pid,0)==0) return Failed(error,@"Cannot inspect a live process");
            continue;
        }
        if (![Physical(@(path)) hasPrefix:prefix]) continue;
        // Check again immediately before signaling, rather than trusting a stale PID.
        memset(path,0,sizeof(path));
        if (pathfn(pid,path,sizeof(path))>0 && [Physical(@(path)) hasPrefix:prefix] && kill(pid,SIGKILL)!=0 && errno!=ESRCH)
            return Failed(error,@"Cannot stop target app or extension");
    }
    for (NSUInteger i=0;i<80;i++) { if ([resolver assertStopped:target error:NULL]) return YES; usleep(50000); }
    return [resolver assertStopped:target error:error];
}
static NSString *LSDPlist(void) {
    NSString *parent=PXAppStateSystemGroupsPath();
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:parent error:NULL]) {
        NSString *root=[parent stringByAppendingPathComponent:name];
        NSDictionary *metadata=[NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([metadata[@"MCMMetadataIdentifier"] isEqual:@"systemgroup.com.apple.lsd"])
            return Physical([root stringByAppendingPathComponent:@"Library/Caches/com.apple.lsdidentifiers.plist"]);
    }
    return nil;
}
static NSDictionary *PreferenceDomains(NSDictionary *target) {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for (NSString *containerID in target[@"containers"]) {
        NSString *root=target[@"containers"][containerID];
        NSMutableSet *domains=[NSMutableSet set];
        if ([containerID isEqual:@"data"]) [domains addObject:target[@"bundleID"]];
        for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"Library/Preferences"] error:NULL])
            if ([file.pathExtension isEqual:@"plist"]) [domains addObject:file.stringByDeletingPathExtension];
        result[containerID]=domains.allObjects;
    }
    return result;
}
static BOOL RefreshPreferences(NSDictionary *target, NSDictionary *before, NSError **error) {
    typedef CFDictionaryRef (*CopyFn)(CFArrayRef,CFStringRef,CFStringRef,CFStringRef,CFStringRef);
    typedef void (*FlushFn)(CFStringRef,CFStringRef);
    CopyFn copy=dlsym(RTLD_DEFAULT,"_CFPreferencesCopyMultipleWithContainer");
    FlushFn flush=dlsym(RTLD_DEFAULT,"_CFPreferencesFlushCachesForIdentifier");
    if (!copy || !flush) return Failed(error,@"Container preference cache APIs unavailable");
    NSDictionary *after=PreferenceDomains(target);
    for (NSString *containerID in target[@"containers"]) {
        NSMutableSet *domains=[NSMutableSet setWithArray:before[containerID]?:@[]];
        [domains addObjectsFromArray:after[containerID]?:@[]];
        NSString *root=target[@"containers"][containerID];
        for (NSString *domain in domains) {
            flush((__bridge CFStringRef)domain,CFSTR("mobile"));
            NSDictionary *api=CFBridgingRelease(copy(NULL,(__bridge CFStringRef)domain,CFSTR("mobile"),kCFPreferencesAnyHost,(__bridge CFStringRef)root));
            NSString *path=[[root stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:[domain stringByAppendingPathExtension:@"plist"]];
            NSDictionary *disk=[NSDictionary dictionaryWithContentsOfFile:path];
            if ([NSFileManager.defaultManager fileExistsAtPath:path] && !disk)
                return Failed(error,@"Restored preferences are unreadable");
            if (![(api?:@{}) isEqual:(disk?:@{})]) return Failed(error,@"Preference cache readback does not match restored files");
        }
    }
    return YES;
}
@interface Backend : NSObject <PXAppStateSessionBackend>
@property (nonatomic, strong) PXAppStateEngine *engine;
@property (nonatomic, strong) PXASLaunchServicesResolver *resolver;
@property (nonatomic, copy) NSDictionary *resolvedTarget;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) void (^progress)(NSDictionary *event);
@property (nonatomic, assign) BOOL savedCurrent;
@end
@implementation Backend
- (NSArray *)catalog:(NSError **)error { return [self.engine catalogBundle:self.bundleID error:error]; }
- (NSDictionary *)target:(NSError **)error {
    NSDictionary *target=[self.resolver resolve:self.bundleID error:error];
    if(target && ![[NSUUID alloc] initWithUUIDString:target[@"IDFV"]]){Failed(error,@"Cannot read current IDFV");return nil;}
    for (NSString *key in @[@"containers",@"bundlePath",@"applicationIdentifier",@"keychainGroups",@"version",@"build"])
        if (target && ![target[key] isEqual:self.resolvedTarget[key]]) { Failed(error,@"Target installation changed during operation"); return nil; }
    return target;
}
- (NSDictionary *)association:(NSError **)error {
    NSString *path=PXAppStateAssociationPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:error]; if (!data) return nil;
    id state=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
    if (![state isKindOfClass:NSDictionary.class]) { Failed(error,@"Account association file is invalid"); return nil; }
    id item=state[self.bundleID];
    if (item && (![item isKindOfClass:NSDictionary.class] || ![item[@"reference"] isKindOfClass:NSString.class] || ![item[@"containers"] isKindOfClass:NSDictionary.class])) {
        Failed(error,@"Account association is invalid"); return nil;
    }
    return item;
}
- (BOOL)writeAssociation:(NSDictionary *)association error:(NSError **)error {
    NSString *path=PXAppStateAssociationPath();
    NSMutableDictionary *state=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy]?:[NSMutableDictionary dictionary];
    if (association) state[self.bundleID]=association; else [state removeObjectForKey:self.bundleID];
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return chmod(path.fileSystemRepresentation,0600)==0 || Failed(error,@"Cannot secure account association file");
}
- (NSDictionary *)captureName:(NSString *)name replace:(BOOL)replace metadata:(NSDictionary *)metadata error:(NSError **)error {
    if(self.progress)self.progress(@{@"phase":@"backup",@"stage":@"prepare"});
    if (!Stop(self.resolver,self.resolvedTarget,error)) return nil;
    NSDictionary *result=[self.engine captureBundle:self.bundleID kind:@"snapshot" name:name replacingSnapshot:replace metadata:metadata error:error];
    if(result)self.savedCurrent=YES;
    return result;
}
- (BOOL)createBaseline:(NSError **)error {
    return [self.engine createBaselineBundle:self.bundleID error:error]!=nil;
}
- (BOOL)restore:(NSString *)reference error:(NSError **)error {
    // Require the cache APIs before entering a destructive restore.
    if (!dlsym(RTLD_DEFAULT,"_CFPreferencesCopyMultipleWithContainer") || !dlsym(RTLD_DEFAULT,"_CFPreferencesFlushCachesForIdentifier"))
        return Failed(error,@"Preference cache APIs unavailable");
    if (!Stop(self.resolver,self.resolvedTarget,error)) return NO;
    NSDictionary *before=PreferenceDomains(self.resolvedTarget);
    if (![self.engine restoreReference:reference bundleID:self.bundleID restoreIdentity:YES error:error]) return NO;
    if(self.progress)self.progress(@{@"phase":@"restore",@"stage":@"verify_preferences"});
    if (!RefreshPreferences(self.resolvedTarget,before,error) || ![self.resolver assertStopped:self.resolvedTarget error:error]) {
        if (error && *error) { NSMutableDictionary *info=[(*error).userInfo mutableCopy]; info[@"stateMayBePartial"]=@YES;
            *error=[NSError errorWithDomain:(*error).domain code:(*error).code userInfo:info]; }
        return NO;
    }
    return YES;
}
- (BOOL)edit:(NSString *)reference metadata:(NSDictionary *)metadata error:(NSError **)error {
    return [self.engine updateSnapshot:reference bundleID:self.bundleID metadata:metadata error:error];
}
- (BOOL)remove:(NSString *)reference error:(NSError **)error { return [self.engine deleteSnapshot:reference bundleID:self.bundleID error:error]; }
@end

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc!=2 || getuid()!=501 || geteuid()!=501) return 64;
    NSError *error=nil; NSDictionary *result=nil;
    NSString *requestPath=Physical(@(argv[1]));
    NSString *operations=Physical(PXAppStateOperationsPath());
    NSString *directory=requestPath.stringByDeletingLastPathComponent;
    struct stat st,dirStat,rootStat;
    if (!operations || ![directory.stringByDeletingLastPathComponent isEqual:operations] ||
        ![[NSUUID alloc] initWithUUIDString:directory.lastPathComponent] ||
        ![requestPath.lastPathComponent isEqual:@"request.plist"] ||
        ![Physical(@(argv[0])) isEqual:[directory stringByAppendingPathComponent:@"worker"]] ||
        lstat(directory.fileSystemRepresentation,&dirStat)!=0 || !S_ISDIR(dirStat.st_mode) || dirStat.st_uid!=501 || (dirStat.st_mode&0777)!=0700 ||
        lstat(operations.fileSystemRepresentation,&rootStat)!=0 || !S_ISDIR(rootStat.st_mode) || rootStat.st_uid!=501 || (rootStat.st_mode&0777)!=0700 ||
        lstat(requestPath.fileSystemRepresentation,&st)!=0 || !S_ISREG(st.st_mode) || st.st_uid!=501 || (st.st_mode&077)!=0) return 64;
    int lockfd=open([[operations stringByAppendingPathComponent:@"session.lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if (lockfd<0 || flock(lockfd,LOCK_EX|LOCK_NB)!=0) { if (lockfd>=0) close(lockfd); return 75; }
    @try {
        NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:requestPath];
        NSString *bundleID=request[@"bundleID"];
        PXASLaunchServicesResolver *resolver=[PXASLaunchServicesResolver new];
        NSDictionary *target=[resolver resolve:bundleID error:&error];
        if (target) {
            NSString *backupRoot=PXAppStateBackupRootPath();
            if ([NSFileManager.defaultManager createDirectoryAtPath:backupRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
                NSString *vendor=Physical(PXAppStateVendorTemplatePath()); struct stat vendorInfo,parentInfo;
                if (!vendor || lstat(vendor.fileSystemRepresentation,&vendorInfo)!=0 || !S_ISREG(vendorInfo.st_mode) ||
                    vendorInfo.st_uid!=0 || (vendorInfo.st_mode&022)!=0 ||
                    lstat(vendor.stringByDeletingLastPathComponent.fileSystemRepresentation,&parentInfo)!=0 ||
                    !S_ISDIR(parentInfo.st_mode) || parentInfo.st_uid!=0 || (parentInfo.st_mode&022)!=0) {
                    Failed(&error,@"Installed IDFV helper is not protected by root ownership");
                    @throw [NSException exceptionWithName:@"PXAppStateWorker" reason:error.localizedDescription userInfo:nil];
                }
                PXASVendorIdentity *identity=[[PXASVendorIdentity alloc] initWithPrivilegedCommand:@[PXBootstrapCommandPath(@"sudo"),@"-n",vendor] systemPlist:LSDPlist()];
                if ([request[@"operation"] isEqual:@"switch"] && ![identity validateState:@{@"bundleID":bundleID,@"vendorName":target[@"vendorName"],@"IDFV":target[@"IDFV"]} target:target error:&error]) {
                    @throw [NSException exceptionWithName:@"PXAppStateWorker" reason:error.localizedDescription userInfo:nil];
                }
                PXAppStateEngine *engine=[[PXAppStateEngine alloc] initWithRoot:backupRoot resolver:resolver
                    keychain:[[PXASSecurityKeychain alloc] initWithApplicationIdentifier:target[@"applicationIdentifier"]] identity:identity error:&error];
                if (engine) { Backend *backend=[Backend new]; backend.engine=engine; backend.resolver=resolver; backend.resolvedTarget=target; backend.bundleID=bundleID;
                    NSString *progressPath=[directory stringByAppendingPathComponent:@"progress.plist"];
                    __block CFAbsoluteTime lastProgressTime=0;
                    __block NSString *lastStage=nil;
                    __weak Backend *weakBackend=backend;
                    void (^progress)(NSDictionary *)=^(NSDictionary *event) {
                        NSString *stage=[NSString stringWithFormat:@"%@/%@",event[@"phase"],event[@"stage"]];
                        CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
                        if([stage isEqual:lastStage] && now-lastProgressTime<0.1)return;
                        lastStage=stage;lastProgressTime=now;
                        struct stat current;
                        if(lstat(directory.fileSystemRepresentation,&current)!=0 || current.st_dev!=dirStat.st_dev || current.st_ino!=dirStat.st_ino)return;
                        NSMutableDictionary *reported=[event mutableCopy];reported[@"savedCurrent"]=@(weakBackend.savedCurrent);
                        NSData *data=[NSPropertyListSerialization dataWithPropertyList:reported format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
                        if(data && [data writeToFile:progressPath options:NSDataWritingAtomic error:NULL])chmod(progressPath.fileSystemRepresentation,0600);
                    };
                    engine.progressHandler=progress; backend.progress=progress;
                    result=[engine performExclusive:^id(NSError **sessionError) {
                        return [[[PXAppStateSession alloc] initWithBackend:backend] perform:request error:sessionError];
                    } error:&error]; }
            } else if (error) {
                NSMutableDictionary *info=[error.userInfo mutableCopy];
                info[NSLocalizedDescriptionKey]=[NSString stringWithFormat:@"Cannot open backup directory %@: %@", backupRoot, error.localizedDescription];
                error=[NSError errorWithDomain:error.domain code:error.code userInfo:info];
            }
        }
    } @catch (NSException *exception) { (void)exception; if (!error) Failed(&error,@"Invalid app-state request"); }
    flock(lockfd,LOCK_UN); close(lockfd);
    NSMutableDictionary *response=[(result?@{@"ok":@YES,@"result":result}:@{@"ok":@NO,@"message":error.localizedDescription?:@"App-state operation failed",
        @"stateMayBePartial":@([error.userInfo[@"stateMayBePartial"] boolValue]),@"archiveMayBePartial":@([error.userInfo[@"archiveMayBePartial"] boolValue])}) mutableCopy];
    if ([error.userInfo[@"pendingCaptureReference"] isKindOfClass:NSString.class]) response[@"pendingCaptureReference"]=error.userInfo[@"pendingCaptureReference"];
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:response format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data) return 1;
    fwrite(data.bytes,1,data.length,stdout); return 0;
} }
