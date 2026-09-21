#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL PXPayloadShouldLoadForIdentity(
    NSString * _Nullable bundleIdentifier,
    NSString * _Nullable processName,
    NSDictionary *scopePropertyList
);

NS_ASSUME_NONNULL_END
