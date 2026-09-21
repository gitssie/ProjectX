#import "PXTargetSelectionServices.h"

#import "IdentifierManager.h"
#import "ProfileManifest.h"
#import "PXEnvironmentPolicy.h"
#import "PXRootHidePath.h"

@interface PXCurrentProfileTargetIdentityStore : NSObject <PXTargetSelectionIdentityStoring>
@property (nonatomic, strong) IdentifierManager *identifierManager;
@end

@implementation PXCurrentProfileTargetIdentityStore

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)activeApplicationIdentityPropertyListsWithError:(NSError **)error {
    PXProfileStore *profileStore = [[PXProfileStore alloc]
        initWithIdentityDirectory:[self.identifierManager profileIdentityPath]];
    return [profileStore activeApplicationIdentityPropertyListsWithError:error];
}

- (BOOL)replaceActiveApplicationIdentityPropertyLists:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)appIdentities
                                                 error:(NSError **)error {
    PXProfileStore *profileStore = [[PXProfileStore alloc]
        initWithIdentityDirectory:[self.identifierManager profileIdentityPath]];
    return [profileStore replaceActiveApplicationIdentityPropertyLists:appIdentities error:error];
}

@end


@interface PXTargetSelectionServices ()
@property (nonatomic, strong, readwrite) id<PXInstalledAppSnapshotProviding> snapshotProvider;
@property (nonatomic, strong, readwrite) PXTargetSelectionReconciler *reconciler;
- (instancetype)initPrivate NS_DESIGNATED_INITIALIZER;
@end


@implementation PXTargetSelectionServices

+ (instancetype)sharedServices {
    static PXTargetSelectionServices *services = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        services = [[self alloc] initPrivate];
    });
    return services;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        IdentifierManager *identifierManager = [IdentifierManager sharedManager];
        PXCurrentProfileTargetIdentityStore *identityStore =
            [[PXCurrentProfileTargetIdentityStore alloc] init];
        identityStore.identifierManager = identifierManager;
        PXAtomicTargetSelectionStateStore *stateStore =
            [[PXAtomicTargetSelectionStateStore alloc]
                initWithScopeFilePath:PXGlobalScopePreferencesPath()
                policyStore:(id<PXTargetSelectionPolicyStoring>)[PXEnvironmentPolicyStore sharedStore]
                identityStore:identityStore
                cacheInvalidator:^{
                    [identifierManager reloadApplicationScope];
                }
                notificationPublisher:^(NSString *notificationName) {
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                         (__bridge CFStringRef)notificationName,
                                                         NULL,
                                                         NULL,
                                                         YES);
                }];
        _snapshotProvider = [[PXLaunchServicesInstalledAppSnapshotProvider alloc] init];
        _reconciler = [[PXTargetSelectionReconciler alloc]
            initWithSnapshotProvider:_snapshotProvider
            stateStore:stateStore];
    }
    return self;
}

@end
