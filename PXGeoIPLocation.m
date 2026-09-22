#import "PXGeoIPLocation.h"

#import <arpa/inet.h>
#import <math.h>

NSString *const PXGeoIPLocationErrorDomain = @"com.hydra.projectx.geo-ip-location";

typedef NS_ENUM(NSInteger, PXGeoIPLocationErrorCode) {
    PXGeoIPLocationErrorInvalidResponse = 1,
    PXGeoIPLocationErrorServiceUnavailable = 2,
    PXGeoIPLocationErrorResponseTooLarge = 3
};

static NSError *PXGeoIPError(PXGeoIPLocationErrorCode code, NSString *description) {
    return [NSError errorWithDomain:PXGeoIPLocationErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSString *PXGeoIPString(id value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    return [(NSString *)value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL PXGeoIPCoordinatesAreValid(NSNumber *latitude, NSNumber *longitude) {
    if (![latitude isKindOfClass:[NSNumber class]] ||
        ![longitude isKindOfClass:[NSNumber class]]) return NO;
    double latitudeValue = latitude.doubleValue;
    double longitudeValue = longitude.doubleValue;
    return isfinite(latitudeValue) && isfinite(longitudeValue) &&
        latitudeValue >= -90.0 && latitudeValue <= 90.0 &&
        longitudeValue >= -180.0 && longitudeValue <= 180.0;
}

static BOOL PXIPv4AddressIsPublic(struct in_addr address) {
    uint32_t value = ntohl(address.s_addr);
    if ((value & 0xff000000U) == 0x00000000U ||
        (value & 0xff000000U) == 0x0a000000U ||
        (value & 0xffc00000U) == 0x64400000U ||
        (value & 0xff000000U) == 0x7f000000U ||
        (value & 0xffff0000U) == 0xa9fe0000U ||
        (value & 0xfff00000U) == 0xac100000U ||
        (value & 0xffffff00U) == 0xc0000000U ||
        (value & 0xffffff00U) == 0xc0000200U ||
        (value & 0xffff0000U) == 0xc0a80000U ||
        (value & 0xfffe0000U) == 0xc6120000U ||
        (value & 0xffffff00U) == 0xc6336400U ||
        (value & 0xffffff00U) == 0xcb007100U ||
        value >= 0xe0000000U) {
        return NO;
    }
    return YES;
}

static BOOL PXGeoIPAddressIsPublic(NSString *address) {
    if (address.length == 0) return NO;
    struct in_addr ipv4;
    if (inet_pton(AF_INET, address.UTF8String, &ipv4) == 1) {
        return PXIPv4AddressIsPublic(ipv4);
    }
    struct in6_addr ipv6;
    if (inet_pton(AF_INET6, address.UTF8String, &ipv6) != 1) return NO;
    if (IN6_IS_ADDR_V4MAPPED(&ipv6)) {
        memcpy(&ipv4.s_addr, &ipv6.s6_addr[12], sizeof(ipv4.s_addr));
        return PXIPv4AddressIsPublic(ipv4);
    }
    if ((ipv6.s6_addr[0] & 0xe0U) != 0x20U ||
        (ipv6.s6_addr[0] == 0x20U && ipv6.s6_addr[1] == 0x01U &&
         ipv6.s6_addr[2] == 0x0dU && ipv6.s6_addr[3] == 0xb8U)) {
        return NO;
    }
    return YES;
}

static BOOL PXGeoIPAddressMatchesFamily(NSString *address, PXGeoIPNetworkFamily family) {
    if (!PXGeoIPAddressIsPublic(address)) return NO;
    if (family == PXGeoIPNetworkFamilyIPv4) {
        struct in_addr ipv4;
        return inet_pton(AF_INET, address.UTF8String, &ipv4) == 1;
    }
    if (family == PXGeoIPNetworkFamilyIPv6) {
        struct in6_addr ipv6;
        return inet_pton(AF_INET6, address.UTF8String, &ipv6) == 1 &&
            !IN6_IS_ADDR_V4MAPPED(&ipv6);
    }
    return NO;
}

@interface PXGeoIPLocation ()
@property (nonatomic, copy, readwrite) NSString *publicIPAddress;
@property (nonatomic, copy, readwrite, nullable) NSString *ipv4Address;
@property (nonatomic, copy, readwrite, nullable) NSString *ipv6Address;
@property (nonatomic, copy, readwrite) NSString *city;
@property (nonatomic, copy, readwrite) NSString *region;
@property (nonatomic, copy, readwrite) NSString *country;
@property (nonatomic, copy, readwrite) NSString *countryCode;
@property (nonatomic, copy, readwrite) NSString *timeZoneIdentifier;
@property (nonatomic, copy, readwrite) NSString *address;
@property (nonatomic, readwrite) double latitude;
@property (nonatomic, readwrite) double longitude;
@end

@implementation PXGeoIPLocation

- (NSString *)publicIPAddressForFamily:(PXGeoIPNetworkFamily)family {
    return PXGeoIPAddressMatchesFamily(self.publicIPAddress, family)
        ? self.publicIPAddress : nil;
}

+ (instancetype)locationWithJSONDictionary:(NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        if (error) *error = PXGeoIPError(PXGeoIPLocationErrorInvalidResponse,
                                         @"GEO IP response is not a dictionary");
        return nil;
    }
    NSNumber *success = [dictionary[@"success"] isKindOfClass:[NSNumber class]]
        ? dictionary[@"success"] : nil;
    if (!success || !success.boolValue) {
        if (error) *error = PXGeoIPError(PXGeoIPLocationErrorServiceUnavailable,
                                         @"GEO IP service rejected the request");
        return nil;
    }
    NSString *publicIPAddress = PXGeoIPString(dictionary[@"ip"]);
    if (!PXGeoIPAddressIsPublic(publicIPAddress)) {
        if (error) *error = PXGeoIPError(PXGeoIPLocationErrorInvalidResponse,
                                         @"GEO IP response has no valid public IP address");
        return nil;
    }
    NSDictionary<NSString *, id> *timeZone = [dictionary[@"timezone"] isKindOfClass:[NSDictionary class]]
        ? dictionary[@"timezone"] : @{};
    NSDictionary<NSString *, id> *policy = @{
        @"publicIP": publicIPAddress,
        @"city": PXGeoIPString(dictionary[@"city"]),
        @"region": PXGeoIPString(dictionary[@"region"]),
        @"country": PXGeoIPString(dictionary[@"country"]),
        @"countryCode": PXGeoIPString(dictionary[@"country_code"]),
        @"timeZone": PXGeoIPString(timeZone[@"id"]),
        @"latitude": dictionary[@"latitude"] ?: NSNull.null,
        @"longitude": dictionary[@"longitude"] ?: NSNull.null,
        @"source": @"geo_ip",
        @"schemaVersion": @1
    };
    return [self locationWithPolicyRepresentation:policy error:error];
}

+ (instancetype)locationWithPolicyRepresentation:(NSDictionary<NSString *, id> *)dictionary
                                             error:(NSError **)error {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        if (error) *error = PXGeoIPError(PXGeoIPLocationErrorInvalidResponse,
                                         @"Saved GEO IP location is invalid");
        return nil;
    }
    NSNumber *latitude = [dictionary[@"latitude"] isKindOfClass:[NSNumber class]]
        ? dictionary[@"latitude"] : nil;
    NSNumber *longitude = [dictionary[@"longitude"] isKindOfClass:[NSNumber class]]
        ? dictionary[@"longitude"] : nil;
    NSString *countryCode = PXGeoIPString(dictionary[@"countryCode"]).uppercaseString;
    NSString *timeZoneIdentifier = PXGeoIPString(dictionary[@"timeZone"]);
    NSString *source = PXGeoIPString(dictionary[@"source"]);
    NSString *storedIP = PXGeoIPString(dictionary[@"publicIP"]);
    id storedIPv4 = dictionary[@"ipv4"];
    id storedIPv6 = dictionary[@"ipv6"];
    NSNumber *schemaVersion = [dictionary[@"schemaVersion"] isKindOfClass:[NSNumber class]]
        ? dictionary[@"schemaVersion"] : nil;
    if (schemaVersion.integerValue != 1 ||
        ![source isEqualToString:@"geo_ip"] ||
        !PXGeoIPCoordinatesAreValid(latitude, longitude) ||
        countryCode.length != 2 ||
        ![NSLocale.ISOCountryCodes containsObject:countryCode] ||
        timeZoneIdentifier.length == 0 ||
        ![NSTimeZone timeZoneWithName:timeZoneIdentifier] ||
        (storedIP.length > 0 && !PXGeoIPAddressIsPublic(storedIP)) ||
        (storedIPv4 && (![storedIPv4 isKindOfClass:[NSString class]] ||
                        !PXGeoIPAddressMatchesFamily(storedIPv4, PXGeoIPNetworkFamilyIPv4))) ||
        (storedIPv6 && (![storedIPv6 isKindOfClass:[NSString class]] ||
                        !PXGeoIPAddressMatchesFamily(storedIPv6, PXGeoIPNetworkFamilyIPv6)))) {
        if (error) *error = PXGeoIPError(PXGeoIPLocationErrorInvalidResponse,
                                         @"GEO IP location fields are incomplete or invalid");
        return nil;
    }

    NSString *city = PXGeoIPString(dictionary[@"city"]);
    NSString *region = PXGeoIPString(dictionary[@"region"]);
    NSString *country = PXGeoIPString(dictionary[@"country"]);
    NSMutableOrderedSet<NSString *> *addressParts = [NSMutableOrderedSet orderedSet];
    for (NSString *part in @[city, region, country]) {
        if (part.length > 0) [addressParts addObject:part];
    }
    NSString *address = PXGeoIPString(dictionary[@"address"]);
    if (address.length == 0) address = [addressParts.array componentsJoinedByString:@", "];
    if (address.length == 0) {
        if (error) *error = PXGeoIPError(PXGeoIPLocationErrorInvalidResponse,
                                         @"GEO IP location has no displayable address");
        return nil;
    }

    PXGeoIPLocation *location = [[self alloc] init];
    location.publicIPAddress = PXGeoIPString(dictionary[@"publicIP"]);
    location.ipv4Address = storedIPv4;
    location.ipv6Address = storedIPv6;
    location.city = city;
    location.region = region;
    location.country = country;
    location.countryCode = countryCode;
    location.timeZoneIdentifier = timeZoneIdentifier;
    location.address = address;
    location.latitude = latitude.doubleValue;
    location.longitude = longitude.doubleValue;
    return location;
}

- (NSDictionary<NSString *, id> *)policyRepresentation {
    return [self policyRepresentationWithIPv4Address:self.ipv4Address
                                         ipv6Address:self.ipv6Address];
}

- (NSDictionary<NSString *, id> *)policyRepresentationWithIPv4Address:(NSString * _Nullable)ipv4Address
                                                      ipv6Address:(NSString * _Nullable)ipv6Address {
    NSMutableDictionary<NSString *, id> *representation = [@{
        @"latitude": @(self.latitude),
        @"longitude": @(self.longitude),
        @"address": self.address,
        @"countryCode": self.countryCode,
        @"timeZone": self.timeZoneIdentifier,
        @"source": @"geo_ip",
        @"schemaVersion": @1
    } mutableCopy];
    if (self.city.length > 0) representation[@"city"] = self.city;
    if (self.region.length > 0) representation[@"region"] = self.region;
    if (self.country.length > 0) representation[@"country"] = self.country;
    if (PXGeoIPAddressMatchesFamily(ipv4Address, PXGeoIPNetworkFamilyIPv4)) {
        representation[@"ipv4"] = ipv4Address;
    }
    if (PXGeoIPAddressMatchesFamily(ipv6Address, PXGeoIPNetworkFamilyIPv6)) {
        representation[@"ipv6"] = ipv6Address;
    }
    return [representation copy];
}

@end

static const NSUInteger PXGeoIPMaximumResponseBytes = 256 * 1024;

@interface PXGeoIPBoundedRequest : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, copy) void (^completion)(PXGeoIPLocation *, NSError *);
@property (nonatomic, copy) void (^addressCompletion)(NSString *, NSError *);
@property (nonatomic, assign) PXGeoIPNetworkFamily addressFamily;
@property (nonatomic, assign) BOOL finished;
- (NSURLSessionDataTask *)startWithConfiguration:(NSURLSessionConfiguration *)configuration
                                        endpoint:(NSURL *)endpoint
                                      completion:(void (^)(PXGeoIPLocation *, NSError *))completion;
- (NSURLSessionDataTask *)startAddressWithConfiguration:(NSURLSessionConfiguration *)configuration
                                               endpoint:(NSURL *)endpoint
                                                 family:(PXGeoIPNetworkFamily)family
                                             completion:(void (^)(NSString *, NSError *))completion;
@end

@implementation PXGeoIPBoundedRequest

- (NSURLSessionDataTask *)startWithConfiguration:(NSURLSessionConfiguration *)configuration
                                        endpoint:(NSURL *)endpoint
                                      completion:(void (^)(PXGeoIPLocation *, NSError *))completion {
    self.completion = completion;
    return [self startWithConfiguration:configuration endpoint:endpoint];
}

- (NSURLSessionDataTask *)startAddressWithConfiguration:(NSURLSessionConfiguration *)configuration
                                               endpoint:(NSURL *)endpoint
                                                 family:(PXGeoIPNetworkFamily)family
                                             completion:(void (^)(NSString *, NSError *))completion {
    self.addressCompletion = completion;
    self.addressFamily = family;
    return [self startWithConfiguration:configuration endpoint:endpoint];
}

- (NSURLSessionDataTask *)startWithConfiguration:(NSURLSessionConfiguration *)configuration
                                        endpoint:(NSURL *)endpoint {
    self.responseData = [NSMutableData data];
    self.session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
    return self.task;
}

- (void)finishWithLocation:(PXGeoIPLocation *)location error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    void (^completion)(PXGeoIPLocation *, NSError *) = self.completion;
    self.completion = nil;
    [self.session finishTasksAndInvalidate];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(location, error); });
}

- (void)finishWithAddress:(NSString *)address error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    void (^completion)(NSString *, NSError *) = self.addressCompletion;
    self.addressCompletion = nil;
    [self.session finishTasksAndInvalidate];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(address, error); });
}

- (void)finishWithError:(NSError *)error {
    if (self.addressCompletion) [self finishWithAddress:nil error:error];
    else [self finishWithLocation:nil error:error];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    (void)dataTask;
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)response : nil;
    if (!httpResponse || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        completionHandler(NSURLSessionResponseCancel);
        [self finishWithError:PXGeoIPError(PXGeoIPLocationErrorServiceUnavailable,
                                           @"GEO IP service returned an HTTP error")];
        return;
    }
    if (response.expectedContentLength > (int64_t)PXGeoIPMaximumResponseBytes) {
        completionHandler(NSURLSessionResponseCancel);
        [self finishWithError:PXGeoIPError(PXGeoIPLocationErrorResponseTooLarge,
                                           @"GEO IP response exceeded the size limit")];
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (self.finished) return;
    if (self.responseData.length + data.length > PXGeoIPMaximumResponseBytes) {
        [dataTask cancel];
        [self finishWithError:PXGeoIPError(PXGeoIPLocationErrorResponseTooLarge,
                                           @"GEO IP response exceeded the size limit")];
        return;
    }
    [self.responseData appendData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)requestError {
    (void)session;
    (void)task;
    if (self.finished) return;
    if (requestError) {
        [self finishWithError:requestError];
        return;
    }
    if (self.responseData.length == 0) {
        [self finishWithError:PXGeoIPError(PXGeoIPLocationErrorInvalidResponse,
                                           @"GEO IP service returned an empty response")];
        return;
    }
    NSError *resultError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:self.responseData
                                                options:0
                                                  error:&resultError];
    if (self.addressCompletion) {
        NSDictionary *dictionary = [object isKindOfClass:[NSDictionary class]]
            ? (NSDictionary *)object : nil;
        NSString *address = PXGeoIPString(dictionary[@"ip"]);
        if (!resultError && !PXGeoIPAddressMatchesFamily(address, self.addressFamily)) {
            resultError = PXGeoIPError(PXGeoIPLocationErrorInvalidResponse,
                                       @"Public IP response has an invalid address family");
        }
        [self finishWithAddress:resultError ? nil : address error:resultError];
        return;
    }
    PXGeoIPLocation *location = resultError ? nil :
        [PXGeoIPLocation locationWithJSONDictionary:object error:&resultError];
    [self finishWithLocation:location error:resultError];
}

@end

@interface PXGeoIPLocationService ()
@property (nonatomic, strong) NSURLSessionConfiguration *configuration;
@property (nonatomic, strong) NSURL *endpoint;
@property (nonatomic, strong) NSURL *ipv4Endpoint;
@property (nonatomic, strong) NSURL *ipv6Endpoint;
@end

@implementation PXGeoIPLocationService

- (instancetype)init {
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 12.0;
    configuration.timeoutIntervalForResource = 15.0;
    configuration.HTTPShouldSetCookies = NO;
    return [self initWithSessionConfiguration:configuration
                                     endpoint:[NSURL URLWithString:@"https://ipwho.is/"]
                                 ipv4Endpoint:[NSURL URLWithString:@"https://api.ipify.org?format=json"]
                                 ipv6Endpoint:[NSURL URLWithString:@"https://api6.ipify.org?format=json"]];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration
                                     endpoint:(NSURL *)endpoint {
    return [self initWithSessionConfiguration:configuration
                                    endpoint:endpoint
                                ipv4Endpoint:[NSURL URLWithString:@"https://api.ipify.org?format=json"]
                                ipv6Endpoint:[NSURL URLWithString:@"https://api6.ipify.org?format=json"]];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration
                                     endpoint:(NSURL *)endpoint
                                 ipv4Endpoint:(NSURL *)ipv4Endpoint
                                 ipv6Endpoint:(NSURL *)ipv6Endpoint {
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _endpoint = endpoint;
        _ipv4Endpoint = ipv4Endpoint;
        _ipv6Endpoint = ipv6Endpoint;
    }
    return self;
}

- (NSURLSessionDataTask *)fetchCurrentLocationWithCompletion:
    (void (^)(PXGeoIPLocation *, NSError *))completion {
    PXGeoIPBoundedRequest *request = [[PXGeoIPBoundedRequest alloc] init];
    return [request startWithConfiguration:self.configuration
                                  endpoint:self.endpoint
                                completion:completion];
}

- (NSURLSessionDataTask *)fetchPublicIPAddressForFamily:(PXGeoIPNetworkFamily)family
                                             completion:(void (^)(NSString *, NSError *))completion {
    NSParameterAssert(family == PXGeoIPNetworkFamilyIPv4 ||
                      family == PXGeoIPNetworkFamilyIPv6);
    PXGeoIPBoundedRequest *request = [[PXGeoIPBoundedRequest alloc] init];
    return [request startAddressWithConfiguration:self.configuration
                                         endpoint:family == PXGeoIPNetworkFamilyIPv4
                                             ? self.ipv4Endpoint : self.ipv6Endpoint
                                           family:family
                                       completion:completion];
}

@end
