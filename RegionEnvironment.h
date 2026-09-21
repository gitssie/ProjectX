#import <Foundation/Foundation.h>

#import "RegionIdentity.h"

NS_ASSUME_NONNULL_BEGIN

@interface PXRegionEnvironmentSnapshot : NSObject

@property (nonatomic, strong, readonly) PXRegionIdentity *regionIdentity;
@property (nonatomic, strong, readonly) NSLocale *locale;
@property (nonatomic, strong, readonly) NSTimeZone *timeZone;
@property (nonatomic, copy, readonly) NSArray<NSString *> *preferredLanguages;

- (instancetype)initWithRegionIdentity:(PXRegionIdentity *)regionIdentity;
- (NSCalendar *)newCalendar;
- (nullable id)regionalPreferenceValueForKey:(NSString *)key;
- (nullable id)valueForRegionalPreferenceKey:(NSString *)key
                               requestedClass:(Class)requestedClass
                                originalValue:(nullable id)originalValue;
- (NSDictionary<NSString *, id> *)dictionaryByApplyingRegionalPreferences:
    (NSDictionary<NSString *, id> *)dictionary;

@end

typedef NSDictionary<NSString *, id> * _Nullable (^PXRegionEnvironmentSourceLoader)(void);
typedef BOOL (^PXRegionEnvironmentScopeEvaluator)(void);

@interface PXRegionEnvironmentCache : NSObject

@property (nonatomic, strong, readonly, nullable) PXRegionEnvironmentSnapshot *currentSnapshot;

- (instancetype)initWithSourceLoader:(PXRegionEnvironmentSourceLoader)sourceLoader
                       scopeEvaluator:(PXRegionEnvironmentScopeEvaluator)scopeEvaluator;
- (BOOL)reloadAfterGenerationChange;
- (void)invalidate;

@end

FOUNDATION_EXPORT PXRegionEnvironmentSnapshot * _Nullable PXCurrentRegionEnvironmentSnapshot(void);

NS_ASSUME_NONNULL_END
