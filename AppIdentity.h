#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *PXNormalizedInstallIdentifierKey(NSString *key);
FOUNDATION_EXPORT BOOL PXInstallIdentifierKeyMatches(NSString *key,
                                                      NSSet<NSString *> *configuredKeys);
FOUNDATION_EXPORT BOOL PXIsValidRealDataContainerRoot(NSString *path);
FOUNDATION_EXPORT BOOL PXIsValidRealAppGroupRoot(NSString *path);
FOUNDATION_EXPORT BOOL PXAppIdentityBundleIsEligible(NSString * _Nullable bundleIdentifier,
                                                     BOOL applicationEnabled,
                                                     BOOL extensionEnabled);
FOUNDATION_EXPORT BOOL PXDeviceIdentifierSpoofingIsAllowedForBundle(
    NSString * _Nullable bundleIdentifier,
    BOOL applicationEnabled
);
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
PXEligibleScopedApplications(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopedApplications
);
FOUNDATION_EXPORT NSSet<NSString *> *PXEnabledEligibleAppBundleIdentifiers(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *scopedApplications
);

@interface PXAppIdentityRecord : NSObject

@property (nonatomic, copy, readonly) NSString *installUUID;
@property (nonatomic, copy, readonly) NSString *containerUUID;
@property (nonatomic, copy, readonly) NSSet<NSString *> *installIdentifierKeys;

+ (instancetype)identityForProfileSeed:(NSString *)profileSeed
                       bundleIdentifier:(NSString *)bundleIdentifier
                   installIdentifierKeys:(nullable NSSet<NSString *> *)installIdentifierKeys;
- (NSDictionary<NSString *, id> *)propertyListRepresentation;
+ (nullable instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList;

@end

@interface PXAppInstallIdentityPolicy : NSObject

- (instancetype)initWithIdentity:(PXAppIdentityRecord *)identity;
- (id)valueForRead:(nullable id)originalValue key:(NSString *)key requestedClass:(Class)requestedClass;
- (id)valueForWrite:(nullable id)proposedValue key:(NSString *)key;
- (NSDictionary *)dictionaryByVirtualizingInstallKeys:(NSDictionary *)dictionary;

@end

@interface PXAppPathMapper : NSObject

- (nullable instancetype)initWithRealDataRoot:(NSString *)realDataRoot
                               virtualDataRoot:(NSString *)virtualDataRoot;
- (NSString *)translatedRealPathForPath:(NSString *)path;
- (NSString *)translatedObservablePathForPath:(NSString *)path;
- (nullable instancetype)mapperByAddingRealGroupRoot:(NSString *)realGroupRoot
                                     virtualGroupRoot:(NSString *)virtualGroupRoot;

@end

@interface PXAppIdentityRuntime : NSObject

+ (instancetype)sharedRuntime;
- (BOOL)configureRealDataRoot:(NSString *)realDataRoot virtualDataRoot:(NSString *)virtualDataRoot;
- (BOOL)addRealGroupRoot:(NSString *)realGroupRoot virtualGroupRoot:(NSString *)virtualGroupRoot;
- (NSString *)translatedRealPathForPath:(NSString *)path;
- (NSString *)translatedObservablePathForPath:(NSString *)path;
- (NSURL *)translatedRealFileURLForURL:(NSURL *)url;
- (NSURL *)translatedObservableFileURLForURL:(NSURL *)url;

@end

@interface PXAppGroupIdentityRecord : NSObject

@property (nonatomic, copy, readonly) NSString *containerUUID;

+ (instancetype)identityForProfileSeed:(NSString *)profileSeed
                        groupIdentifier:(NSString *)groupIdentifier;
- (NSDictionary<NSString *, id> *)propertyListRepresentation;
+ (nullable instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList;

@end

NS_ASSUME_NONNULL_END
