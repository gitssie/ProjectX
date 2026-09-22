#import <Foundation/Foundation.h>

#include <assert.h>

#import "PXGeoIPLocation.h"

@interface PXTestGeoIPURLProtocol : NSURLProtocol
@end

static NSData *PXTestResponseData;
static NSInteger PXTestResponseStatus;
static NSString *PXTestRequestedHost;

@implementation PXTestGeoIPURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [@[@"geoip.test", @"ipv4.test", @"ipv6.test"]
        containsObject:request.URL.host];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    PXTestRequestedHost = self.request.URL.host;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
        statusCode:PXTestResponseStatus
        HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Type": @"application/json" }];
    [self.client URLProtocol:self didReceiveResponse:response
         cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (PXTestResponseData.length > 0) {
        [self.client URLProtocol:self didLoadData:PXTestResponseData];
    }
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

static NSDictionary<NSString *, id> *PXValidGeoIPResponse(void) {
    return @{
        @"success": @YES,
        @"ip": @"1.1.1.1",
        @"city": @"Paris",
        @"region": @"Île-de-France",
        @"country": @"France",
        @"country_code": @"fr",
        @"latitude": @48.8566,
        @"longitude": @2.3522,
        @"timezone": @{ @"id": @"Europe/Paris" }
    };
}

static void PXTestParsesAndPersistsCompleteGeoIPLocation(void) {
    NSError *error = nil;
    PXGeoIPLocation *location = [PXGeoIPLocation
        locationWithJSONDictionary:PXValidGeoIPResponse()
        error:&error];
    assert(location != nil);
    assert(error == nil);
    assert([location.publicIPAddress isEqualToString:@"1.1.1.1"]);
    assert([[location publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv4]
        isEqualToString:@"1.1.1.1"]);
    assert([location publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv6] == nil);
    assert([location.countryCode isEqualToString:@"FR"]);
    assert([location.timeZoneIdentifier isEqualToString:@"Europe/Paris"]);
    assert([location.address isEqualToString:@"Paris, Île-de-France, France"]);

    NSDictionary<NSString *, id> *policy = [location policyRepresentation];
    assert([policy[@"source"] isEqualToString:@"geo_ip"]);
    assert(policy[@"publicIP"] == nil);
    PXGeoIPLocation *restored = [PXGeoIPLocation
        locationWithPolicyRepresentation:policy
        error:&error];
    assert(restored != nil);
    assert(error == nil);
    assert([restored.address isEqualToString:location.address]);
    assert(restored.latitude == location.latitude);
    assert(restored.longitude == location.longitude);
}

static void PXTestClassifiesIPv6GeoIPResponse(void) {
    NSMutableDictionary<NSString *, id> *response = [PXValidGeoIPResponse() mutableCopy];
    response[@"ip"] = @"2a0d:e487:63e:999c::6f7:a8d";
    response[@"type"] = @"IPv6";
    PXGeoIPLocation *location = [PXGeoIPLocation locationWithJSONDictionary:response error:nil];
    assert(location != nil);
    assert([location publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv4] == nil);
    assert([[location publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv6]
        isEqualToString:response[@"ip"]]);
}

static void PXTestPersistsDualStackAddressesWithLocation(void) {
    PXGeoIPLocation *location = [PXGeoIPLocation
        locationWithJSONDictionary:PXValidGeoIPResponse() error:nil];
    NSDictionary<NSString *, id> *policy = [location
        policyRepresentationWithIPv4Address:@"176.122.187.27"
                              ipv6Address:@"2a0d:e487:63e:999c::6f7:a8d"];
    assert([policy[@"ipv4"] isEqualToString:@"176.122.187.27"]);
    assert([policy[@"ipv6"] isEqualToString:@"2a0d:e487:63e:999c::6f7:a8d"]);
    PXGeoIPLocation *restored = [PXGeoIPLocation
        locationWithPolicyRepresentation:policy error:nil];
    assert([restored.ipv4Address isEqualToString:@"176.122.187.27"]);
    assert([restored.ipv6Address isEqualToString:@"2a0d:e487:63e:999c::6f7:a8d"]);
    NSDictionary<NSString *, id> *roundTrip = [restored policyRepresentation];
    assert([roundTrip[@"ipv4"] isEqualToString:policy[@"ipv4"]]);
    assert([roundTrip[@"ipv6"] isEqualToString:policy[@"ipv6"]]);

    NSMutableDictionary<NSString *, id> *invalid = [policy mutableCopy];
    invalid[@"ipv4"] = @"127.0.0.1";
    assert([PXGeoIPLocation locationWithPolicyRepresentation:invalid error:nil] == nil);
    invalid[@"ipv4"] = @"2a0d:e487:63e:999c::6f7:a8d";
    assert([PXGeoIPLocation locationWithPolicyRepresentation:invalid error:nil] == nil);
    invalid = [policy mutableCopy];
    invalid[@"ipv6"] = @"176.122.187.27";
    assert([PXGeoIPLocation locationWithPolicyRepresentation:invalid error:nil] == nil);
}

static void PXTestRejectsServiceAndInvalidLocationResponses(void) {
    NSError *error = nil;
    NSDictionary<NSString *, id> *rejected = @{
        @"success": @NO,
        @"message": @"rate limited"
    };
    assert([PXGeoIPLocation locationWithJSONDictionary:rejected error:&error] == nil);
    assert([error.domain isEqualToString:PXGeoIPLocationErrorDomain]);

    NSMutableDictionary<NSString *, id> *invalid = [PXValidGeoIPResponse() mutableCopy];
    invalid[@"latitude"] = @181;
    error = nil;
    assert([PXGeoIPLocation locationWithJSONDictionary:invalid error:&error] == nil);
    assert(error != nil);

    invalid = [PXValidGeoIPResponse() mutableCopy];
    invalid[@"timezone"] = @{ @"id": @"Invalid/Zone" };
    error = nil;
    assert([PXGeoIPLocation locationWithJSONDictionary:invalid error:&error] == nil);
    assert(error != nil);

    invalid = [PXValidGeoIPResponse() mutableCopy];
    invalid[@"ip"] = @"203.0.113.7";
    error = nil;
    assert([PXGeoIPLocation locationWithJSONDictionary:invalid error:&error] == nil);
    assert(error != nil);

    NSMutableDictionary<NSString *, id> *invalidPolicy =
        [[[PXGeoIPLocation locationWithJSONDictionary:PXValidGeoIPResponse() error:nil]
            policyRepresentation] mutableCopy];
    invalidPolicy[@"source"] = @"manual";
    error = nil;
    assert([PXGeoIPLocation locationWithPolicyRepresentation:invalidPolicy error:&error] == nil);
    assert(error != nil);

    invalidPolicy[@"source"] = @"geo_ip";
    invalidPolicy[@"publicIP"] = @"127.0.0.1";
    error = nil;
    assert([PXGeoIPLocation locationWithPolicyRepresentation:invalidPolicy error:&error] == nil);
    assert(error != nil);
}

static void PXTestServiceResponse(NSData *responseData,
                                  NSInteger statusCode,
                                  BOOL expectedSuccess,
                                  NSInteger expectedErrorCode) {
    PXTestResponseData = responseData;
    PXTestResponseStatus = statusCode;
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.protocolClasses = @[[PXTestGeoIPURLProtocol class]];
    PXGeoIPLocationService *service = [[PXGeoIPLocationService alloc]
        initWithSessionConfiguration:configuration
        endpoint:[NSURL URLWithString:@"https://geoip.test/"]];
    __block BOOL completed = NO;
    __block PXGeoIPLocation *actualLocation = nil;
    __block NSError *actualError = nil;
    [service fetchCurrentLocationWithCompletion:^(PXGeoIPLocation *location, NSError *error) {
        actualLocation = location;
        actualError = error;
        completed = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    assert(completed);
    assert((actualLocation != nil) == expectedSuccess);
    assert((actualError == nil) == expectedSuccess);
    if (!expectedSuccess && expectedErrorCode > 0) {
        assert([actualError.domain isEqualToString:PXGeoIPLocationErrorDomain]);
        assert(actualError.code == expectedErrorCode);
    }
}

static void PXTestServiceBoundsDownloadAndRejectsHTTPErrors(void) {
    NSData *validJSON = [NSJSONSerialization dataWithJSONObject:PXValidGeoIPResponse()
                                                       options:0
                                                         error:nil];
    PXTestServiceResponse(validJSON, 200, YES, 0);
    PXTestServiceResponse(validJSON, 503, NO, 2);
    PXTestServiceResponse([NSData data], 200, NO, 1);
    NSMutableData *oversized = [NSMutableData dataWithLength:256 * 1024 + 1];
    PXTestServiceResponse(oversized, 200, NO, 3);
}

static void PXTestPublicAddressResponse(PXGeoIPNetworkFamily family,
                                        NSString *responseAddress,
                                        NSString *expectedAddress) {
    PXTestRequestedHost = nil;
    PXTestResponseData = [NSJSONSerialization dataWithJSONObject:@{ @"ip": responseAddress }
                                                      options:0
                                                        error:nil];
    PXTestResponseStatus = 200;
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.protocolClasses = @[[PXTestGeoIPURLProtocol class]];
    PXGeoIPLocationService *service = [[PXGeoIPLocationService alloc]
        initWithSessionConfiguration:configuration
                           endpoint:[NSURL URLWithString:@"https://geoip.test/"]
                       ipv4Endpoint:[NSURL URLWithString:@"https://ipv4.test/?format=json"]
                       ipv6Endpoint:[NSURL URLWithString:@"https://ipv6.test/?format=json"]];
    __block BOOL completed = NO;
    __block NSString *actualAddress = nil;
    __block NSError *actualError = nil;
    [service fetchPublicIPAddressForFamily:family completion:^(NSString *address, NSError *error) {
        actualAddress = address;
        actualError = error;
        completed = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    assert(completed);
    assert([PXTestRequestedHost isEqualToString:family == PXGeoIPNetworkFamilyIPv4
        ? @"ipv4.test" : @"ipv6.test"]);
    assert((actualError == nil) == (expectedAddress != nil));
    assert(expectedAddress == nil || [actualAddress isEqualToString:expectedAddress]);
    assert(expectedAddress != nil || actualAddress == nil);
}

static void PXTestDetectsIPv4AndIPv6Separately(void) {
    PXTestPublicAddressResponse(PXGeoIPNetworkFamilyIPv4,
                                @"176.122.187.27", @"176.122.187.27");
    PXTestPublicAddressResponse(PXGeoIPNetworkFamilyIPv6,
                                @"2a0d:e487:63e:999c::6f7:a8d",
                                @"2a0d:e487:63e:999c::6f7:a8d");
    PXTestPublicAddressResponse(PXGeoIPNetworkFamilyIPv6, @"1.1.1.1", nil);
    PXTestPublicAddressResponse(PXGeoIPNetworkFamilyIPv4, @"10.0.0.1", nil);
    PXTestPublicAddressResponse(PXGeoIPNetworkFamilyIPv4, @"not-an-ip", nil);
}

int main(void) {
    @autoreleasepool {
        PXTestParsesAndPersistsCompleteGeoIPLocation();
        PXTestClassifiesIPv6GeoIPResponse();
        PXTestPersistsDualStackAddressesWithLocation();
        PXTestRejectsServiceAndInvalidLocationResponses();
        PXTestServiceBoundsDownloadAndRejectsHTTPErrors();
        PXTestDetectsIPv4AndIPv6Separately();
    }
    return 0;
}
