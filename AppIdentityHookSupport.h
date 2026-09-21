#import <Foundation/Foundation.h>

#import "AppIdentity.h"
#import "GraphicsIdentity.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT PXAppIdentityRecord * _Nullable PXPrepareCurrentProcessAppIdentity(void);
FOUNDATION_EXPORT PXAppGroupIdentityRecord * _Nullable PXPrepareCurrentProcessGroupIdentity(NSString *groupIdentifier);
FOUNDATION_EXPORT NSDictionary<NSString *, PXAppGroupIdentityRecord *> *
    PXPrepareCurrentProcessGroupIdentities(NSSet<NSString *> *groupIdentifiers);
FOUNDATION_EXPORT BOOL PXPrepareCurrentProcessDataPathMapping(PXAppIdentityRecord *identity);
FOUNDATION_EXPORT void PXObserveAppIdentityMappingChanges(void);
FOUNDATION_EXPORT BOOL PXAppIdentityMappingsChangedSinceLaunch(void);
FOUNDATION_EXPORT NSString *PXVirtualDataContainerRoot(NSString *containerUUID);
FOUNDATION_EXPORT NSString *PXVirtualAppGroupRoot(NSString *containerUUID);
FOUNDATION_EXPORT PXGraphicsIdentity * _Nullable PXPrepareCurrentProcessGraphicsIdentity(void);
FOUNDATION_EXPORT void PXInvalidateCurrentProcessGraphicsIdentity(void);
FOUNDATION_EXPORT NSUUID * _Nullable PXPrepareScopedVendorIdentifier(
    NSString *bundleIdentifier,
    NSString *identityDirectory
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable PXPrepareScopedNetworkIdentity(
    NSString *bundleIdentifier,
    NSString *identityDirectory
);
FOUNDATION_EXPORT NSUUID * _Nullable PXPrepareCurrentProcessVendorIdentifier(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable PXPrepareCurrentProcessNetworkIdentity(void);

NS_ASSUME_NONNULL_END
