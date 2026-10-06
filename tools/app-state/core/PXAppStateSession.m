#import "PXAppStateSession.h"

static BOOL SessionFail(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"PXAppStateSession" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
@interface PXAppStateSession ()
@property (nonatomic, strong) id<PXAppStateSessionBackend> backend;
@end
@implementation PXAppStateSession
- (instancetype)initWithBackend:(id<PXAppStateSessionBackend>)backend {
    if ((self=[super init])) _backend=backend;
    return self;
}
- (NSDictionary *)entry:(NSString *)reference catalog:(NSArray *)catalog {
    for (NSDictionary *entry in catalog) if ([entry[@"reference"] isEqual:reference]) return entry;
    return nil;
}
- (NSDictionary *)save:(NSDictionary *)current metadata:(NSDictionary *)metadata target:(NSDictionary *)target error:(NSError **)error {
    NSString *name=current ? [current[@"reference"] lastPathComponent] : @"auto";
    NSDictionary *result=[self.backend captureName:name replace:current!=nil metadata:metadata error:error];
    if (!result) return nil;
    NSDictionary *association=@{@"reference":result[@"reference"],@"containers":target[@"containers"]};
    if (![self.backend writeAssociation:association error:error]) return nil;
    return association;
}
- (NSDictionary *)perform:(NSDictionary *)request error:(NSError **)error {
    NSString *operation=request[@"operation"];
    if (![@[@"catalog",@"save",@"switch",@"edit",@"delete",@"baseline"] containsObject:operation]) {
        SessionFail(error,@"Unknown app-state operation"); return nil;
    }
    NSArray *catalog=[self.backend catalog:error]; if (!catalog) return nil;
    NSDictionary *target=[self.backend target:error]; if (!target) return nil;
    NSDictionary *association=[self.backend association:error]; if (error && *error) return nil;
    BOOL restorePending=[association[@"restorePending"] boolValue];
    NSDictionary *current=[self entry:association[@"reference"] catalog:catalog];
    NSString *liveIDFV=[target[@"IDFV"] isKindOfClass:NSString.class]?[[[NSUUID alloc] initWithUUIDString:target[@"IDFV"]] UUIDString]:nil;
    NSMutableArray *identityMatches=[NSMutableArray array];
    if(liveIDFV)for(NSDictionary *entry in catalog) {
        if([entry[@"kind"] isEqual:@"snapshot"] && [entry[@"IDFV"] isEqual:liveIDFV])[identityMatches addObject:entry];
    }
    if (restorePending)current=nil;
    else if (![current[@"kind"] isEqual:@"snapshot"] || ![association[@"containers"] isEqual:target[@"containers"]] ||
        (liveIDFV && ![current[@"IDFV"] isEqual:liveIDFV])) {
        current=nil;
        if (association && ![self.backend writeAssociation:nil error:error]) return nil;
    }
    if(identityMatches.count==1 && !restorePending) {
        current=identityMatches.firstObject;
        NSDictionary *inferred=@{@"reference":current[@"reference"],@"containers":target[@"containers"]};
        if(![association isEqual:inferred] && ![self.backend writeAssociation:inferred error:error])return nil;
    }
    if ([operation isEqual:@"catalog"]) {
        NSMutableDictionary *result=[@{@"entries":catalog,@"currentReference":current[@"reference"]?:@""} mutableCopy];
        result[@"restorePending"]=@(restorePending);
        if(identityMatches.count>1)result[@"duplicateIdentityReferences"]=[identityMatches valueForKey:@"reference"];
        return result;
    }
    NSDictionary *metadata=request[@"account"];
    if (metadata && (![metadata isKindOfClass:NSDictionary.class] || metadata.count!=2 ||
        ![metadata[@"displayName"] isKindOfClass:NSString.class] || ![metadata[@"note"] isKindOfClass:NSString.class] ||
        [metadata[@"displayName"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length==0 ||
        [metadata[@"displayName"] length]>100 || [metadata[@"note"] length]>1000)) {
        SessionFail(error,@"Invalid account name or note"); return nil;
    }
    if ([operation isEqual:@"baseline"]) {
        if(metadata){SessionFail(error,@"Baseline does not contain account metadata");return nil;}
        BOOL exists=NO;for(NSDictionary *entry in catalog)if([entry[@"kind"] isEqual:@"baseline"] && [entry[@"version"] isEqual:target[@"version"]])exists=YES;
        if(!exists && ![self.backend createBaseline:error])return nil;
    } else if ([operation isEqual:@"save"]) {
        if(restorePending){SessionFail(error,@"Retry restoration before backing up this incomplete environment.");return nil;}
        BOOL newAccount=[request[@"saveAsNew"] boolValue];
        if(identityMatches.count>1){SessionFail(error,[NSString stringWithFormat:@"Multiple backups share the current IDFV. Keep one before saving: %@",[[identityMatches valueForKey:@"reference"] componentsJoinedByString:@", "]]);return nil;}
        if(newAccount && identityMatches.count==1){SessionFail(error,@"This IDFV already has a backup. Update it, or use a baseline before saving another account.");return nil;}
        if (newAccount) current=nil;
        if (!current && !metadata) { SessionFail(error,@"Name this account before its first backup"); return nil; }
        if (newAccount && ![self.backend writeAssociation:nil error:error]) return nil;
        if (![self save:current metadata:metadata target:target error:error]) return nil;
    } else {
        NSString *reference=request[@"reference"];
        NSDictionary *destination=[self entry:reference catalog:catalog];
        if (!destination) { SessionFail(error,@"The selected backup is unavailable"); return nil; }
        if ([operation isEqual:@"edit"] || [operation isEqual:@"delete"]) {
            if (![destination[@"kind"] isEqual:@"snapshot"]) { SessionFail(error,@"Account operation requires a snapshot"); return nil; }
            if ([operation isEqual:@"edit"]) {
                if (!metadata || ![self.backend edit:reference metadata:metadata error:error]) return nil;
            } else {
                if ([current[@"reference"] isEqual:reference]) { SessionFail(error,@"Switch away before deleting this account backup"); return nil; }
                if (![self.backend remove:reference error:error]) return nil;
            }
        } else if (![current[@"reference"] isEqual:reference]) {
            if(![request[@"discardCurrent"] boolValue] && identityMatches.count>1 && (current || metadata)) {SessionFail(error,@"Multiple backups share the current IDFV. Keep one before updating this environment.");return nil;}
            if(restorePending && metadata){SessionFail(error,@"Retry restoration before backing up this incomplete environment.");return nil;}
            if (![request[@"discardCurrent"] boolValue] && (current || metadata)) {
                if (![self save:current metadata:metadata target:target error:error]) return nil;
            } else if (!restorePending && ![request[@"discardCurrent"] boolValue]) {
                SessionFail(error,@"Save the current environment or explicitly discard it before switching"); return nil;
            }
            // A durable pending marker prevents IDFV inference from reactivating
            // either the source or destination after failure/crash mid-restore.
            if (![self.backend writeAssociation:@{@"reference":@"",@"containers":target[@"containers"],@"restorePending":@YES,@"pendingReference":reference} error:error]) return nil;
            if (![self.backend restore:reference error:error]) return nil;
            NSDictionary *restoredAssociation=[destination[@"kind"] isEqual:@"snapshot"]?@{@"reference":reference,@"containers":target[@"containers"]}:nil;
            if(![self.backend writeAssociation:restoredAssociation error:error])return nil;
        }
    }
    return [self perform:@{@"operation":@"catalog"} error:error];
}
@end
