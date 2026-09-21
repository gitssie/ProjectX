#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PXRegionIdentity : NSObject

@property (nonatomic, copy, readonly) NSString *stableRegionIdentifier;
@property (nonatomic, copy, readonly) NSString *countryCode;
@property (nonatomic, copy, readonly) NSString *primaryLanguageTag;
@property (nonatomic, copy, readonly) NSArray<NSString *> *preferredLanguages;
@property (nonatomic, copy, readonly) NSString *localeIdentifier;
@property (nonatomic, copy, readonly) NSString *timeZoneIdentifier;
@property (nonatomic, copy, readonly) NSArray<NSString *> *timeZoneIdentifiers;
@property (nonatomic, copy, readonly) NSString *currencyCode;
@property (nonatomic, copy, readonly) NSString *calendarIdentifier;
@property (nonatomic, copy, readonly) NSString *measurementSystem;
@property (nonatomic, copy, readonly) NSString *temperatureUnit;

- (NSDictionary<NSString *, id> *)propertyListRepresentation;
- (BOOL)validate;
+ (nullable instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList;

@end

FOUNDATION_EXPORT NSArray<PXRegionIdentity *> *PXRegionCatalog(void);
FOUNDATION_EXPORT PXRegionIdentity * _Nullable PXRegionIdentityForCountryCode(NSString *countryCode,
                                                                              NSData *seed);
FOUNDATION_EXPORT PXRegionIdentity * _Nullable PXRegionIdentityByCompletingPropertyList(
    NSDictionary<NSString *, id> *propertyList,
    NSString *fallbackCountryCode,
    NSData *seed
);

NS_ASSUME_NONNULL_END
