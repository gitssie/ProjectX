#import "../core/PXAppState.h"
#import "../adapters/PXASNative.h"
#include <unistd.h>
static void Usage(void) {
    fputs("usage: app-state inspect|describe ROOT BUNDLE_ID\n"
          "       app-state snapshot ROOT BUNDLE_ID [YYYYMMDD-NN] [--replace]\n"
          "       app-state baseline ROOT BUNDLE_ID [APP_VERSION]\n"
          "       app-state supplement-keychain ROOT BUNDLE_ID SNAPSHOT_REFERENCE\n"
          "       app-state restore ROOT BUNDLE_ID REFERENCE [--identity]\n",stderr);
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc<4||argc>6){Usage();return 64;}
    if(getuid()!=501){fputs("Run app-state as mobile; root is reserved for vendor-worker.\n",stderr);return 64;}
    NSString *command=@(argv[1]),*root=@(argv[2]),*bundle=@(argv[3]);
    NSError *error=nil;PXASLaunchServicesResolver *resolver=[PXASLaunchServicesResolver new];
    NSDictionary *target=[resolver resolve:bundle error:&error];
    if(!target){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
    if([command isEqual:@"describe"]&&argc==4){
        NSDictionary *description=@{@"bundleID":target[@"bundleID"],@"version":target[@"version"],@"build":target[@"build"],
            @"applicationIdentifier":target[@"applicationIdentifier"],@"keychainGroups":target[@"keychainGroups"],
            @"signedEntitlements":target[@"signedEntitlements"],@"containers":target[@"containers"]};
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:description format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
        if(!data)return 1;fwrite(data.bytes,1,data.length,stdout);return 0;
    }
    NSArray *prefix=nil;const char *encoded=getenv("PXAS_IDFV_COMMAND");
    if(encoded){NSData *json=[@(encoded) dataUsingEncoding:NSUTF8StringEncoding];id parsed=[NSJSONSerialization JSONObjectWithData:json options:0 error:&error];
        if(![parsed isKindOfClass:NSArray.class]||[parsed count]==0){fputs("Invalid PXAS_IDFV_COMMAND argv array\n",stderr);return 64;}
        for(id arg in parsed)if(![arg isKindOfClass:NSString.class]||[arg length]==0){fputs("Invalid IDFV argument\n",stderr);return 64;}prefix=parsed;
    }
    const char *lsd=getenv("PXAS_LSD_PLIST");
    PXASVendorIdentity *identity=[[PXASVendorIdentity alloc] initWithPrivilegedCommand:prefix systemPlist:lsd?@(lsd):nil];
    PXASSecurityKeychain *keychain=[[PXASSecurityKeychain alloc] initWithApplicationIdentifier:target[@"applicationIdentifier"]];
    PXAppStateEngine *engine=[[PXAppStateEngine alloc] initWithRoot:root resolver:resolver keychain:keychain identity:identity error:&error];
    if(!engine){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
    NSDictionary *result=nil;
    if([command isEqual:@"inspect"]&&argc==4)result=[engine inspectBundle:bundle error:&error];
    else if([command isEqual:@"supplement-keychain"]&&argc==5)
        result=[engine supplementKeychainReference:@(argv[4]) bundleID:bundle error:&error];
    else if(([@[@"snapshot",@"baseline"] containsObject:command])&&(argc==4||argc==5))
        result=[engine captureBundle:bundle kind:command name:argc==5?@(argv[4]):([command isEqual:@"baseline"]?target[@"version"]:@"auto") error:&error];
    else if([command isEqual:@"snapshot"]&&argc==6&&strcmp(argv[5],"--replace")==0)
        result=[engine captureBundle:bundle kind:command name:@(argv[4]) replacingSnapshot:YES error:&error];
    else if([command isEqual:@"restore"]&&(argc==5||(argc==6&&strcmp(argv[5],"--identity")==0)))
        result=[engine restoreReference:@(argv[4]) bundleID:bundle restoreIdentity:argc==6 error:&error];
    else{Usage();return 64;}
    if(!result){fprintf(stderr,"%s; state_may_be_partial=%s; archive_may_be_partial=%s\n",error.localizedDescription.UTF8String,[error.userInfo[@"stateMayBePartial"] boolValue]?"true":"false",[error.userInfo[@"archiveMayBePartial"] boolValue]?"true":"false");
        if(error.userInfo[@"pendingCaptureReference"])fprintf(stderr,"pending_capture_reference=%s\n",[error.userInfo[@"pendingCaptureReference"] UTF8String]);return 1;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    if(!data)return 1;fwrite(data.bytes,1,data.length,stdout);puts("");
}return 0;}
