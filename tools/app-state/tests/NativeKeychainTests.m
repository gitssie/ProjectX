#import "../adapters/PXASNative.h"
#import <Security/Security.h>
// Override only the Security call boundary; exercise the actual native adapter.
@interface PXASSecurityKeychain (TestSeam)
- (BOOL)authority:(NSArray *)groups error:(NSError **)error;
- (OSStatus)copyMatching:(NSDictionary *)query result:(CFTypeRef *)result;
- (OSStatus)addItem:(NSDictionary *)item;
- (OSStatus)deleteQuery:(NSDictionary *)query;
- (OSStatus)updateQuery:(NSDictionary *)query attributes:(NSDictionary *)attributes;
@end
static NSUInteger passed;
static void Assert(BOOL ok,NSString *message){if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}passed++;}
static NSString *const Group=@"TESTTEAM.com.example.state";
static NSDictionary *Record(BOOL sync,NSString *account,NSString *secret){
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccessGroup:Group,(__bridge id)kSecAttrSynchronizable:@(sync),
        (__bridge id)kSecAttrAccount:account,(__bridge id)kSecAttrService:@"ExampleSession",
        (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlock,
        (__bridge id)kSecValueData:[secret dataUsingEncoding:NSUTF8StringEncoding]};
}
@interface MemorySecurity : PXASSecurityKeychain
@property(nonatomic,strong) NSMutableArray *items;
@property(nonatomic) NSUInteger deletes;
@property(nonatomic) NSUInteger updates;
@property(nonatomic) NSUInteger anyQueries;
@property(nonatomic) BOOL allowSyncDeletes;
@end
@implementation MemorySecurity
- (BOOL)authority:(NSArray *)groups error:(NSError **)error{(void)error;return [groups isEqual:@[Group]];}
- (BOOL)matches:(NSDictionary *)item query:(NSDictionary *)query{
    for(id key in @[(__bridge id)kSecClass,(__bridge id)kSecAttrAccessGroup,(__bridge id)kSecAttrAccount,(__bridge id)kSecAttrService,
        (__bridge id)kSecAttrServer,(__bridge id)kSecAttrPort,(__bridge id)kSecAttrProtocol,(__bridge id)kSecAttrAuthenticationType,
        (__bridge id)kSecAttrSecurityDomain,(__bridge id)kSecAttrPath])
        if(query[key] && ![query[key] isEqual:item[key]])return NO;
    id sync=query[(__bridge id)kSecAttrSynchronizable];
    return [sync isEqual:(__bridge id)kSecAttrSynchronizableAny] || [sync isEqual:item[(__bridge id)kSecAttrSynchronizable]];
}
- (OSStatus)copyMatching:(NSDictionary *)query result:(CFTypeRef *)result{
    Assert([query[(__bridge id)kSecAttrSynchronizable] isEqual:(__bridge id)kSecAttrSynchronizableAny],@"exports must query both sync states");self.anyQueries++;
    NSMutableArray *found=[NSMutableArray array];for(NSDictionary *item in self.items)if([self matches:item query:query])[found addObject:item];
    if(!found.count)return errSecItemNotFound;
    *result=CFBridgingRetain(found);return errSecSuccess;
}
- (OSStatus)deleteQuery:(NSDictionary *)query{
    if([query[(__bridge id)kSecAttrSynchronizable] boolValue])
        Assert(self.allowSyncDeletes && query[(__bridge id)kSecAttrAccount] && (query[(__bridge id)kSecAttrService] || query[(__bridge id)kSecAttrServer]),@"authorized sync deletion uses exact item identity");
    else Assert([query[(__bridge id)kSecAttrSynchronizable] isEqual:@NO],@"snapshot deletion remains nonsync-only");self.deletes++;
    NSIndexSet *indexes=[self.items indexesOfObjectsPassingTest:^BOOL(NSDictionary *item,NSUInteger index,BOOL *stop){(void)index;(void)stop;return [self matches:item query:query];}];
    [self.items removeObjectsAtIndexes:indexes];return indexes.count?errSecSuccess:errSecItemNotFound;
}
- (OSStatus)addItem:(NSDictionary *)item{
    Assert(CFGetTypeID((__bridge CFTypeRef)item[(__bridge id)kSecAttrSynchronizable])==CFBooleanGetTypeID(),@"Security add input has typed Boolean sync flag");
    [self.items addObject:item];return errSecSuccess;
}
- (OSStatus)updateQuery:(NSDictionary *)query attributes:(NSDictionary *)attributes{
    Assert([query[(__bridge id)kSecAttrSynchronizable] isEqual:@YES] && query[(__bridge id)kSecAttrAccount] &&
        (query[(__bridge id)kSecAttrService] || query[(__bridge id)kSecAttrServer]),@"sync update identifies one exact item");
    Assert(CFGetTypeID((__bridge CFTypeRef)query[(__bridge id)kSecAttrSynchronizable])==CFBooleanGetTypeID(),@"Security update query has typed Boolean sync flag");
    Assert(!attributes[(__bridge id)kSecClass] && !attributes[(__bridge id)kSecAttrAccessible],@"sync update excludes immutable protection attributes");
    self.updates++;
    for(NSUInteger i=0;i<self.items.count;i++)if([self matches:self.items[i] query:query]){
        NSMutableDictionary *updated=[self.items[i] mutableCopy];[updated addEntriesFromDictionary:attributes];self.items[i]=updated;return errSecSuccess;
    }
    return errSecItemNotFound;
}
@end
int main(void){@autoreleasepool{
    NSError *scopeError=nil;
    NSDictionary *scopeEnt=@{@"application-identifier":Group,@"keychain-access-groups":@[@"TESTTEAM.shared",Group],@"com.apple.security.application-groups":@[@"group.example.shared"]};
    Assert([PXASKeychainGroupsFromEntitlements(scopeEnt,@"com.example.state",&scopeError) isEqual:@[@"TESTTEAM.shared",Group,@"group.example.shared"]],@"derive effective scope from explicit groups, App ID and signed App Groups with deduplication");
    Assert([PXASKeychainGroupsFromEntitlements(@{@"application-identifier":Group},@"com.example.state",&scopeError) isEqual:@[Group]],@"App ID remains queryable without explicit access groups");
    Assert(PXASKeychainGroupsFromEntitlements(scopeEnt,@"com.other.app",&scopeError)==nil,@"reject mismatched signed app identity");
    Assert(PXASKeychainGroupsFromEntitlements(@{@"application-identifier":Group,@"keychain-access-groups":@[@"OTHERTEAM.secret"]},@"com.example.state",&scopeError)==nil,@"reject cross-team explicit keychain scope");
    Assert(PXASKeychainGroupsFromEntitlements(@{@"application-identifier":Group,@"com.apple.security.application-groups":@[@"com.apple.system"]},@"com.example.state",&scopeError)==nil,@"reject system group masquerading as App Group");
    MemorySecurity *adapter=[[MemorySecurity alloc] initWithApplicationIdentifier:@"TESTTEAM.com.example.state"];
    NSDictionary *local=Record(NO,@"device",@"local"),*sync=Record(YES,@"refresh-token",@"saved-token");
    adapter.items=[@[local,sync] mutableCopy];NSError *error=nil;
    NSArray *exported=[adapter exportGroups:@[Group] error:&error];
    Assert(exported.count==2 && [exported containsObject:local] && [exported containsObject:sync],@"native export preserves true and false with data");
    Assert([adapter validateRecords:exported groups:@[Group] error:&error],@"both sync states validate");
    NSMutableDictionary *numberFlag=[sync mutableCopy];numberFlag[(__bridge id)kSecAttrSynchronizable]=[NSNumber numberWithInt:1];
    Assert([adapter validateRecords:@[numberFlag] groups:@[Group] error:&error],@"Security numeric zero/one sync representation validates");
    adapter.items=[@[local] mutableCopy];
    Assert([adapter replaceGroups:@[Group] records:@[local,numberFlag] error:&error],@"numeric archived sync flag restores through typed Security input");
    adapter.items=[@[local,sync] mutableCopy];adapter.deletes=0;adapter.updates=0;
    NSMutableDictionary *stringGeneric=[local mutableCopy];stringGeneric[(__bridge id)kSecAttrGeneric]=@"stored-string";
    adapter.items=[@[stringGeneric,sync] mutableCopy];
    Assert([[adapter exportGroups:@[Group] error:&error] containsObject:stringGeneric],@"existing string generic attribute exports without conversion");
    adapter.items=[@[local,sync] mutableCopy];
    Assert(![adapter validateRecords:@[sync,sync] groups:@[Group] error:&error],@"duplicate identity rejected");
    NSMutableDictionary *invalid=[sync mutableCopy];invalid[(__bridge id)kSecAttrSynchronizable]=@"YES";
    Assert(![adapter validateRecords:@[invalid] groups:@[Group] error:&error],@"archive invalid field type rejected");
    NSArray *supplemented=[adapter supplementSynchronizableRecords:@[local] groups:@[Group] error:&error];
    Assert(supplemented.count==2 && [supplemented containsObject:sync] && adapter.deletes==0 && adapter.updates==0,@"supplement reads only and preserves original local records");
    adapter.items=[@[local,Record(YES,@"refresh-token",@"anonymous-token")] mutableCopy];
    Assert([adapter replaceGroups:@[Group] records:@[local,sync] error:&error],@"restore replaces token data without deleting sync row");
    Assert(adapter.updates==1 && [adapter.items containsObject:sync],@"saved refresh token and sync flag survive readback");
    adapter.allowSyncDeletes=YES;
    NSDictionary *extra=Record(YES,@"new-apple-profile",@"extra-data");
    NSMutableDictionary *unrelated=[extra mutableCopy];unrelated[(__bridge id)kSecAttrAccessGroup]=@"OTHERTEAM.unrelated";
    adapter.items=[@[local,sync,extra,unrelated] mutableCopy];NSUInteger updates=adapter.updates;
    Assert([adapter replaceGroups:@[Group] records:@[local,sync] error:&error] && ![adapter.items containsObject:extra] &&
        [adapter.items containsObject:sync] && [adapter.items containsObject:unrelated] && adapter.updates==updates,@"snapshot deletes only extra target-scope sync record and preserves desired sync plus unrelated groups");
    Assert([adapter replaceGroups:@[Group] records:@[] error:&error] && [adapter.items isEqual:@[unrelated]],@"empty snapshot removes all target records in both sync states");
    adapter.items=[@[local,sync] mutableCopy];NSUInteger deletes=adapter.deletes;
    NSMutableDictionary *protected=[sync mutableCopy];protected[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleWhenUnlocked;
    Assert(![adapter replaceGroups:@[Group] records:@[local,protected] error:&error] && adapter.deletes==deletes,@"protection mismatch fails before local deletion");
    NSMutableDictionary *labelled=[sync mutableCopy];labelled[(__bridge id)kSecAttrLabel]=@"existing-label";adapter.items=[@[local,labelled] mutableCopy];
    Assert(![adapter replaceGroups:@[Group] records:@[local,sync] error:&error] && adapter.deletes==deletes,@"unsupported sync attribute removal fails before mutation");
    adapter.items=[@[local] mutableCopy];
    Assert([adapter replaceGroups:@[Group] records:@[local,sync] error:&error] && [adapter.items containsObject:sync],@"missing archived sync row is added with true flag");
    adapter.items=[@[Record(NO,@"device",@"other-device"),sync] mutableCopy];
    Assert([adapter supplementSynchronizableRecords:@[local] groups:@[Group] error:&error]==nil,@"different local identity rejects archive supplement");
    adapter.items=[@[local] mutableCopy];deletes=adapter.deletes;
    for(NSDictionary *bad in @[@{(__bridge id)kSecAttrAccount:@[]},@{(__bridge id)kSecAttrAccessible:@[]},
        @{(__bridge id)kSecAttrAccessible:@"cku"},@{(__bridge id)kSecAttrPort:@"invalid"}]){
        NSMutableDictionary *record=[sync mutableCopy];[record addEntriesFromDictionary:bad];
        Assert(![adapter replaceGroups:@[Group] records:@[local,record] error:&error] && adapter.deletes==deletes,@"invalid archived attributes reject before deleting local records");
    }
    NSMutableDictionary *internet=[sync mutableCopy];internet[(__bridge id)kSecClass]=(__bridge id)kSecClassInternetPassword;
    [internet removeObjectForKey:(__bridge id)kSecAttrService];
    [internet addEntriesFromDictionary:@{(__bridge id)kSecAttrServer:@"example.test",(__bridge id)kSecAttrPort:@443,
        (__bridge id)kSecAttrProtocol:(__bridge id)kSecAttrProtocolHTTPS,(__bridge id)kSecAttrAuthenticationType:(__bridge id)kSecAttrAuthenticationTypeDefault,
        (__bridge id)kSecAttrSecurityDomain:@"",(__bridge id)kSecAttrPath:@"/session"}];
    NSMutableDictionary *oldInternet=[internet mutableCopy];oldInternet[(__bridge id)kSecValueData]=[@"old" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *otherInternet=[internet mutableCopy];otherInternet[(__bridge id)kSecAttrPath]=@"/other";
    adapter.items=[@[local,oldInternet,otherInternet] mutableCopy];
    Assert([adapter replaceGroups:@[Group] records:@[local,internet,otherInternet] error:&error] &&
        [adapter.items containsObject:internet] && [adapter.items containsObject:otherInternet],@"internet-password upsert respects server/port/path identity");
    NSMutableDictionary *outside=[sync mutableCopy];outside[(__bridge id)kSecAttrAccessGroup]=@"OTHERTEAM.unrelated";
    adapter.items=[@[local,sync,internet,outside] mutableCopy];adapter.allowSyncDeletes=YES;
    Assert([adapter validateBaselineResetGroups:@[Group] error:&error] && [adapter resetGroupsForBaseline:@[Group] error:&error],@"explicit baseline clears sync and nonsync records");
    Assert([adapter.items isEqual:@[outside]],@"baseline preserves unrelated keychain groups");
    printf("%lu native keychain assertions passed; Security calls mocked.\n",(unsigned long)passed);
}return 0;}
