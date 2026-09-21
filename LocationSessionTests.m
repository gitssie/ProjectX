#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>

#import "LocationSession.h"

static double distanceMeters(double latitudeA,
                             double longitudeA,
                             double latitudeB,
                             double longitudeB) {
    double latitudeRadians = latitudeA * M_PI / 180.0;
    double northMeters = (latitudeB - latitudeA) * 111000.0;
    double eastMeters = (longitudeB - longitudeA) * 111000.0 * cos(latitudeRadians);
    return hypot(northMeters, eastMeters);
}

static void testStationarySampleIsCoherentAndBounded(void) {
    PXLocationSession *session = [[PXLocationSession alloc]
        initWithGenerationID:@"11111111-1111-4111-8111-111111111111"
        seed:@"stationary-seed"];
    PXLocationSampleInput *input = [[PXLocationSampleInput alloc] init];
    input.latitude = 48.8566;
    input.longitude = 2.3522;
    input.altitude = 35.0;
    input.desiredHorizontalAccuracy = 8.0;
    input.driftRadiusMeters = 2.0;
    input.requestedSpeed = 17.0;
    input.movementMode = PXLocationMovementModeStationary;
    NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:1000];
    PXLocationSample *sample = [session nextLocationSampleForInput:input
                                                   sourceTimestamp:timestamp
                                                               now:timestamp];
    assert(sample != nil);
    assert(distanceMeters(input.latitude, input.longitude,
                          sample.latitude, sample.longitude) <= 2.01);
    assert(sample.speed == 0.0);
    assert(sample.course == -1.0);
    assert(sample.horizontalAccuracy >= 5.0 && sample.horizontalAccuracy <= 15.0);
    assert(sample.verticalAccuracy >= sample.horizontalAccuracy);
    assert([sample.timestamp isEqualToDate:timestamp]);
    assert([sample.source isEqualToString:@"stationary"]);
    assert(session.currentLocationSample == sample);
    for (NSUInteger index = 0; index < 500; index++) {
        sample = [session nextLocationSampleForInput:input
                                     sourceTimestamp:timestamp
                                                 now:timestamp];
        assert(distanceMeters(input.latitude, input.longitude,
                              sample.latitude, sample.longitude) <= 2.01);
    }
}

static void testRouteSampleUsesSegmentBearingAndTransportationSpeedLimit(void) {
    PXLocationSession *session = [[PXLocationSession alloc]
        initWithGenerationID:@"22222222-2222-4222-8222-222222222222"
        seed:@"route-seed"];
    PXLocationSampleInput *input = [[PXLocationSampleInput alloc] init];
    input.latitude = 37.7749;
    input.longitude = -122.4190;
    input.altitude = 12.0;
    input.desiredHorizontalAccuracy = 7.0;
    input.driftRadiusMeters = 1.0;
    input.requestedSpeed = 10.0;
    input.movementMode = PXLocationMovementModeWalking;
    input.segmentStart = [[PXLocationPoint alloc] initWithLatitude:37.7749
                                                        longitude:-122.4200];
    input.segmentEnd = [[PXLocationPoint alloc] initWithLatitude:37.7749
                                                      longitude:-122.4100];
    NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:2000];
    PXLocationSample *sample = [session nextLocationSampleForInput:input
                                                   sourceTimestamp:timestamp
                                                               now:timestamp];
    assert(sample != nil);
    assert([sample.source isEqualToString:@"route"]);
    assert(sample.speed > 0.0 && sample.speed <= 2.2);
    assert(fabs(sample.course - 90.0) < 2.0);
    assert(distanceMeters(input.latitude, input.longitude,
                          sample.latitude, sample.longitude) <= 1.01);
}

static void testHeadingIsNormalizedSmoothAndCoherentWithRouteCourse(void) {
    PXLocationSession *session = [[PXLocationSession alloc]
        initWithGenerationID:@"33333333-3333-4333-8333-333333333333"
        seed:@"heading-seed"];
    PXLocationSampleInput *input = [[PXLocationSampleInput alloc] init];
    input.latitude = 51.5;
    input.longitude = -0.12;
    input.altitude = 20.0;
    input.desiredHorizontalAccuracy = 6.0;
    input.movementMode = PXLocationMovementModeDriving;
    input.requestedSpeed = 18.0;
    input.segmentStart = [[PXLocationPoint alloc] initWithLatitude:51.49 longitude:-0.12];
    input.segmentEnd = [[PXLocationPoint alloc] initWithLatitude:51.51 longitude:-0.12];
    NSDate *firstDate = [NSDate dateWithTimeIntervalSince1970:3000];
    PXLocationSample *location = [session nextLocationSampleForInput:input
                                                     sourceTimestamp:firstDate
                                                                 now:firstDate];
    PXHeadingSample *first = [session nextHeadingSampleWithSourceTimestamp:firstDate
                                                                        now:firstDate
                                                   orientationOffsetDegrees:0.0];
    assert(first != nil);
    assert(first.trueHeading >= 0.0 && first.trueHeading < 360.0);
    assert(first.magneticHeading >= 0.0 && first.magneticHeading < 360.0);
    assert(fabs(PXNormalizeDirection(first.magneticHeading + first.declination) -
                first.trueHeading) < 0.001);
    assert(fabs(first.trueHeading - location.course) <= 8.0);
    assert(first.headingAccuracy > 0.0);
    assert(hypot(first.x, first.y) > 20.0);

    NSDate *secondDate = [NSDate dateWithTimeIntervalSince1970:3001];
    PXHeadingSample *second = [session nextHeadingSampleWithSourceTimestamp:secondDate
                                                                         now:secondDate
                                                    orientationOffsetDegrees:90.0];
    double delta = fabs(fmod((second.trueHeading - first.trueHeading) + 540.0, 360.0) - 180.0);
    assert(delta <= 8.01);
    assert(second.declination == first.declination);
    assert([second.timestamp isEqualToDate:secondDate]);
    assert(session.currentHeadingSample == second);
}

static void testHeadingBeforeFirstLocationUsesStationaryOrientation(void) {
    PXLocationSession *session = [[PXLocationSession alloc]
        initWithGenerationID:@"88888888-8888-4888-8888-888888888888"
        seed:@"heading-without-location"];
    NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:3500];
    PXHeadingSample *heading = [session nextHeadingSampleWithSourceTimestamp:timestamp
                                                                          now:timestamp
                                                     orientationOffsetDegrees:90.0];
    assert(heading != nil);
    assert(fabs(heading.trueHeading - 90.0) > 0.001);
}

@interface RecordingLocationDelegate : NSObject <CLLocationManagerDelegate>
@property (nonatomic, assign) NSUInteger modernCount;
@property (nonatomic, assign) NSUInteger legacyCount;
@property (nonatomic, assign) NSUInteger headingCount;
@property (nonatomic, assign) NSUInteger authorizationCount;
@property (nonatomic, strong) NSArray<CLLocation *> *lastLocations;
@property (nonatomic, strong) CLLocation *lastLegacyLocation;
@property (nonatomic, strong) id lastHeading;
@end


@implementation RecordingLocationDelegate

- (void)locationManager:(CLLocationManager *)manager
      didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager;
    self.modernCount++;
    self.lastLocations = locations;
}

- (void)locationManager:(CLLocationManager *)manager
     didUpdateToLocation:(CLLocation *)newLocation
            fromLocation:(CLLocation *)oldLocation {
    (void)manager;
    (void)oldLocation;
    self.legacyCount++;
    self.lastLegacyLocation = newLocation;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    (void)manager;
    self.headingCount++;
    self.lastHeading = newHeading;
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
    self.authorizationCount++;
}

@end


static void testDelegateProxyTransformsEachUpdateOnceAndForwardsUnrelatedMethods(void) {
    RecordingLocationDelegate *delegate = [[RecordingLocationDelegate alloc] init];
    CLLocation *realLocation = [[CLLocation alloc] initWithLatitude:1.0 longitude:2.0];
    CLLocation *spoofedLocation = [[CLLocation alloc] initWithLatitude:3.0 longitude:4.0];
    id realHeading = @"real-heading";
    id spoofedHeading = @"spoofed-heading";
    CLLocationManager *manager = [[CLLocationManager alloc] init];
    PXLocationDelegateProxy *proxy = [[PXLocationDelegateProxy alloc]
        initWithOriginalDelegate:delegate
        locationTransformer:^NSArray<CLLocation *> *(CLLocationManager *manager,
                                                       NSArray<CLLocation *> *locations) {
            (void)manager;
            assert(locations.count == 1 && locations.firstObject == realLocation);
            return @[spoofedLocation];
        }
        legacyTransformer:^NSArray<CLLocation *> *(CLLocationManager *manager,
                                                    CLLocation *newLocation,
                                                    CLLocation *oldLocation) {
            (void)manager;
            assert(newLocation == realLocation);
            assert(oldLocation == realLocation);
            return @[spoofedLocation];
        }
        headingTransformer:^CLHeading *(CLLocationManager *manager, CLHeading *heading) {
            (void)manager;
            assert((id)heading == realHeading);
            return (CLHeading *)spoofedHeading;
        }];

    [(id<CLLocationManagerDelegate>)proxy locationManager:manager
                                       didUpdateLocations:@[realLocation]];
    [(id<CLLocationManagerDelegate>)proxy locationManager:manager
                                      didUpdateToLocation:realLocation
                                             fromLocation:realLocation];
    [(id<CLLocationManagerDelegate>)proxy locationManager:manager
                                         didUpdateHeading:(CLHeading *)realHeading];
    [(id<CLLocationManagerDelegate>)proxy locationManagerDidChangeAuthorization:manager];
    assert(delegate.modernCount == 1);
    assert(delegate.legacyCount == 1);
    assert(delegate.headingCount == 1);
    assert(delegate.authorizationCount == 1);
    assert(delegate.lastLocations.firstObject == spoofedLocation);
    assert(delegate.lastLegacyLocation == spoofedLocation);
    assert(delegate.lastHeading == spoofedHeading);
    assert(proxy.originalDelegate == delegate);
    assert([proxy respondsToSelector:@selector(locationManager:didUpdateLocations:)]);
    assert(![proxy respondsToSelector:@selector(nonexistentLocationSelector)]);
}

static void testDelegateProxyPassThroughPreservesExactCallbackObjects(void) {
    RecordingLocationDelegate *delegate = [[RecordingLocationDelegate alloc] init];
    CLLocationManager *manager = [[CLLocationManager alloc] init];
    CLLocation *location = [[CLLocation alloc] initWithLatitude:8.0 longitude:9.0];
    id heading = @"unchanged-heading";
    PXLocationDelegateProxy *proxy = [[PXLocationDelegateProxy alloc]
        initWithOriginalDelegate:delegate
        locationTransformer:^NSArray<CLLocation *> *(CLLocationManager *callbackManager,
                                                       NSArray<CLLocation *> *locations) {
            assert(callbackManager == manager);
            return locations;
        }
        legacyTransformer:^NSArray<CLLocation *> *(CLLocationManager *callbackManager,
                                                    CLLocation *newLocation,
                                                    CLLocation *oldLocation) {
            assert(callbackManager == manager);
            return @[newLocation, oldLocation];
        }
        headingTransformer:^CLHeading *(CLLocationManager *callbackManager, CLHeading *newHeading) {
            assert(callbackManager == manager);
            return newHeading;
        }];
    [(id<CLLocationManagerDelegate>)proxy locationManager:manager
                                       didUpdateLocations:@[location]];
    [(id<CLLocationManagerDelegate>)proxy locationManager:manager
                                      didUpdateToLocation:location
                                             fromLocation:location];
    [(id<CLLocationManagerDelegate>)proxy locationManager:manager
                                         didUpdateHeading:(CLHeading *)heading];
    assert(delegate.lastLocations.firstObject == location);
    assert(delegate.lastLegacyLocation == location);
    assert(delegate.lastHeading == heading);
    assert(delegate.modernCount == 1 && delegate.legacyCount == 1 && delegate.headingCount == 1);
}

@interface RealHeadingFixture : NSObject
@property (nonatomic, strong) NSDate *timestamp;
@end


@implementation RealHeadingFixture
- (CLLocationDirection)magneticHeading { return 250.0; }
- (CLLocationDirection)trueHeading { return 255.0; }
- (CLLocationDirection)headingAccuracy { return 1.0; }
- (CLHeadingComponentValue)x { return -100.0; }
- (CLHeadingComponentValue)y { return -100.0; }
- (CLHeadingComponentValue)z { return -100.0; }
@end


static void testCallbackValueObjectsExposeOneCoherentSyntheticSample(void) {
    PXLocationSession *session = [[PXLocationSession alloc]
        initWithGenerationID:@"44444444-4444-4444-8444-444444444444"
        seed:@"value-object-seed"];
    PXLocationSampleInput *input = [[PXLocationSampleInput alloc] init];
    input.latitude = 35.0;
    input.longitude = 139.0;
    input.altitude = 42.0;
    input.desiredHorizontalAccuracy = 9.0;
    input.movementMode = PXLocationMovementModeStationary;
    NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:4000];
    PXLocationSample *locationSample = [session nextLocationSampleForInput:input
                                                           sourceTimestamp:timestamp
                                                                       now:timestamp];
    CLLocation *location = PXLocationFromSample(locationSample);
    assert(PXLocationSampleForLocation(location) == locationSample);
    assert(location.coordinate.latitude == locationSample.latitude);
    assert(location.coordinate.longitude == locationSample.longitude);
    assert(location.altitude == locationSample.altitude);
    assert(location.horizontalAccuracy == locationSample.horizontalAccuracy);
    assert(location.verticalAccuracy == locationSample.verticalAccuracy);
    assert(location.speed == locationSample.speed);
    assert(location.course == locationSample.course);
    assert([location.timestamp isEqualToDate:locationSample.timestamp]);

    PXHeadingSample *headingSample = [session nextHeadingSampleWithSourceTimestamp:timestamp
                                                                                now:timestamp
                                                           orientationOffsetDegrees:0.0];
    RealHeadingFixture *realHeading = [[RealHeadingFixture alloc] init];
    realHeading.timestamp = timestamp;
    CLHeading *heading = PXSyntheticHeadingFromSample(headingSample, (CLHeading *)realHeading);
    assert(PXHeadingSampleForHeading(heading) == headingSample);
    assert([heading isKindOfClass:[CLHeading class]]);
    assert(heading.trueHeading == headingSample.trueHeading);
    assert(heading.magneticHeading == headingSample.magneticHeading);
    assert(heading.headingAccuracy == headingSample.headingAccuracy);
    assert(heading.x == headingSample.x);
    assert(heading.y == headingSample.y);
    assert(heading.z == headingSample.z);
    assert([heading.timestamp isEqualToDate:headingSample.timestamp]);
    assert(heading.trueHeading != [(id)realHeading trueHeading]);
}

static void testGenerationChangeAtomicallyReplacesSessionAndStaleSample(void) {
    PXLocationSessionCache *cache = [[PXLocationSessionCache alloc] init];
    PXLocationSession *first = [cache
        sessionForGenerationID:@"55555555-5555-4555-8555-555555555555"
        seed:@"first-seed"];
    PXLocationSampleInput *input = [[PXLocationSampleInput alloc] init];
    input.latitude = 10.0;
    input.longitude = 20.0;
    input.altitude = 5.0;
    input.desiredHorizontalAccuracy = 8.0;
    NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:5000];
    assert([first nextLocationSampleForInput:input
                            sourceTimestamp:timestamp
                                        now:timestamp] != nil);
    assert([cache sessionForGenerationID:first.generationID seed:@"first-seed"] == first);

    PXLocationSession *second = [cache
        sessionForGenerationID:@"66666666-6666-4666-8666-666666666666"
        seed:@"second-seed"];
    assert(second != first);
    assert(second.currentLocationSample == nil);
    assert(cache.currentSession == second);
    [cache invalidate];
    assert(cache.currentSession == nil);
}

static void testTimestampsAreNeverFutureAndNeverMoveBackward(void) {
    PXLocationSession *session = [[PXLocationSession alloc]
        initWithGenerationID:@"77777777-7777-4777-8777-777777777777"
        seed:@"timestamp-seed"];
    PXLocationSampleInput *input = [[PXLocationSampleInput alloc] init];
    input.latitude = 1.0;
    input.longitude = 1.0;
    input.altitude = 1.0;
    input.desiredHorizontalAccuracy = 5.0;
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:6000];
    NSDate *future = [NSDate dateWithTimeIntervalSince1970:7000];
    PXLocationSample *first = [session nextLocationSampleForInput:input
                                                  sourceTimestamp:future
                                                              now:now];
    assert([first.timestamp isEqualToDate:now]);
    PXLocationSample *second = [session nextLocationSampleForInput:input
                                                   sourceTimestamp:[NSDate dateWithTimeIntervalSince1970:5000]
                                                               now:[NSDate dateWithTimeIntervalSince1970:6001]];
    assert([second.timestamp isEqualToDate:first.timestamp]);

    PXHeadingSample *firstHeading = [session nextHeadingSampleWithSourceTimestamp:future
                                                                                now:now
                                                           orientationOffsetDegrees:0.0];
    PXHeadingSample *secondHeading = [session
        nextHeadingSampleWithSourceTimestamp:[NSDate dateWithTimeIntervalSince1970:5000]
        now:[NSDate dateWithTimeIntervalSince1970:6001]
        orientationOffsetDegrees:0.0];
    assert([firstHeading.timestamp isEqualToDate:now]);
    assert([secondHeading.timestamp isEqualToDate:firstHeading.timestamp]);
}

static void testInitializationGuardSourceReadGuardAndWeakDelegateOwnership(void) {
    __block NSUInteger initializationCount = 0;
    assert(PXInitializeLocationHooksOnce(^{ initializationCount++; }));
    assert(!PXInitializeLocationHooksOnce(^{ initializationCount++; }));
    assert(initializationCount == 1);

    assert(!PXLocationSourceReadInProgress());
    PXBeginLocationSourceRead();
    PXBeginLocationSourceRead();
    assert(PXLocationSourceReadInProgress());
    PXEndLocationSourceRead();
    assert(PXLocationSourceReadInProgress());
    PXEndLocationSourceRead();
    assert(!PXLocationSourceReadInProgress());

    __weak RecordingLocationDelegate *weakDelegate = nil;
    PXLocationDelegateProxy *proxy = nil;
    @autoreleasepool {
        RecordingLocationDelegate *delegate = [[RecordingLocationDelegate alloc] init];
        weakDelegate = delegate;
        proxy = [[PXLocationDelegateProxy alloc]
            initWithOriginalDelegate:delegate
            locationTransformer:^NSArray<CLLocation *> *(CLLocationManager *manager,
                                                          NSArray<CLLocation *> *locations) {
                (void)manager;
                return locations;
            }
            legacyTransformer:^NSArray<CLLocation *> *(CLLocationManager *manager,
                                                        CLLocation *newLocation,
                                                        CLLocation *oldLocation) {
                (void)manager;
                return oldLocation ? @[newLocation, oldLocation] : @[newLocation];
            }
            headingTransformer:^CLHeading *(CLLocationManager *manager, CLHeading *heading) {
                (void)manager;
                return heading;
            }];
    }
    assert(weakDelegate == nil);
    assert(proxy.originalDelegate == nil);
}

int main(void) {
    @autoreleasepool {
        testStationarySampleIsCoherentAndBounded();
        testRouteSampleUsesSegmentBearingAndTransportationSpeedLimit();
        testHeadingIsNormalizedSmoothAndCoherentWithRouteCourse();
        testHeadingBeforeFirstLocationUsesStationaryOrientation();
        testDelegateProxyTransformsEachUpdateOnceAndForwardsUnrelatedMethods();
        testDelegateProxyPassThroughPreservesExactCallbackObjects();
        testCallbackValueObjectsExposeOneCoherentSyntheticSample();
        testGenerationChangeAtomicallyReplacesSessionAndStaleSample();
        testTimestampsAreNeverFutureAndNeverMoveBackward();
        testInitializationGuardSourceReadGuardAndWeakDelegateOwnership();
    }
    return 0;
}
