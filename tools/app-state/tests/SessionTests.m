#import "../core/PXAppStateSession.h"
static NSUInteger count=0;
static void Check(BOOL ok, const char *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } count++; }
@interface Fixture : NSObject <PXAppStateSessionBackend>
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, strong) NSMutableArray *calls;
@property (nonatomic, copy) NSDictionary *current;
@property (nonatomic, copy) NSDictionary *roots;
@property (nonatomic, copy) NSString *IDFV;
@property (nonatomic, assign) BOOL failSave;
@property (nonatomic, assign) BOOL failRestore;
@property (nonatomic, assign) BOOL failAfterIdentity;
@end
@implementation Fixture
- (instancetype)init { if ((self=[super init])) {
    _entries=[@[@{@"reference":@"test/snapshots/20261006-01",@"kind":@"snapshot"},
        @{@"reference":@"test/snapshots/20261006-02",@"kind":@"snapshot"},
        @{@"reference":@"test/baselines/1.0",@"kind":@"baseline",@"version":@"1.0"}] mutableCopy];
    _roots=@{@"data":@"/new-installation"}; _calls=[NSMutableArray array];
} return self; }
- (NSArray *)catalog:(NSError **)error { (void)error; return self.entries; }
- (NSDictionary *)target:(NSError **)error { (void)error; NSMutableDictionary *target=[@{@"containers":self.roots,@"version":@"1.0"} mutableCopy];if(self.IDFV)target[@"IDFV"]=self.IDFV;return target; }
- (BOOL)createBaseline:(NSError **)error { (void)error;[self.calls addObject:@"baseline"];[self.entries addObject:@{@"reference":@"test/baselines/1.0",@"kind":@"baseline",@"version":@"1.0"}];return YES; }
- (NSDictionary *)association:(NSError **)error { (void)error; return self.current; }
- (BOOL)writeAssociation:(NSDictionary *)association error:(NSError **)error {
    (void)error; self.current=association; [self.calls addObject:[association[@"restorePending"] boolValue]?[@"pending:" stringByAppendingString:association[@"pendingReference"]]:(association?[@"associate:" stringByAppendingString:association[@"reference"]]:@"clear")]; return YES;
}
- (NSDictionary *)captureName:(NSString *)name replace:(BOOL)replace metadata:(NSDictionary *)metadata error:(NSError **)error {
    [self.calls addObject:replace?[@"replace:" stringByAppendingString:name]:@"new"];
    if (self.failSave) { if (error) *error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil]; return nil; }
    if (!replace) {
        Check(metadata!=nil,"new account capture receives its metadata");
        [self.entries addObject:@{@"reference":@"test/snapshots/20261006-03",@"kind":@"snapshot",@"account":metadata}];
    }
    return @{@"reference":[@"test/snapshots/" stringByAppendingString:replace?name:@"20261006-03"]};
}
- (BOOL)restore:(NSString *)reference error:(NSError **)error {
    Check([self.current[@"restorePending"] boolValue] && [self.current[@"reference"] isEqual:@""],"durable pending marker precedes live restore");
    [self.calls addObject:[@"restore:" stringByAppendingString:reference]];
    if(self.IDFV && (!self.failRestore || self.failAfterIdentity)) {
        for(NSDictionary *entry in self.entries)if([entry[@"reference"] isEqual:reference])self.IDFV=entry[@"IDFV"]?:NSUUID.UUID.UUIDString;
    }
    if (self.failRestore && error) *error=[NSError errorWithDomain:@"fixture" code:2 userInfo:@{@"stateMayBePartial":@YES}];
    return !self.failRestore;
}
- (BOOL)edit:(NSString *)reference metadata:(NSDictionary *)metadata error:(NSError **)error { (void)metadata; (void)error; [self.calls addObject:[@"edit:" stringByAppendingString:reference]]; return YES; }
- (BOOL)remove:(NSString *)reference error:(NSError **)error { (void)error; [self.calls addObject:[@"delete:" stringByAppendingString:reference]]; return YES; }
@end
static NSDictionary *Association(Fixture *f, NSString *name) { return @{@"reference":[@"test/snapshots/" stringByAppendingString:name],@"containers":f.roots}; }
int main(void) { @autoreleasepool {
    Fixture *f=[Fixture new]; PXAppStateSession *session=[[PXAppStateSession alloc] initWithBackend:f]; NSError *error=nil;
    NSDictionary *metadata=@{@"displayName":@"Account C",@"note":@"France"};
    Check([session perform:@{@"operation":@"save"} error:&error]==nil && f.calls.count==0,"first save requires an explicit account name"); error=nil;
    Check([session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-02"} error:&error]==nil && f.calls.count==0,"unassigned switching requires save or discard"); error=nil;
    NSDictionary *result=[session perform:@{@"operation":@"save",@"account":metadata} error:&error];
    Check([result[@"currentReference"] isEqual:@"test/snapshots/20261006-03"],"first save associates the published backup");
    [f.calls removeAllObjects]; result=[session perform:@{@"operation":@"save"} error:&error];
    Check(result!=nil && [f.calls.firstObject isEqual:@"replace:20261006-03"],"subsequent saves update the same directory");
    f.current=Association(f,@"20261006-01"); [f.calls removeAllObjects];
    result=[session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-02"} error:&error];
    Check([f.calls isEqual:@[@"replace:20261006-01",@"associate:test/snapshots/20261006-01",@"pending:test/snapshots/20261006-02",@"restore:test/snapshots/20261006-02",@"associate:test/snapshots/20261006-02"]],"switch saves current before marking pending and restoring destination");
    Check([result[@"currentReference"] isEqual:@"test/snapshots/20261006-02"],"switch activates only after restore readback");
    [f.calls removeAllObjects];
    result=[session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-01",@"discardCurrent":@YES} error:&error];
    Check(result!=nil && [f.calls isEqual:@[@"pending:test/snapshots/20261006-01",@"restore:test/snapshots/20261006-01",@"associate:test/snapshots/20261006-01"]],"unchecked automatic backup switches assigned account without overwriting previous snapshot");
    f.current=Association(f,@"20261006-02");
    [f.calls removeAllObjects]; f.failSave=YES;
    Check([session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-01"} error:&error]==nil &&
        [f.calls isEqual:@[@"replace:20261006-02"]] && [f.current[@"reference"] hasSuffix:@"-02"],"capture failure stops before live replacement");
    error=nil; f.failSave=NO; f.failRestore=YES; [f.calls removeAllObjects];
    Check([session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-01"} error:&error]==nil && [f.current[@"restorePending"] boolValue],"restore failure retains pending state without active account");
    error=nil; f.failRestore=NO; [f.calls removeAllObjects];
    result=[session perform:@{@"operation":@"switch",@"reference":@"test/baselines/1.0",@"discardCurrent":@YES} error:&error];
    Check(result!=nil && [result[@"currentReference"] isEqual:@""] && !f.current,"baseline stays unassigned for new account login");
    Check([f.calls isEqual:@[@"pending:test/baselines/1.0",@"restore:test/baselines/1.0",@"clear"]],"baseline completes before clearing pending marker without saving partial data");
    result=[session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-01",@"account":metadata} error:&error];
    Check(result!=nil && [f.current[@"reference"] hasSuffix:@"-01"],"save-first unassigned switch preserves new account before restoring old");
    [f.calls removeAllObjects];
    Check([session perform:@{@"operation":@"delete",@"reference":@"test/snapshots/20261006-01"} error:&error]==nil && f.calls.count==0,"active backup cannot be deleted"); error=nil;
    f.current=@{@"reference":@"test/snapshots/20261006-01",@"containers":@{@"data":@"/old-installation"}};
    result=[session perform:@{@"operation":@"catalog"} error:&error];
    Check([result[@"currentReference"] isEqual:@""] && !f.current,"reinstallation invalidates the old association");
    [f.calls removeAllObjects];
    Check([session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/missing",@"account":metadata} error:&error]==nil && f.calls.count==0,"missing destination rejected before saving or live mutation"); error=nil;
    f.current=Association(f,@"20261006-01");
    result=[session perform:@{@"operation":@"save",@"saveAsNew":@YES,@"account":metadata} error:&error];
    Check(result!=nil && [f.calls containsObject:@"new"] && [f.current[@"reference"] hasSuffix:@"-03"],"explicit new-account save does not overwrite prior account directory");
    f.failSave=YES; error=nil;
    Check([session perform:@{@"operation":@"save",@"saveAsNew":@YES,@"account":metadata} error:&error]==nil && !f.current,
        "failed explicit new-account capture cannot retain the old account association");
    f=[Fixture new];session=[[PXAppStateSession alloc] initWithBackend:f];error=nil;
    NSString *identifier=@"A35F738D-FFCA-4137-9C7C-09323B9F9872";
    f.IDFV=identifier.lowercaseString;
    f.entries[0]=@{@"reference":@"test/snapshots/20261006-01",@"kind":@"snapshot",@"IDFV":identifier};
    result=[session perform:@{@"operation":@"catalog"} error:&error];
    Check([result[@"currentReference"] hasSuffix:@"-01"] && [f.current[@"containers"] isEqual:f.roots],"unique normalized IDFV identifies externally restored environment");
    f.roots=@{@"data":@"/reinstalled-container"};
    result=[session perform:@{@"operation":@"catalog"} error:&error];
    Check([result[@"currentReference"] hasSuffix:@"-01"] && [f.current[@"containers"] isEqual:f.roots],"same IDFV rebinds to current containers");
    [f.calls removeAllObjects];result=[session perform:@{@"operation":@"save"} error:&error];
    Check(result && [f.calls.firstObject isEqual:@"replace:20261006-01"],"inferred IDFV saves into its fixed directory");
    [f.calls removeAllObjects];
    Check([session perform:@{@"operation":@"save",@"saveAsNew":@YES,@"account":metadata} error:&error]==nil && !f.calls.count,
        "same IDFV cannot create another account backup");
    error=nil;f.IDFV=@"C9EB7804-2062-4519-AC8D-6F68972574F3";
    result=[session perform:@{@"operation":@"catalog"} error:&error];
    Check([result[@"currentReference"] isEqual:@""] && !f.current,"changed IDFV invalidates association even with unchanged containers");
    f.IDFV=identifier;
    f.entries[1]=@{@"reference":@"test/snapshots/20261006-02",@"kind":@"snapshot",@"IDFV":identifier};
    result=[session perform:@{@"operation":@"catalog"} error:&error];
    Check([result[@"currentReference"] isEqual:@""] && [result[@"duplicateIdentityReferences"] count]==2,"duplicate historical IDFV reports conflict instead of choosing arbitrarily");
    [f.calls removeAllObjects];
    Check([session perform:@{@"operation":@"save",@"account":metadata} error:&error]==nil && !f.calls.count,"duplicate IDFV cannot publish another backup");
    f=[Fixture new];session=[[PXAppStateSession alloc] initWithBackend:f];error=nil;
    f.IDFV=identifier;
    NSString *destinationIDFV=@"C9EB7804-2062-4519-AC8D-6F68972574F3";
    f.entries[0]=@{@"reference":@"test/snapshots/20261006-01",@"kind":@"snapshot",@"IDFV":identifier};
    f.entries[1]=@{@"reference":@"test/snapshots/20261006-02",@"kind":@"snapshot",@"IDFV":destinationIDFV};
    f.failRestore=YES;
    Check([session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-02"} error:&error]==nil,"simulate restore failure before IDFV changes");
    error=nil;session=[[PXAppStateSession alloc] initWithBackend:f];
    result=[session perform:@{@"operation":@"catalog"} error:&error];
    Check([result[@"currentReference"] isEqual:@""] && [result[@"restorePending"] boolValue],"pending restoration survives new session and suppresses source IDFV inference");
    [f.calls removeAllObjects];
    Check([session perform:@{@"operation":@"save"} error:&error]==nil && !f.calls.count,"partial restoration cannot overwrite full backup");
    error=nil;f.failAfterIdentity=YES;
    Check([session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-02"} error:&error]==nil && [f.IDFV isEqual:destinationIDFV],"simulate failure after identity restoration or preference-cache readback");
    error=nil;result=[session perform:@{@"operation":@"catalog"} error:&error];
    Check([result[@"currentReference"] isEqual:@""] && [result[@"restorePending"] boolValue],"pending marker suppresses destination IDFV inference too");
    f.failRestore=NO;[f.calls removeAllObjects];
    result=[session perform:@{@"operation":@"switch",@"reference":@"test/snapshots/20261006-02"} error:&error];
    Check([result[@"currentReference"] hasSuffix:@"-02"] && ![result[@"restorePending"] boolValue] && [f.calls containsObject:@"restore:test/snapshots/20261006-02"],"same-reference retry fully restores before clearing pending marker");
    f=[Fixture new];session=[[PXAppStateSession alloc] initWithBackend:f];error=nil;
    [f.entries removeAllObjects];f.current=nil;
    result=[session perform:@{@"operation":@"baseline"} error:&error];
    Check(result!=nil && [f.calls isEqual:@[@"baseline"]],"first initialization creates baseline without capture or restore");
    [f.calls removeAllObjects];
    Check([session perform:@{@"operation":@"baseline"} error:&error]!=nil && !f.calls.count,"existing baseline creation is idempotent");
    printf("%lu session assertions passed.\n",(unsigned long)count);
} return 0; }
