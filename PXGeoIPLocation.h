#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXGeoIPLocationErrorDomain;

typedef NS_ENUM(NSInteger, PXGeoIPNetworkFamily) {
    PXGeoIPNetworkFamilyIPv4 = 4,
    PXGeoIPNetworkFamilyIPv6 = 6
};

@interface PXGeoIPLocation : NSObject

@property (nonatomic, copy, readonly) NSString *publicIPAddress;
@property (nonatomic, copy, readonly, nullable) NSString *ipv4Address;
@property (nonatomic, copy, readonly, nullable) NSString *ipv6Address;
@property (nonatomic, copy, readonly) NSString *city;
@property (nonatomic, copy, readonly) NSString *region;
@property (nonatomic, copy, readonly) NSString *country;
@property (nonatomic, copy, readonly) NSString *countryCode;
@property (nonatomic, copy, readonly) NSString *timeZoneIdentifier;
@property (nonatomic, copy, readonly) NSString *address;
@property (nonatomic, readonly) double latitude;
@property (nonatomic, readonly) double longitude;

+ (nullable instancetype)locationWithJSONDictionary:(NSDictionary<NSString *, id> *)dictionary
                                               error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)locationWithPolicyRepresentation:(NSDictionary<NSString *, id> *)dictionary
                                                     error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, id> *)policyRepresentation;
- (NSDictionary<NSString *, id> *)policyRepresentationWithIPv4Address:(nullable NSString *)ipv4Address
                                                      ipv6Address:(nullable NSString *)ipv6Address;
- (nullable NSString *)publicIPAddressForFamily:(PXGeoIPNetworkFamily)family;

@end

@interface PXGeoIPLocationService : NSObject

- (instancetype)init;
- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration
                                     endpoint:(NSURL *)endpoint;
- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration
                                     endpoint:(NSURL *)endpoint
                                 ipv4Endpoint:(NSURL *)ipv4Endpoint
                                 ipv6Endpoint:(NSURL *)ipv6Endpoint NS_DESIGNATED_INITIALIZER;
- (NSURLSessionDataTask *)fetchCurrentLocationWithCompletion:
    (void (^)(PXGeoIPLocation * _Nullable location, NSError * _Nullable error))completion;
- (NSURLSessionDataTask *)fetchPublicIPAddressForFamily:(PXGeoIPNetworkFamily)family
                                             completion:(void (^)(NSString * _Nullable address,
                                                                  NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
