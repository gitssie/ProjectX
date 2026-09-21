#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const PXGraphicsIdentityErrorDomain;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityErrorDomain;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityMismatchFieldsErrorKey;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityReasonErrorKey;

FOUNDATION_EXPORT NSString * const PXModelCompatibilityReasonPhysicalUnavailable;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityReasonImmutableHardwareMismatch;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityReasonHostCapabilitiesUnavailable;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityReasonCandidateInvalid;

FOUNDATION_EXPORT NSString * const PXModelCompatibilityFieldMarketingFamily;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityFieldCPUClass;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityFieldGraphicsClass;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityFieldMemoryClass;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityFieldDisplayClass;
FOUNDATION_EXPORT NSString * const PXModelCompatibilityFieldHostGraphics;

typedef NS_ENUM(NSInteger, PXModelCompatibilityErrorCode) {
    PXModelCompatibilityErrorPhysicalUnavailable = 1,
    PXModelCompatibilityErrorImmutableHardwareMismatch = 2,
    PXModelCompatibilityErrorHostCapabilitiesUnavailable = 3,
    PXModelCompatibilityErrorCandidateInvalid = 4
};

FOUNDATION_EXPORT NSDictionary<NSString *, id> *PXCurrentGraphicsHostCapabilities(void);
FOUNDATION_EXPORT BOOL PXGraphicsModelRecordIsCompatibleWithHostCapabilities(
    NSDictionary<NSString *, id> *modelRecord,
    NSDictionary<NSString *, id> *hostCapabilities,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT BOOL PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
    NSDictionary<NSString *, id> *candidateModelRecord,
    NSDictionary<NSString *, id> * _Nullable physicalModelRecord,
    NSDictionary<NSString *, id> *hostCapabilities,
    NSError * _Nullable * _Nullable error
);

@class PXGraphicsIdentity;

FOUNDATION_EXPORT NSUInteger PXGraphicsClampedLimit(PXGraphicsIdentity *identity,
                                                     NSString *key,
                                                     NSUInteger hostLimit);
FOUNDATION_EXPORT NSArray<NSString *> *PXGraphicsFilteredExtensions(
    NSArray<NSString *> *targetExtensions,
    NSArray<NSString *> *hostExtensions
);
FOUNDATION_EXPORT BOOL PXGraphicsAllowsMetalFamily(PXGraphicsIdentity *identity,
                                                    NSUInteger family,
                                                    BOOL hostSupportsFamily);

FOUNDATION_EXPORT BOOL PXGraphicsProtectionIsEnabledForSettings(
    NSDictionary<NSString *, id> * _Nullable settings
);
FOUNDATION_EXPORT BOOL PXGraphicsUserScriptsNeedCurrentSource(
    NSArray<NSString *> *existingSources,
    NSString *currentSource
);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *PXGraphicsModelDescription(
    NSString *gpuFamily,
    NSString *metalFeatureSet,
    NSDictionary<NSString *, id> *webGLInfo
);

@interface PXGraphicsIdentity : NSObject

@property (nonatomic, copy, readonly) NSString *generationID;
@property (nonatomic, copy, readonly) NSString *modelIdentifier;
@property (nonatomic, copy, readonly) NSString *gpuName;
@property (nonatomic, copy, readonly) NSString *gpuFamily;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *metalFamilies;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *metalFeatureSets;
@property (nonatomic, copy, readonly) NSString *metalFeatureSetName;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *webGL;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *openGL;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *hostCapabilities;
@property (nonatomic, assign, readonly) uint64_t canvasNoiseSeed;

+ (nullable instancetype)identityWithModelRecord:(NSDictionary<NSString *, id> *)modelRecord
                                      profileSeed:(NSString *)profileSeed
                                     generationID:(NSString *)generationID
                                 hostCapabilities:(NSDictionary<NSString *, id> *)hostCapabilities
                                            error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                             error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, id> *)propertyListRepresentation;
- (BOOL)validateAgainstModelRecord:(NSDictionary<NSString *, id> *)modelRecord
                  hostCapabilities:(NSDictionary<NSString *, id> *)hostCapabilities
                             error:(NSError * _Nullable * _Nullable)error;
- (NSData *)deterministicallyNoisedBytes:(NSData *)input domain:(NSString *)domain;
- (NSString *)javaScriptSource;

@end

NS_ASSUME_NONNULL_END
