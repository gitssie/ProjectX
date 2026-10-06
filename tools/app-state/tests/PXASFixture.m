#import "PXASFixture.h"
static BOOL Reject(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
@implementation PXASFixture
- (NSDictionary *)resolve:(NSString *)bundleID error:(NSError **)error {
    if (![bundleID isEqual:self.target[@"bundleID"]]) { Reject(error,@"Unknown fixture bundle"); return nil; }
    return self.target;
}
- (BOOL)assertStopped:(NSDictionary *)target error:(NSError **)error {
    (void)target; return !self.running || Reject(error,@"Fixture app is running");
}
- (NSArray *)exportGroups:(NSArray *)groups error:(NSError **)error {
    if(self.exportHook)self.exportHook();
    if(self.failExportOnce){self.failExportOnce=NO;Reject(error,@"Injected export failure");return nil;}
    return [self validateRecords:self.records groups:groups error:error] ? self.records : nil;
}
- (BOOL)validateRecords:(NSArray *)records groups:(NSArray *)groups error:(NSError **)error {
    for (NSDictionary *record in records) {
        if (![groups containsObject:record[@"group"]] ||
            ![@[@NO,@YES] containsObject:record[@"synchronizable"]])
            return Reject(error,@"Fixture record outside exact scope");
    }
    return YES;
}
- (BOOL)validateReplacement:(NSArray *)records groups:(NSArray *)groups error:(NSError **)error {
    return [self validateRecords:records groups:groups error:error];
}
- (BOOL)replaceGroups:(NSArray *)groups records:(NSArray *)records error:(NSError **)error {
    if (![self validateReplacement:records groups:groups error:error]) return NO;
    self.replacementCount++; self.records = [self.records filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *record,NSDictionary *bindings){(void)bindings;return [record[@"synchronizable"] boolValue];}]];
    if (self.failAfterKeychainClear) { self.failAfterKeychainClear = NO; return Reject(error,@"Injected failure after clear"); }
    self.records = records; return YES;
}
- (BOOL)validateBaselineResetGroups:(NSArray *)groups error:(NSError **)error {
    return [self exportGroups:groups error:error]!=nil;
}
- (BOOL)resetGroupsForBaseline:(NSArray *)groups error:(NSError **)error {
    if(![self validateBaselineResetGroups:groups error:error])return NO;
    self.replacementCount++;self.records=@[];
    if(self.failAfterKeychainClear){self.failAfterKeychainClear=NO;return Reject(error,@"Injected failure after baseline clear");}
    return YES;
}
- (NSArray *)supplementSynchronizableRecords:(NSArray *)records groups:(NSArray *)groups error:(NSError **)error {
    if(![self validateRecords:records groups:groups error:error])return nil;
    NSArray *current=[self exportGroups:groups error:error];if(!current)return nil;
    NSPredicate *local=[NSPredicate predicateWithBlock:^BOOL(NSDictionary *record,NSDictionary *bindings){(void)bindings;return ![record[@"synchronizable"] boolValue];}];
    NSArray *savedLocal=[records filteredArrayUsingPredicate:local],*currentLocal=[current filteredArrayUsingPredicate:local];
    if(![[NSSet setWithArray:savedLocal] isEqual:[NSSet setWithArray:currentLocal]]){Reject(error,@"Local records differ");return nil;}
    NSMutableArray *merged=[NSMutableArray arrayWithArray:savedLocal];
    for(NSDictionary *record in current)if([record[@"synchronizable"] boolValue])[merged addObject:record];
    return merged;
}
- (NSDictionary *)capture:(NSDictionary *)target error:(NSError **)error {
    (void)target; (void)error; return self.identityState;
}
- (BOOL)validateState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error {
    (void)target; return state[@"IDFV"] != nil || Reject(error,@"Identity missing");
}
- (BOOL)restoreState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error {
    if (![self validateState:state target:target error:error]) return NO;
    self.identityState = state;
    if (self.failIdentityOnce) { self.failIdentityOnce = NO; return Reject(error,@"Injected identity failure after mutation"); }
    return YES;
}
@end
