#import "PXASFixture.h"
#include <sys/stat.h>
#include <unistd.h>
#include <sys/file.h>
#include <fcntl.h>
#import <dispatch/dispatch.h>
static NSUInteger passed = 0;
static void Assert(BOOL ok, NSString *name) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); exit(1); }
    passed++; printf("PASS: %s\n",name.UTF8String);
}
static void Dir(NSString *path) {
    Assert([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:NULL],@"create fixture directory");
}
static void Text(NSString *text, NSString *path) {
    Assert([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL],@"write fixture content");
}
static NSString *Read(NSString *path) { return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]; }
static NSArray *Records(NSString *value) {
    return @[@{@"group":@"TESTTEAM.com.example.state", @"synchronizable":@NO, @"secret":[value dataUsingEncoding:NSUTF8StringEncoding]}];
}
int main(void) { @autoreleasepool {
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"pxas-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    Dir(temp); char *resolved = realpath(temp.fileSystemRepresentation,NULL); temp = @(resolved); free(resolved);
    NSString *store = [temp stringByAppendingPathComponent:@"store"], *bundle = [temp stringByAppendingPathComponent:@"App.app"];
    NSString *data = [temp stringByAppendingPathComponent:@"data-old"], *group = [temp stringByAppendingPathComponent:@"group-old"];
    for (NSString *path in @[store,bundle,data,group]) Dir(path);
    Text(@"executable-v1",[bundle stringByAppendingPathComponent:@"App"]);
    Text(@"info-v1",[bundle stringByAppendingPathComponent:@"Info.plist"]);
    Text(@"system-old",[data stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]);
    Text(@"group-old",[group stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]);
    Dir([data stringByAppendingPathComponent:@"tmp"]);
    Text(@"temporary-cache",[data stringByAppendingPathComponent:@"tmp/cache"]);
    NSString *previews=[data stringByAppendingPathComponent:@"Library/SplashBoard/Snapshots/scene"];
    Dir(previews);Text(@"system-preview",[previews stringByAppendingPathComponent:@"preview.ktx"]);
    Text(@"keep-state",[previews stringByAppendingPathComponent:@"state.plist"]);
    NSString *groupPreviews=[group stringByAppendingPathComponent:@"Library/SplashBoard/Snapshots/scene"];
    Dir(groupPreviews);Text(@"group-file",[groupPreviews stringByAppendingPathComponent:@"preview.ktx"]);
    PXASFixture *fixture = [PXASFixture new]; fixture.records = Records(@"saved"); fixture.identityState = @{@"IDFV":@"saved-identity"};
    fixture.target = @{@"bundleID":@"com.example.state", @"version":@"1.0", @"build":@"10", @"executable":@"App",
        @"bundlePath":bundle, @"containers":@{@"data":data,@"group.example":group}, @"keychainGroups":@[@"TESTTEAM.com.example.state"]};
    NSError *error = nil; PXAppStateEngine *engine = [[PXAppStateEngine alloc] initWithRoot:store resolver:fixture keychain:fixture identity:fixture error:&error];
    Assert(engine != nil,@"create generic engine");
    NSDictionary *firstSnapshot=[engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-10" error:&error];
    if(!firstSnapshot)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
    Assert(firstSnapshot!=nil,@"snapshot capture does not require a baseline or app copy");
    NSDictionary *baseline = [engine captureBundle:@"com.example.state" kind:@"baseline" name:@"1.0" error:&error];
    Assert(baseline != nil,@"capture baseline");
    NSString *baselinePath = [store stringByAppendingPathComponent:baseline[@"reference"]];
    Assert(![NSFileManager.defaultManager fileExistsAtPath:[baselinePath stringByAppendingPathComponent:@"containers/data/Library/SplashBoard"]] &&
        [Read([baselinePath stringByAppendingPathComponent:@"containers/group.example/Library/SplashBoard/Snapshots/scene/preview.ktx"]) isEqual:@"group-file"] &&
        [Read([previews stringByAppendingPathComponent:@"preview.ktx"]) isEqual:@"system-preview"],@"exclude entire main-container SplashBoard without changing App Group or live source");
    Assert([Read([baselinePath stringByAppendingPathComponent:@"containers/data/tmp/cache"]) isEqual:@"temporary-cache"] &&
        [Read([data stringByAppendingPathComponent:@"tmp/cache"]) isEqual:@"temporary-cache"],@"baseline includes tmp contents without changing live files");
    Assert(![NSFileManager.defaultManager fileExistsAtPath:[baselinePath stringByAppendingPathComponent:@"keychain"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[baselinePath stringByAppendingPathComponent:@"identity"]],@"baseline excludes keychain and identity");
    Dir([data stringByAppendingPathComponent:@"Library/Preferences"]);
    Text(@"saved-data",[data stringByAppendingPathComponent:@"Library/Preferences/state.plist"]);
    Text(@"saved-group",[group stringByAppendingPathComponent:@"state.db"]);
    NSString *indexedDB = [data stringByAppendingPathComponent:@"Library/WebKit/WebsiteData/IndexedDB"];
    Dir(indexedDB);
    Text(@"saved-index", [indexedDB stringByAppendingPathComponent:@"state.db"]);
    Assert(symlink(indexedDB.fileSystemRepresentation, [indexedDB stringByAppendingPathComponent:@"v0"].fileSystemRepresentation) == 0,
        @"create absolute directory link back to its parent");
    Assert(symlink("Library/Preferences/state.plist", [data stringByAppendingPathComponent:@"relative-link"].fileSystemRepresentation) == 0,
        @"create relative file link");
    Assert(symlink([group stringByAppendingPathComponent:@"state.db"].fileSystemRepresentation, [data stringByAppendingPathComponent:@"group-link"].fileSystemRepresentation) == 0,
        @"create link to another captured container");
    Assert(symlink("../group-old/state.db", [data stringByAppendingPathComponent:@"relative-group-link"].fileSystemRepresentation) == 0,
        @"create relative cross-container link");
    Assert(symlink([[data stringByAppendingString:@"/../group-old/state.db"] fileSystemRepresentation],
        [data stringByAppendingPathComponent:@"absolute-parent-group-link"].fileSystemRepresentation) == 0,
        @"create absolute parent-traversal cross-container link");
    Assert(symlink("missing-file", [data stringByAppendingPathComponent:@"dangling-link"].fileSystemRepresentation) == 0,
        @"create dangling link without target data");
    NSString *outsideDirectory = [temp stringByAppendingPathComponent:@"outside/subdir"];
    Dir(outsideDirectory);
    Text(@"outside-secret", [temp stringByAppendingPathComponent:@"outside/secret"]);
    Assert(symlink(outsideDirectory.fileSystemRepresentation, [data stringByAppendingPathComponent:@"bridge"].fileSystemRepresentation) == 0 &&
        symlink("bridge/../secret", [data stringByAppendingPathComponent:@"through-link"].fileSystemRepresentation) == 0,
        @"create link target containing link and parent traversal");
    Assert(symlink([data stringByAppendingPathComponent:@"bridge/../secret"].fileSystemRepresentation,
        [data stringByAppendingPathComponent:@"absolute-through-link"].fileSystemRepresentation) == 0,
        @"create absolute target containing link and parent traversal");
    Assert(lchmod([data stringByAppendingPathComponent:@"relative-link"].fileSystemRepresentation, 0700) == 0,
        @"set nondefault symbolic link mode");
    NSDictionary *snapshot = [engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-01" error:&error];
    Assert(snapshot != nil,@"capture snapshot");
    NSString *snapshotPath=[store stringByAppendingPathComponent:snapshot[@"reference"]];
    Assert([Read([snapshotPath stringByAppendingPathComponent:@"containers/data/tmp/cache"]) isEqual:@"temporary-cache"],
        @"snapshot includes tmp file contents");
    NSDictionary *incomplete=[engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-08" error:&error];
    Assert(incomplete!=nil,@"capture incomplete-keychain repair fixture");
    NSDictionary *syncRecord=@{@"group":@"TESTTEAM.com.example.state",@"synchronizable":@YES,@"account":@"refresh-token",@"secret":[@"fresh-token" dataUsingEncoding:NSUTF8StringEncoding]};
    fixture.records=[Records(@"saved") arrayByAddingObject:syncRecord];NSUInteger supplementCalls=fixture.replacementCount;
    NSDictionary *supplement=[engine supplementKeychainReference:incomplete[@"reference"] bundleID:@"com.example.state" error:&error];
    Assert([supplement[@"keychainCount"] isEqual:@2] && fixture.replacementCount==supplementCalls && fixture.records.count==2,
        @"supplement captures sync records without changing live keychain");
    NSString *repaired=[store stringByAppendingPathComponent:incomplete[@"reference"]];
    NSArray *savedRecords=[NSArray arrayWithContentsOfFile:[repaired stringByAppendingPathComponent:@"keychain/records.plist"]];
    Assert([savedRecords containsObject:syncRecord] && [savedRecords containsObject:Records(@"saved").firstObject],@"sync true and local false both persist in archive");
    Text(@"fresh-login-state",[data stringByAppendingPathComponent:@"Library/Preferences/state.plist"]);
    Assert([engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-08" replacingSnapshot:YES error:&error]!=nil &&
        [Read([repaired stringByAppendingPathComponent:@"containers/data/Library/Preferences/state.plist"]) isEqual:@"fresh-login-state"],@"explicit refresh replaces full existing snapshot with current containers and keys");
    Assert([engine captureBundle:@"com.example.state" kind:@"baseline" name:@"1.0" replacingSnapshot:YES error:&error]==nil &&
        [engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"auto" replacingSnapshot:YES error:&error]==nil,@"refresh refuses baseline and automatic names");
    Text(@"saved-data",[data stringByAppendingPathComponent:@"Library/Preferences/state.plist"]);
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]!=nil &&
        fixture.replacementCount==supplementCalls+1 && [fixture.records isEqual:Records(@"saved")],@"snapshot restore removes live sync records absent from archive");
    fixture.records=Records(@"different");
    Assert([engine supplementKeychainReference:incomplete[@"reference"] bundleID:@"com.example.state" error:&error]==nil &&
        [[NSArray arrayWithContentsOfFile:[repaired stringByAppendingPathComponent:@"keychain/records.plist"]] isEqual:savedRecords],@"different local identity rejects supplement without archive changes");
    fixture.records=[Records(@"saved") arrayByAddingObject:syncRecord];
    Assert([engine restoreReference:incomplete[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]!=nil && [fixture.records containsObject:syncRecord],@"supplemented snapshot restores sync records");
    Assert([engine supplementKeychainReference:baseline[@"reference"] bundleID:@"com.example.state" error:&error]==nil,@"supplement rejects baseline references");
    NSDictionary *full=[engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-09" error:&error];
    Assert(full && [[NSArray arrayWithContentsOfFile:[[store stringByAppendingPathComponent:full[@"reference"]] stringByAppendingPathComponent:@"keychain/records.plist"]] containsObject:syncRecord],@"new snapshot includes synchronizable records");
    fixture.records=Records(@"saved");
    NSString *historicalRoot = [temp stringByAppendingPathComponent:@"data-earlier"];
    NSString *historicalLink = [snapshotPath stringByAppendingPathComponent:@"containers/data/historical-link"];
    Assert(symlink([[historicalRoot stringByAppendingPathComponent:@"Library/WebKit/WebsiteData/IndexedDB"] fileSystemRepresentation], historicalLink.fileSystemRepresentation) == 0,
        @"snapshot can contain a link from an installation older than its capture container");
    NSString *snapshotManifestPath=[snapshotPath stringByAppendingPathComponent:@"manifest.plist"];
    NSMutableDictionary *historicalManifest=[[NSDictionary dictionaryWithContentsOfFile:snapshotManifestPath] mutableCopy];
    NSMutableDictionary *historicalInventories=[historicalManifest[@"containerInventories"] mutableCopy];
    NSMutableArray *historicalData=[historicalInventories[@"data"] mutableCopy];
    struct stat historicalStat; Assert(lstat(historicalLink.fileSystemRepresentation,&historicalStat)==0,@"read historical link attributes");
    [historicalData addObject:@{@"path":@"historical-link",@"type":@"symlink",@"target":[historicalRoot stringByAppendingPathComponent:@"Library/WebKit/WebsiteData/IndexedDB"],@"mode":@(historicalStat.st_mode&07777),@"uid":@(historicalStat.st_uid),@"gid":@(historicalStat.st_gid)}];
    [historicalData sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"path"] compare:b[@"path"]];}];
    historicalInventories[@"data"]=historicalData;historicalManifest[@"containerInventories"]=historicalInventories;
    historicalManifest[@"containerSourceAliases"]=@{@"data":@[historicalRoot]};
    Assert([historicalManifest writeToFile:snapshotManifestPath atomically:YES],@"record explicitly identified historical container alias");
    Assert(![NSFileManager.defaultManager fileExistsAtPath:[snapshotPath stringByAppendingPathComponent:@"verification"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[snapshotPath stringByAppendingPathComponent:@"README.txt"]] &&
        [[NSDictionary dictionaryWithContentsOfFile:[snapshotPath stringByAppendingPathComponent:@"manifest.plist"]][@"containerInventories"] isKindOfClass:NSDictionary.class],
        @"inventories embedded in manifest without README or verification directory");
    Assert(snapshot[@"baselineRef"]==nil && baseline[@"baselineRef"]==nil,@"data archives have no application baseline dependency");
    NSString *baselineManifestPath = [baselinePath stringByAppendingPathComponent:@"manifest.plist"];
    NSDictionary *baselineManifest = [NSDictionary dictionaryWithContentsOfFile:baselineManifestPath];
    NSMutableDictionary *wrongFormat = [baselineManifest mutableCopy];
    wrongFormat[@"formatVersion"] = @1;
    Assert([wrongFormat writeToFile:baselineManifestPath atomically:YES], @"set unsupported baseline format");
    Assert([engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-04" error:&error] != nil,
        @"snapshot capture is independent of unrelated baseline format");
    NSUInteger priorReplacements = fixture.replacementCount;
    Assert([engine restoreReference:baseline[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error] == nil &&
        fixture.replacementCount == priorReplacements, @"baseline restore rejects its own unsupported format before mutation");
    Assert([baselineManifest writeToFile:baselineManifestPath atomically:YES], @"restore current baseline manifest");
    Assert(![NSFileManager.defaultManager fileExistsAtPath:[baselinePath stringByAppendingPathComponent:@"application"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[[store stringByAppendingPathComponent:snapshot[@"reference"]] stringByAppendingPathComponent:@"application"]],@"neither baseline nor snapshot stores an application copy");
    Text(@"changed-executable",[bundle stringByAppendingPathComponent:@"App"]);
    NSDictionary *changed=[engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-03" error:&error];
    Assert(changed!=nil,@"changed installed executable does not block data capture");
    Text(@"executable-v1",[bundle stringByAppendingPathComponent:@"App"]);
    Assert([engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-01" error:&error] == nil,@"refuse overwrite");
    Assert([engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"../escape" error:&error] == nil,@"reject traversal name");
    Assert([engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261301-01" error:&error]==nil,@"invalid calendar date rejected");
    Assert([engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-00" error:&error]==nil,@"zero daily sequence rejected");
    NSDictionary *autoOne=[engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"auto" error:&error];
    NSDictionary *autoTwo=[engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"auto" error:&error];
    Assert(autoOne && autoTwo && [autoOne[@"reference"] lastPathComponent].length==11 &&
        ![autoOne[@"reference"] isEqual:autoTwo[@"reference"]],@"automatic snapshots use date plus distinct daily sequence");
    Assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:store error:NULL] isEqual:@[@"com.example.state"]],@"store root contains only per-app directory");
    Assert([NSSet setWithArray:[NSFileManager.defaultManager contentsOfDirectoryAtPath:[store stringByAppendingPathComponent:@"com.example.state"] error:NULL]].count==2 &&
        ![NSFileManager.defaultManager fileExistsAtPath:[store stringByAppendingPathComponent:@"work"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[store stringByAppendingPathComponent:@"applications"]],@"only baseline and snapshot categories; no applications or work directories");
    NSString *newData = [temp stringByAppendingPathComponent:@"data-new"], *newGroup = [temp stringByAppendingPathComponent:@"group-new"];
    Dir(newData); Dir(newGroup); Text(@"system-new",[newData stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]);
    Text(@"group-new",[newGroup stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]);
    Text(@"current",[newData stringByAppendingPathComponent:@"current.txt"]);
    Dir([newData stringByAppendingPathComponent:@"tmp"]);
    Text(@"stale",[newData stringByAppendingPathComponent:@"tmp/stale"]);
    NSMutableDictionary *newTarget = [fixture.target mutableCopy]; newTarget[@"containers"] = @{@"data":newData,@"group.example":newGroup}; fixture.target = newTarget;
    fixture.records = Records(@"current"); fixture.identityState = @{@"IDFV":@"current-identity"};
    NSMutableDictionary *badAliases=[historicalManifest mutableCopy];
    badAliases[@"containerSourceAliases"]=@{@"data":@[@"/outside/unrelated-container"]};
    Assert([badAliases writeToFile:snapshotManifestPath atomically:YES],@"set alias outside captured container parent");
    NSUInteger aliasReplacements=fixture.replacementCount;
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:YES error:&error]==nil && fixture.replacementCount==aliasReplacements,
        @"out-of-scope historical alias rejected before keychain or container mutation");
    Assert([historicalManifest writeToFile:snapshotManifestPath atomically:YES],@"restore valid historical alias mapping");
    NSDictionary *restored = [engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:YES error:&error];
    if (!restored) fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
    Assert(restored != nil,@"restore into new container UUID paths");
    struct stat restoredTmp;NSString *newTmp=[newData stringByAppendingPathComponent:@"tmp"];
    Assert(lstat(newTmp.fileSystemRepresentation,&restoredTmp)==0 && S_ISDIR(restoredTmp.st_mode) &&
        (restoredTmp.st_mode&07777)==0700 && [Read([newTmp stringByAppendingPathComponent:@"cache"]) isEqual:@"temporary-cache"] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[newTmp stringByAppendingPathComponent:@"stale"]],
        @"restore replaces stale tmp contents with archived files and permissions");
    Assert([Read([newData stringByAppendingPathComponent:@"Library/Preferences/state.plist"]) isEqual:@"saved-data"] &&
        [Read([newGroup stringByAppendingPathComponent:@"state.db"]) isEqual:@"saved-group"],@"restore main and shared contents");
    Assert([Read([newData stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]) isEqual:@"system-new"],@"preserve current container metadata");
    Assert([fixture.records isEqual:Records(@"saved")] && [fixture.identityState[@"IDFV"] isEqual:@"saved-identity"],@"restore keychain and injected identity");
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *restoredDB = [newData stringByAppendingPathComponent:@"Library/WebKit/WebsiteData/IndexedDB"];
    Assert([Read([newData stringByAppendingPathComponent:@"historical-link/state.db"]) isEqual:@"saved-index"],
        @"explicit historical alias relocates a link whose UUID differs from capture source");
    Assert([[fm destinationOfSymbolicLinkAtPath:[restoredDB stringByAppendingPathComponent:@"v0"] error:NULL] isEqual:@"."] &&
        [Read([restoredDB stringByAppendingPathComponent:@"v0/state.db"]) isEqual:@"saved-index"],
        @"absolute old-container link becomes relative and resolves restored data");
    Assert([[fm destinationOfSymbolicLinkAtPath:[newData stringByAppendingPathComponent:@"relative-link"] error:NULL] isEqual:@"Library/Preferences/state.plist"] &&
        [Read([newData stringByAppendingPathComponent:@"relative-link"]) isEqual:@"saved-data"], @"relative link survives restoration");
    Assert([Read([newData stringByAppendingPathComponent:@"through-link"]) isEqual:@"outside-secret"] &&
        [Read([newData stringByAppendingPathComponent:@"absolute-through-link"]) isEqual:@"outside-secret"],
        @"link and parent traversal retain filesystem resolution semantics");
    struct stat restoredLink;
    Assert(lstat([newData stringByAppendingPathComponent:@"relative-link"].fileSystemRepresentation, &restoredLink) == 0 &&
        (restoredLink.st_mode & 07777) == 0700, @"restore symbolic link mode without chmod on its target");
    Assert([Read([newData stringByAppendingPathComponent:@"group-link"]) isEqual:@"saved-group"], @"cross-container link follows the current shared container");
    Assert([[fm destinationOfSymbolicLinkAtPath:[newData stringByAppendingPathComponent:@"relative-group-link"] error:NULL] isEqual:@"../group-new/state.db"] &&
        [Read([newData stringByAppendingPathComponent:@"relative-group-link"]) isEqual:@"saved-group"], @"relative cross-container link is relocated to current container");
    Assert([Read([newData stringByAppendingPathComponent:@"absolute-parent-group-link"]) isEqual:@"saved-group"],
        @"absolute parent traversal resolves current shared container");
    Assert([[fm destinationOfSymbolicLinkAtPath:[newData stringByAppendingPathComponent:@"dangling-link"] error:NULL] isEqual:@"missing-file"],
        @"dangling link is preserved without following its target");
    Assert([[fm destinationOfSymbolicLinkAtPath:[snapshotPath stringByAppendingPathComponent:@"containers/data/Library/WebKit/WebsiteData/IndexedDB/v0"] error:NULL] isEqual:indexedDB],
        @"backup preserves original link text and is not modified by restore");
    Assert(restored[@"rollbackRef"]==nil &&
        [[NSFileManager.defaultManager contentsOfDirectoryAtPath:[store stringByAppendingPathComponent:@"com.example.state/snapshots"] error:NULL]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.'"]].count==0,@"restore creates no rollback or temporary directories");
    fixture.records=[Records(@"saved") arrayByAddingObject:syncRecord];
    Assert([engine restoreReference:baseline[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error] != nil,@"restore baseline clears both sync states");
    Assert(fixture.records.count == 0 && ![NSFileManager.defaultManager fileExistsAtPath:[newData stringByAppendingPathComponent:@"Library/Preferences/state.plist"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[newData stringByAppendingPathComponent:@"Library/SplashBoard"]],@"baseline clears keychain and business data");
    Assert(![fixture.identityState[@"IDFV"] isEqual:@"saved-identity"] && [[NSUUID alloc] initWithUUIDString:fixture.identityState[@"IDFV"]]!=nil,@"baseline generates a fresh IDFV without captured identity");
    NSString *firstResetIDFV=fixture.identityState[@"IDFV"];
    Assert([engine restoreReference:baseline[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]!=nil && ![fixture.identityState[@"IDFV"] isEqual:firstResetIDFV],@"each baseline restore generates a new IDFV");
    fixture.failExportOnce=YES;
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]==nil,
        @"readback export failure reported");
    Assert([engine restoreReference:baseline[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]!=nil,
        @"failed restore leaves no transaction directory; retry succeeds");
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),finished=dispatch_semaphore_create(0);
    __block NSUInteger exportCalls=0; __block NSDictionary *threadResult=nil;
    fixture.exportHook=^{ if(exportCalls++==0){dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);} };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{
        NSError *threadError=nil;threadResult=[engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-90" error:&threadError];
        dispatch_semaphore_signal(finished);
    }});
    Assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"first same-engine operation reaches blocking adapter");
    Assert([engine restoreReference:baseline[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]==nil &&
        [error.localizedDescription containsString:@"busy"],@"second same-engine operation cannot acquire lock");
    dispatch_semaphore_signal(release);
    Assert(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0 && threadResult!=nil,
        @"first operation retains lock and completes");
    fixture.exportHook=nil;
    fixture.records = Records(@"original-key"); Text(@"original-data",[newData stringByAppendingPathComponent:@"original.txt"]);
    fixture.failAfterKeychainClear = YES;
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error] == nil &&
        [error.userInfo[@"stateMayBePartial"] boolValue] && error.userInfo[@"rollback"]==nil,@"failure after clear reports partial state");
    Assert(fixture.records.count==0 && [Read([newData stringByAppendingPathComponent:@"original.txt"]) isEqual:@"original-data"],@"failed keychain operation stops without automatic undo");
    fixture.identityState = @{@"IDFV":@"original-identity"}; fixture.failIdentityOnce = YES;
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:YES error:&error] == nil &&
        [error.userInfo[@"stateMayBePartial"] boolValue],@"identity failure reports partial state");
    Assert([fixture.records isEqual:Records(@"saved")] && [Read([newData stringByAppendingPathComponent:@"Library/Preferences/state.plist"]) isEqual:@"saved-data"] &&
        [fixture.identityState[@"IDFV"] isEqual:@"saved-identity"],@"failed restore does not replay previous state");
    fixture.running = YES; NSUInteger calls = fixture.replacementCount;
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error] == nil && fixture.replacementCount == calls,@"running app rejected before mutation"); fixture.running = NO;
    newTarget[@"build"] = @"11";newTarget[@"version"]=@"2.0";fixture.target = newTarget;
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error] != nil && fixture.replacementCount > calls,@"different installed version and build allow data restoration");
    Assert([engine restoreReference:baseline[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]!=nil,@"baseline data restore also allows a newer installed version");
    newTarget[@"build"] = @"10";newTarget[@"version"]=@"1.0";fixture.target = newTarget;calls=fixture.replacementCount;
    Text(@"tampered",[store stringByAppendingPathComponent:[snapshot[@"reference"] stringByAppendingPathComponent:@"containers/data/Library/Preferences/state.plist"]]);
    Assert([engine restoreReference:snapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error] == nil && fixture.replacementCount == calls,@"core corruption rejected before clear");
    Assert([engine restoreReference:baseline[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]!=nil,
        @"payload preflight failure permits retry");
    Assert([engine restoreReference:@"../escape" bundleID:@"com.example.state" restoreIdentity:NO error:&error] == nil,@"reject escaping reference");
    int lockFD=open(store.fileSystemRepresentation,O_RDONLY|O_DIRECTORY);
    Assert(lockFD>=0 && flock(lockFD,LOCK_EX|LOCK_NB)==0,@"acquire competing store lock");
    Assert([engine captureBundle:@"com.example.state" kind:@"baseline" name:@"1.0" error:&error]==nil,@"concurrent operation rejected");
    flock(lockFD,LOCK_UN); close(lockFD);
    Text(@"external",[temp stringByAppendingPathComponent:@"external.txt"]);
    Assert([NSFileManager.defaultManager createSymbolicLinkAtPath:[newData stringByAppendingPathComponent:@"unsafe"]
        withDestinationPath:[temp stringByAppendingPathComponent:@"external.txt"] error:NULL],@"create adversarial symlink");
    NSDictionary *linkedSnapshot = [engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-06" error:&error];
    Assert(linkedSnapshot != nil, @"capture external link without following its target");
    Assert([engine restoreReference:linkedSnapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error] != nil &&
        [Read([temp stringByAppendingPathComponent:@"external.txt"]) isEqual:@"external"], @"restore external link without modifying external data");
    NSDictionary *description=@{@"displayName":@"Account A",@"note":@"France"};
    Assert([engine updateSnapshot:linkedSnapshot[@"reference"] bundleID:@"com.example.state" metadata:description error:&error],@"edit account metadata without live mutation");
    NSArray *catalog=[engine catalogBundle:@"com.example.state" error:&error];
    Assert(catalog!=nil && [catalog filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry,NSDictionary *bindings){
        (void)bindings;return [entry[@"account"] isEqual:description];}]].count==1,@"catalog reads root manifest account descriptions");
    NSString *displayManifestPath=[[store stringByAppendingPathComponent:linkedSnapshot[@"reference"]] stringByAppendingPathComponent:@"manifest.plist"];
    NSMutableDictionary *displayManifest=[[NSDictionary dictionaryWithContentsOfFile:displayManifestPath] mutableCopy];
    [displayManifest removeObjectForKey:@"date"];
    for(NSString *timestamp in @[@"2026-10-06T09:00:00Z",@"2026-10-06T09:00:00.123Z",@"2026-10-06T11:00:00+02:00"]){
        displayManifest[@"createdUTC"]=timestamp;
        Assert([displayManifest writeToFile:displayManifestPath atomically:YES],@"write existing string-date manifest");
        NSData *original=[NSData dataWithContentsOfFile:displayManifestPath];
        NSArray *listed=[engine catalogBundle:@"com.example.state" error:&error];
        NSDictionary *entry=[[listed filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){
            (void)bindings;return [item[@"reference"] isEqual:linkedSnapshot[@"reference"]];}]] firstObject];
        Assert([entry[@"savedAt"] isKindOfClass:NSDate.class],@"catalog accepts existing ISO date string");
        Assert([[NSData dataWithContentsOfFile:displayManifestPath] isEqual:original],@"catalog does not rewrite existing manifest");
    }
    [displayManifest removeObjectForKey:@"createdUTC"];
    [displayManifest removeObjectForKey:@"version"];
    Assert([displayManifest writeToFile:displayManifestPath atomically:YES],@"write archive without optional display metadata");
    Assert([engine catalogBundle:@"com.example.state" error:&error]!=nil,@"missing display metadata does not block entire catalog");
    Assert([engine restoreReference:linkedSnapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:NO error:&error]!=nil,
        @"restore does not depend on optional display metadata");
    fixture.identityState=@{@"bundleID":@"com.example.state",@"IDFV":@"AB0399A3-3148-430A-BA5F-84CF6F7C38DD"};
    NSMutableArray *progressEvents=[NSMutableArray array];
    engine.progressHandler=^(NSDictionary *event){[progressEvents addObject:[event copy]];};
    Assert([engine captureBundle:@"com.example.state" kind:@"snapshot" name:@"20261005-06" replacingSnapshot:YES metadata:nil error:&error]!=nil,@"refresh named account snapshot");
    NSArray *captureStages=[progressEvents valueForKey:@"stage"];
    Assert([captureStages containsObject:@"verify_files"] && [captureStages containsObject:@"verify_keychain"] && [captureStages containsObject:@"publish"],@"backup progress includes real file/keychain verification before publication");
    unsigned long long lastBytes=0; NSUInteger lastFiles=0;
    for(NSDictionary *event in progressEvents)if([event[@"stage"] isEqual:@"copy"]){
        Assert([event[@"bytes"] unsignedLongLongValue]>=lastBytes && [event[@"files"] unsignedIntegerValue]>=lastFiles,@"completed-file backup counters never decrease");
        lastBytes=[event[@"bytes"] unsignedLongLongValue];lastFiles=[event[@"files"] unsignedIntegerValue];
    }
    Assert(lastBytes>0 && lastFiles>0,@"backup progress reports bytes/files copied by real copyfile callbacks");
    [progressEvents removeAllObjects];
    Assert([engine restoreReference:linkedSnapshot[@"reference"] bundleID:@"com.example.state" restoreIdentity:YES error:&error]!=nil,@"progress-enabled restore retains original identity and file semantics");
    NSArray *restoreStages=[progressEvents valueForKey:@"stage"];
    Assert([restoreStages containsObject:@"verify_files"] && [restoreStages containsObject:@"verify_identity"] && [restoreStages containsObject:@"verify_keychain"],@"restore progress explicitly reports all native verification phases");
    BOOL verificationStarted=NO,forwardOnly=YES;
    for(NSString *stage in restoreStages) {
        if([stage isEqual:@"verify_files"])verificationStarted=YES;
        if(verificationStarted && [@[@"clear",@"copy"] containsObject:stage])forwardOnly=NO;
    }
    Assert(forwardOnly,@"restore finishes all data copying before advancing to final verification");
    engine.progressHandler=nil;
    NSDictionary *refreshedManifest=[NSDictionary dictionaryWithContentsOfFile:[[store stringByAppendingPathComponent:linkedSnapshot[@"reference"]] stringByAppendingPathComponent:@"manifest.plist"]];
    Assert([refreshedManifest[@"title"] isEqual:description[@"displayName"]] && [refreshedManifest[@"note"] isEqual:description[@"note"]] && !refreshedManifest[@"account"],@"fixed-directory refresh preserves name and note in simple root fields");
    Assert([refreshedManifest[@"date"] isKindOfClass:NSDate.class] && [refreshedManifest[@"idfv"] isEqual:fixture.identityState[@"IDFV"]] && !refreshedManifest[@"createdUTC"],@"new manifest records short date and idfv fields");
    NSArray *identified=[engine catalogBundle:@"com.example.state" error:&error];
    Assert([[identified filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry,NSDictionary *bindings){(void)bindings;return [entry[@"IDFV"] isEqual:fixture.identityState[@"IDFV"]];}]] count]==1,@"catalog indexes IDFV from root manifest");
    Assert(![engine updateSnapshot:baseline[@"reference"] bundleID:@"com.example.state" metadata:description error:&error],@"account metadata cannot be attached to a baseline");
    Assert(![engine updateSnapshot:linkedSnapshot[@"reference"] bundleID:@"com.example.state" metadata:@{@"displayName":@"  ",@"note":@""} error:&error],@"reject empty account name");
    Assert(![engine deleteSnapshot:@"../escape" bundleID:@"com.example.state" error:&error],@"deletion rejects escaping references");
    Assert([engine deleteSnapshot:linkedSnapshot[@"reference"] bundleID:@"com.example.state" error:&error] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[store stringByAppendingPathComponent:linkedSnapshot[@"reference"]]],@"delete removes only the selected saved snapshot");
    PXAppStateEngine *competitor=[[PXAppStateEngine alloc] initWithRoot:store resolver:fixture keychain:fixture identity:fixture error:&error];
    NSArray *exclusive=[engine performExclusive:^id(NSError **innerError) {
        NSArray *inside=[engine catalogBundle:@"com.example.state" error:innerError];
        Assert(inside!=nil,@"exclusive session permits nested engine operations");
        Assert([competitor catalogBundle:@"com.example.state" error:NULL]==nil,@"nested call does not release the session's cross-worker store lock");
        return inside;
    } error:&error];
    Assert(exclusive!=nil && [competitor catalogBundle:@"com.example.state" error:&error]!=nil,@"exclusive session releases lock after completion");
    NSMutableDictionary *initialTarget=[fixture.target mutableCopy];initialTarget[@"version"]=@"3.0";fixture.target=initialTarget;
    NSString *liveData=fixture.target[@"containers"][@"data"];
    Text(@"live-account",[liveData stringByAppendingPathComponent:@"account.txt"]);
    NSArray *liveRecords=[fixture.records copy];NSDictionary *liveIdentity=[fixture.identityState copy];
    fixture.running=YES;
    NSDictionary *blank=[engine createBaselineBundle:@"com.example.state" error:&error];
    Assert(blank!=nil,@"create baseline from missing version directory");
    NSString *blankPath=[store stringByAppendingPathComponent:blank[@"reference"]];
    NSDictionary *blankManifest=[NSDictionary dictionaryWithContentsOfFile:[blankPath stringByAppendingPathComponent:@"manifest.plist"]];
    Assert(![blankManifest[@"keychainIncluded"] boolValue] && ![blankManifest[@"identityIncluded"] boolValue] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[blankPath stringByAppendingPathComponent:@"containers/data/account.txt"]],@"new baseline contains no live account data, secrets or identity");
    Assert([Read([liveData stringByAppendingPathComponent:@"account.txt"]) isEqual:@"live-account"] && [fixture.records isEqual:liveRecords] && [fixture.identityState isEqual:liveIdentity],@"baseline creation preserves live account and keychain");
    Assert([engine createBaselineBundle:@"com.example.state" error:&error]==nil,@"core does not overwrite existing baseline");error=nil;
    fixture.running=NO;
    Assert([engine restoreReference:blank[@"reference"] bundleID:@"com.example.state" restoreIdentity:YES error:&error]!=nil,@"empty baseline restores through normal pipeline");
    Assert(![NSFileManager.defaultManager fileExistsAtPath:[liveData stringByAppendingPathComponent:@"account.txt"]] && fixture.records.count==0 && ![fixture.identityState isEqual:liveIdentity],@"using empty baseline clears account data and keychain and resets identity");
    engine = nil;
    Assert([NSFileManager.defaultManager removeItemAtPath:temp error:NULL],@"clean temporary test tree");
    printf("%lu assertions passed; no real app or keychain touched.\n",(unsigned long)passed);
} return 0; }
