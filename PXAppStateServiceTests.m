#import "PXAppStateService.h"
#import "PXKeychainOneShotExecution.h"
#include <sys/stat.h>
static NSUInteger checks=0;
static void Check(BOOL value,const char *message) { if (!value) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } checks++; }
@interface PXAppStateService (TestSeam)
- (BOOL)isMobile;
- (id<PXKeychainOneShotExecuting>)targetExecution;
- (id<PXKeychainOneShotProcessRunning>)processRunner;
- (NSDictionary *)operationPaths;
- (NSDictionary *)runBundle:(NSString *)bundleID request:(NSDictionary *)request error:(NSError **)error;
@end
@interface Execution : NSObject <PXKeychainOneShotExecuting>
@property (nonatomic, copy) NSDictionary *entitlements;
@end
@implementation Execution
- (NSDictionary *)signedEntitlementsForTargetBundleIdentifier:(NSString *)bundleIdentifier error:(NSError **)error {
    (void)bundleIdentifier; (void)error; return self.entitlements;
}
- (PXKeychainOneShotResponse *)executeRequest:(PXKeychainCommandRequest *)request workerEntitlements:(NSDictionary *)workerEntitlements error:(NSError **)error {
    (void)request; (void)workerEntitlements; (void)error; return nil;
}
@end
@interface Runner : NSObject <PXKeychainOneShotProcessRunning>
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, assign) NSUInteger launches;
@end
@implementation Runner
- (BOOL)runExecutable:(NSString *)executable arguments:(NSArray *)arguments timeout:(NSTimeInterval)timeout standardOutput:(NSData **)output error:(NSError **)error {
    (void)timeout;
    if ([executable.lastPathComponent isEqual:@"ldid"]) {
        if ([arguments.firstObject isEqual:@"-e"] && output) *output=[NSData dataWithContentsOfFile:[arguments.lastObject stringByAppendingPathExtension:@"entitlements.plist"]];
        return YES;
    }
    self.launches++;
    if([self.mode isEqual:@"progress-final"]) {
        NSString *path=[executable.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"progress.plist"];
        Check([@{@"phase":@"restore",@"stage":@"verify_preferences",@"savedCurrent":@YES} writeToFile:path atomically:YES],"write fast final verification event");
        chmod(path.fileSystemRepresentation,0600);
    }
    NSDictionary *ent=[NSDictionary dictionaryWithContentsOfFile:[executable stringByAppendingPathExtension:@"entitlements.plist"]];
    Check([ent[@"keychain-access-groups"] isEqual:@[@"TEAM.custom",@"TEAM.test.app",@"group.test.app"]],"worker receives all exact effective groups");
    Check([ent[@"application-identifier"] isEqual:@"TEAM.test.app"],"worker uses target application identifier");
    if ([self.mode isEqual:@"timeout"]) { if (error) *error=[NSError errorWithDomain:@"runner" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Timed out"}]; return NO; }
    if ([self.mode isEqual:@"invalid"]) { if (output) *output=[@"invalid response" dataUsingEncoding:NSUTF8StringEncoding]; return YES; }
    NSMutableDictionary *response=[@{@"ok":@YES,@"result":@{@"entries":@[],@"currentReference":@""}} mutableCopy];
    if ([self.mode isEqual:@"partial"] || [self.mode isEqual:@"cleanup"]) {
        response=[@{@"ok":@NO,@"message":@"Publication failed",@"archiveMayBePartial":@YES,@"stateMayBePartial":@NO,
            @"pendingCaptureReference":@"test.app/snapshots/.capture-test"} mutableCopy];
    }
    if ([self.mode isEqual:@"cleanup"]) {
        NSString *directory=executable.stringByDeletingLastPathComponent;
        Check([NSFileManager.defaultManager moveItemAtPath:directory toPath:[directory stringByAppendingString:@"-moved"] error:NULL],"simulate operation directory replacement");
        Check([@"foreign occupant" writeToFile:directory atomically:NO encoding:NSUTF8StringEncoding error:NULL],"occupy original worker directory path");
    }
    if (output) *output=[NSPropertyListSerialization dataWithPropertyList:response format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL]; return YES;
}
@end
@interface Service : PXAppStateService
@property (nonatomic, strong) Execution *execution;
@property (nonatomic, strong) Runner *runner;
@property (nonatomic, copy) NSDictionary *paths;
@end
@implementation Service
- (BOOL)isMobile { return YES; }
- (id<PXKeychainOneShotExecuting>)targetExecution { return self.execution; }
- (id<PXKeychainOneShotProcessRunning>)processRunner { return self.runner; }
- (NSDictionary *)operationPaths { return self.paths; }
@end
int main(void) { @autoreleasepool {
    NSString *temp=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"px-app-state-service-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    Check([NSFileManager.defaultManager createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL],"create private fixture");
    NSString *template=[temp stringByAppendingPathComponent:@"template"];
    Check([@"unsigned fixture" writeToFile:template atomically:NO encoding:NSUTF8StringEncoding error:NULL],"create fixture worker template");
    Service *service=[Service new]; service.execution=[Execution new]; service.runner=[Runner new];
    service.execution.entitlements=@{@"application-identifier":@"TEAM.test.app",@"keychain-access-groups":@[@"TEAM.custom"],@"com.apple.security.application-groups":@[@"group.test.app"]};
    service.paths=@{@"root":[temp stringByAppendingPathComponent:@"operations"],@"worker":template,@"vendor":template,@"bootstrap":temp,@"ldid":[temp stringByAppendingPathComponent:@"ldid"]};
    NSError *error=nil;
    NSDictionary *result=[service runBundle:@"test.app" request:@{@"operation":@"catalog"} error:&error];
    Check(result!=nil && error==nil,"scoped worker success is parsed");
    Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:service.paths[@"root"] error:NULL].count==0,"operation artifacts removed after success");
    service.runner.mode=@"progress-final";
    __block BOOL finished=NO;NSMutableArray *events=[NSMutableArray array];
    [service executeBundle:@"test.app" request:@{@"operation":@"switch"} progress:^(NSDictionary *event){
        Check(!finished,"progress precedes operation completion");[events addObject:event];
    } completion:^(NSDictionary *value,NSError *failure){
        Check(value!=nil && failure==nil,"progress operation completes");finished=YES;
    }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!finished && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(finished && [events.lastObject[@"stage"] isEqual:@"verify_preferences"] && [events.lastObject[@"savedCurrent"] boolValue],"final verification stage survives a worker faster than polling");
    service.runner.mode=@"timeout";
    Check([service runBundle:@"test.app" request:@{@"operation":@"switch"} error:&error]==nil && [error.userInfo[@"stateMayBePartial"] boolValue] && [error.userInfo[@"archiveMayBePartial"] boolValue],"unknown switch completion conservatively reports partial live and archive state"); error=nil;
    service.runner.mode=@"invalid";
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && [error.userInfo[@"archiveMayBePartial"] boolValue] && ![error.userInfo[@"stateMayBePartial"] boolValue],"invalid capture response marks archive uncertainty only"); error=nil;
    service.runner.mode=@"partial";
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && [error.userInfo[@"pendingCaptureReference"] isEqual:@"test.app/snapshots/.capture-test"],"replacement failure preserves completed capture recovery reference"); error=nil;
    service.runner.mode=@"cleanup";
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && [error.userInfo[@"archiveMayBePartial"] boolValue] && [error.userInfo[@"pendingCaptureReference"] isEqual:@"test.app/snapshots/.capture-test"],"cleanup failure preserves original partial flags and recovery reference");
    error=nil; NSUInteger launched=service.runner.launches;
    service.execution.entitlements=@{@"application-identifier":@"TEAM.test.app",@"keychain-access-groups":@[@"*"]};
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && service.runner.launches==launched,"unsafe entitlement rejected before any worker launch");
    Check([NSFileManager.defaultManager removeItemAtPath:temp error:NULL],"remove isolated fixture");
    printf("%lu app-state service assertions passed; no device authority used.\n",(unsigned long)checks);
} return 0; }
