#import <Foundation/Foundation.h>
#import "AppIdentity.h"
#import "GraphicsIdentity.h"
#import "PXEnvironmentPolicy.h"

NS_ASSUME_NONNULL_BEGIN

@interface PXVirtualRuntimeSession : NSObject

@property (nonatomic, copy, readonly) NSString *bootUUID;
@property (nonatomic, copy, readonly) NSDate *bootTime;

- (instancetype)initWithBootUUID:(NSString *)bootUUID bootTime:(NSDate *)bootTime;
- (NSDictionary<NSString *, id> *)propertyListRepresentation;
+ (nullable instancetype)sessionWithPropertyList:(NSDictionary<NSString *, id> *)propertyList;

@end

@interface PXProfileGenerationInput : NSObject

@property (nonatomic, copy) NSData *seed;
@property (nonatomic, copy) NSDate *generatedAt;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *modelCatalog;
@property (nonatomic, copy) NSDictionary<NSString *, id> *physicalModelRecord;
@property (nonatomic, assign) BOOL usesPhysicalDeviceModel;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *iOSCatalog;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *carrierCatalog;
@property (nonatomic, copy) NSSet<NSString *> *trustedCarrierIDs;
@property (nonatomic, copy) NSDictionary<NSString *, id> *pinnedLocation;
@property (nonatomic, copy) NSDictionary<NSString *, id> *region;
@property (nonatomic, copy) NSSet<NSString *> *appBundleIdentifiers;
@property (nonatomic, copy) NSSet<NSString *> *appGroupIdentifiers;
@property (nonatomic, copy) NSDictionary<NSString *, NSSet<NSString *> *> *installIdentifierKeysByBundleIdentifier;
@property (nonatomic, copy) NSDictionary<NSString *, id> *graphicsHostCapabilities;
@property (nonatomic, assign) PXEnvironmentNetworkType networkType;
@property (nonatomic, copy) NSSet<NSNumber *> *networkTypes;

@end

@interface PXProfileManifest : NSObject

@property (nonatomic, copy, readonly) NSString *generationID;
@property (nonatomic, copy, readonly) NSString *seed;
@property (nonatomic, copy, readonly) NSDate *generatedAt;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *device;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *operatingSystem;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *identifiers;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *network;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *region;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *location;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *graphics;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, PXAppIdentityRecord *> *appIdentities;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, PXAppGroupIdentityRecord *> *appGroupIdentities;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *fieldSourcePolicy;
@property (nonatomic, strong, readonly) PXVirtualRuntimeSession *virtualSession;

- (NSDictionary<NSString *, id> *)propertyListRepresentation;
- (BOOL)validateWithError:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)manifestWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                             error:(NSError * _Nullable * _Nullable)error;

@end

FOUNDATION_EXPORT NSUUID * _Nullable PXProfileVendorIdentifierForBundleIdentifier(
    PXProfileManifest * _Nullable manifest,
    NSString * _Nullable bundleIdentifier
);

@interface PXProfileGenerator : NSObject

- (nullable PXProfileManifest *)generateManifestWithInput:(PXProfileGenerationInput *)input
                                                     error:(NSError * _Nullable * _Nullable)error;

@end

@interface PXProfileStore : NSObject

@property (nonatomic, assign) BOOL failBeforePromotionForTesting;

- (instancetype)initWithIdentityDirectory:(NSString *)identityDirectory;
- (BOOL)promoteManifest:(PXProfileManifest *)manifest error:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceActiveIdentifierValue:(NSString *)value
                              forKey:(NSString *)key
                               error:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceActiveLocalIPAddress:(NSString *)ipv4
                       IPv6Address:(NSString *)ipv6
                             error:(NSError * _Nullable * _Nullable)error;
- (nullable NSString *)activeGenerationIDWithError:(NSError * _Nullable * _Nullable)error;
- (nullable PXProfileManifest *)activeManifestWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)activeApplicationIdentityPropertyListsWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceActiveApplicationIdentityPropertyLists:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)appIdentities
                                                 error:(NSError * _Nullable * _Nullable)error;
- (BOOL)ensureApplicationIdentityForBundleIdentifier:(NSString *)bundleIdentifier
                                     groupIdentifiers:(NSSet<NSString *> *)groupIdentifiers
                                installIdentifierKeys:(NSSet<NSString *> *)installIdentifierKeys
                                                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
