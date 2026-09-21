#import "LocationSession.h"

#include <math.h>
#import <objc/runtime.h>

static __thread NSUInteger PXLocationSourceReadDepth = 0;
static char PXLocationSampleAssociationKey;
static char PXHeadingSampleAssociationKey;

void PXBeginLocationSourceRead(void) {
    PXLocationSourceReadDepth++;
}

void PXEndLocationSourceRead(void) {
    if (PXLocationSourceReadDepth > 0) {
        PXLocationSourceReadDepth--;
    }
}

BOOL PXLocationSourceReadInProgress(void) {
    return PXLocationSourceReadDepth > 0;
}

BOOL PXInitializeLocationHooksOnce(void (^initializer)(void)) {
    if (!initializer) {
        return NO;
    }
    static dispatch_once_t onceToken;
    __block BOOL initialized = NO;
    dispatch_once(&onceToken, ^{
        initializer();
        initialized = YES;
    });
    return initialized;
}

double PXNormalizeDirection(double direction) {
    if (!isfinite(direction)) {
        return 0.0;
    }
    double normalized = fmod(direction, 360.0);
    return normalized < 0.0 ? normalized + 360.0 : normalized;
}

@implementation PXLocationPoint

- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude {
    self = [super init];
    if (self) {
        _latitude = latitude;
        _longitude = longitude;
    }
    return self;
}

@end


@implementation PXLocationSampleInput
@end

@interface PXLocationSample ()

@property (nonatomic, copy, readwrite) NSString *generationID;
@property (nonatomic, copy, readwrite) NSString *source;
@property (nonatomic, assign, readwrite) double latitude;
@property (nonatomic, assign, readwrite) double longitude;
@property (nonatomic, assign, readwrite) double altitude;
@property (nonatomic, assign, readwrite) double horizontalAccuracy;
@property (nonatomic, assign, readwrite) double verticalAccuracy;
@property (nonatomic, assign, readwrite) double speed;
@property (nonatomic, assign, readwrite) double course;
@property (nonatomic, strong, readwrite) NSDate *timestamp;

@end


@implementation PXLocationSample
@end

@interface PXHeadingSample ()

@property (nonatomic, copy, readwrite) NSString *generationID;
@property (nonatomic, assign, readwrite) double magneticHeading;
@property (nonatomic, assign, readwrite) double trueHeading;
@property (nonatomic, assign, readwrite) double declination;
@property (nonatomic, assign, readwrite) double headingAccuracy;
@property (nonatomic, assign, readwrite) double x;
@property (nonatomic, assign, readwrite) double y;
@property (nonatomic, assign, readwrite) double z;
@property (nonatomic, strong, readwrite) NSDate *timestamp;

@end


@implementation PXHeadingSample
@end

CLLocation *PXLocationFromSample(PXLocationSample *sample) {
    if (!sample) {
        return nil;
    }
    CLLocation *location = [[CLLocation alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(sample.latitude, sample.longitude)
        altitude:sample.altitude
        horizontalAccuracy:sample.horizontalAccuracy
        verticalAccuracy:sample.verticalAccuracy
        course:sample.course
        speed:sample.speed
        timestamp:sample.timestamp];
    objc_setAssociatedObject(location,
                             &PXLocationSampleAssociationKey,
                             sample,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return location;
}

PXLocationSample *PXLocationSampleForLocation(CLLocation *location) {
    return location ? objc_getAssociatedObject(location, &PXLocationSampleAssociationKey) : nil;
}

@interface PXSyntheticHeadingProxy : NSProxy

@property (nonatomic, strong) PXHeadingSample *sample;
@property (nonatomic, strong, nullable) CLHeading *sourceHeading;

@end


@implementation PXSyntheticHeadingProxy

- (CLLocationDirection)magneticHeading { return self.sample.magneticHeading; }
- (CLLocationDirection)trueHeading { return self.sample.trueHeading; }
- (CLLocationDirection)headingAccuracy { return self.sample.headingAccuracy; }
- (CLHeadingComponentValue)x { return self.sample.x; }
- (CLHeadingComponentValue)y { return self.sample.y; }
- (CLHeadingComponentValue)z { return self.sample.z; }
- (NSDate *)timestamp { return self.sample.timestamp; }
- (Class)class { return [CLHeading class]; }
- (BOOL)isKindOfClass:(Class)candidateClass {
    return [[CLHeading class] isSubclassOfClass:candidateClass];
}
- (BOOL)isMemberOfClass:(Class)candidateClass {
    return candidateClass == [CLHeading class];
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(magneticHeading) || selector == @selector(trueHeading) ||
        selector == @selector(headingAccuracy) || selector == @selector(x) ||
        selector == @selector(y) || selector == @selector(z) || selector == @selector(timestamp)) {
        return YES;
    }
    return [self.sourceHeading respondsToSelector:selector] || [super respondsToSelector:selector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSMethodSignature *signature = [(id)self.sourceHeading methodSignatureForSelector:selector];
    return signature ?: [CLHeading instanceMethodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (self.sourceHeading && [self.sourceHeading respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:self.sourceHeading];
        return;
    }
    [NSException raise:NSInvalidArgumentException
                format:@"Synthetic heading does not respond to %@",
                       NSStringFromSelector(invocation.selector)];
}

@end

CLHeading *PXSyntheticHeadingFromSample(PXHeadingSample *sample, CLHeading *sourceHeading) {
    if (!sample) {
        return sourceHeading;
    }
    PXSyntheticHeadingProxy *proxy = [PXSyntheticHeadingProxy alloc];
    proxy.sample = sample;
    proxy.sourceHeading = sourceHeading;
    objc_setAssociatedObject(proxy,
                             &PXHeadingSampleAssociationKey,
                             sample,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return (CLHeading *)proxy;
}

PXHeadingSample *PXHeadingSampleForHeading(CLHeading *heading) {
    return heading ? objc_getAssociatedObject(heading, &PXHeadingSampleAssociationKey) : nil;
}

@interface PXLocationSession ()

@property (nonatomic, copy, readwrite) NSString *generationID;
@property (nonatomic, strong, readwrite, nullable) PXLocationSample *currentLocationSample;
@property (nonatomic, strong, readwrite, nullable) PXHeadingSample *currentHeadingSample;
@property (nonatomic, assign) uint64_t randomState;
@property (nonatomic, assign) double northDriftMeters;
@property (nonatomic, assign) double eastDriftMeters;
@property (nonatomic, assign) double lastCourse;
@property (nonatomic, assign) BOOL hasLastCourse;
@property (nonatomic, assign) double declination;
@property (nonatomic, assign) double stationaryOrientation;
@property (nonatomic, assign) double lastTrueHeading;
@property (nonatomic, assign) BOOL hasHeading;

@end


@implementation PXLocationSession

- (instancetype)initWithGenerationID:(NSString *)generationID seed:(NSString *)seed {
    if (![[NSUUID alloc] initWithUUIDString:generationID] || seed.length == 0) {
        return nil;
    }
    self = [super init];
    if (self) {
        _generationID = [generationID.lowercaseString copy];
        NSData *seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];
        const uint8_t *bytes = seedData.bytes;
        uint64_t hash = 1469598103934665603ULL;
        for (NSUInteger index = 0; index < seedData.length; index++) {
            hash ^= bytes[index];
            hash *= 1099511628211ULL;
        }
        _randomState = hash ?: 0x9e3779b97f4a7c15ULL;
        _declination = ((double)(_randomState % 3001) / 100.0) - 15.0;
        _stationaryOrientation = (double)((_randomState >> 16) % 36000) / 100.0;
    }
    return self;
}

- (double)nextUnitValue {
    self.randomState += 0x9e3779b97f4a7c15ULL;
    uint64_t value = self.randomState;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
    value ^= value >> 31;
    return (double)(value >> 11) / (double)(1ULL << 53);
}

static BOOL PXLocationInputIsValid(PXLocationSampleInput *input) {
    return input && isfinite(input.latitude) && isfinite(input.longitude) &&
        input.latitude >= -90.0 && input.latitude <= 90.0 &&
        input.longitude >= -180.0 && input.longitude <= 180.0 &&
        isfinite(input.altitude) && isfinite(input.desiredHorizontalAccuracy) &&
        isfinite(input.driftRadiusMeters) && isfinite(input.requestedSpeed);
}

static BOOL PXLocationPointIsValid(PXLocationPoint *point) {
    return point && isfinite(point.latitude) && isfinite(point.longitude) &&
        point.latitude >= -90.0 && point.latitude <= 90.0 &&
        point.longitude >= -180.0 && point.longitude <= 180.0;
}

static double PXLocationBearing(PXLocationPoint *start, PXLocationPoint *end) {
    double latitude1 = start.latitude * M_PI / 180.0;
    double latitude2 = end.latitude * M_PI / 180.0;
    double longitudeDifference = (end.longitude - start.longitude) * M_PI / 180.0;
    double y = sin(longitudeDifference) * cos(latitude2);
    double x = cos(latitude1) * sin(latitude2) -
        sin(latitude1) * cos(latitude2) * cos(longitudeDifference);
    return PXNormalizeDirection(atan2(y, x) * 180.0 / M_PI);
}

static double PXShortestDirectionDelta(double fromDirection, double toDirection) {
    double delta = PXNormalizeDirection(toDirection) - PXNormalizeDirection(fromDirection);
    if (delta > 180.0) delta -= 360.0;
    if (delta < -180.0) delta += 360.0;
    return delta;
}

- (NSDate *)timestampFromSource:(NSDate *)sourceTimestamp now:(NSDate *)now {
    if (![sourceTimestamp isKindOfClass:[NSDate class]] || ![now isKindOfClass:[NSDate class]]) {
        return nil;
    }
    NSDate *timestamp = [sourceTimestamp compare:now] == NSOrderedDescending ? now : sourceTimestamp;
    if (self.currentLocationSample &&
        [timestamp compare:self.currentLocationSample.timestamp] == NSOrderedAscending) {
        timestamp = self.currentLocationSample.timestamp;
    }
    return timestamp;
}

- (PXLocationSample *)nextLocationSampleForInput:(PXLocationSampleInput *)input
                                  sourceTimestamp:(NSDate *)sourceTimestamp
                                              now:(NSDate *)now {
    @synchronized(self) {
        NSDate *timestamp = [self timestampFromSource:sourceTimestamp now:now];
        if (!PXLocationInputIsValid(input) || !timestamp) {
            return nil;
        }
        double radius = MAX(0.0, MIN(5.0, input.driftRadiusMeters));
        double targetAngle = [self nextUnitValue] * 2.0 * M_PI;
        double targetRadius = sqrt([self nextUnitValue]) * radius;
        double targetNorth = cos(targetAngle) * targetRadius;
        double targetEast = sin(targetAngle) * targetRadius;
        self.northDriftMeters += MAX(-0.5, MIN(0.5, targetNorth - self.northDriftMeters));
        self.eastDriftMeters += MAX(-0.5, MIN(0.5, targetEast - self.eastDriftMeters));
        double driftMagnitude = hypot(self.northDriftMeters, self.eastDriftMeters);
        if (driftMagnitude > radius && driftMagnitude > 0.0) {
            self.northDriftMeters *= radius / driftMagnitude;
            self.eastDriftMeters *= radius / driftMagnitude;
        }
        double latitude = input.latitude + self.northDriftMeters / 111000.0;
        double longitudeScale = MAX(0.01, cos(input.latitude * M_PI / 180.0));
        double longitude = input.longitude + self.eastDriftMeters / (111000.0 * longitudeScale);
        double horizontalAccuracy = MAX(5.0, MIN(50.0,
            input.desiredHorizontalAccuracy + ([self nextUnitValue] - 0.5) * 2.0));
        BOOL hasRoute = input.movementMode != PXLocationMovementModeStationary &&
            PXLocationPointIsValid(input.segmentStart) && PXLocationPointIsValid(input.segmentEnd) &&
            (input.segmentStart.latitude != input.segmentEnd.latitude ||
             input.segmentStart.longitude != input.segmentEnd.longitude);
        double speed = 0.0;
        double course = -1.0;
        if (hasRoute) {
            double requestedSpeed = input.requestedSpeed;
            if (input.movementMode == PXLocationMovementModeWalking) {
                speed = MAX(0.5, MIN(2.2, requestedSpeed > 0.0 ? requestedSpeed : 1.4));
            } else {
                speed = MAX(2.0, MIN(45.0, requestedSpeed > 0.0 ? requestedSpeed : 15.0));
            }
            double targetCourse = PXLocationBearing(input.segmentStart, input.segmentEnd);
            if (!self.hasLastCourse) {
                course = targetCourse;
                self.hasLastCourse = YES;
            } else {
                double courseDelta = PXShortestDirectionDelta(self.lastCourse, targetCourse);
                course = PXNormalizeDirection(self.lastCourse + MAX(-20.0, MIN(20.0, courseDelta)));
            }
            self.lastCourse = course;
        }

        PXLocationSample *sample = [[PXLocationSample alloc] init];
        sample.generationID = self.generationID;
        sample.source = hasRoute ? @"route" : @"stationary";
        sample.latitude = latitude;
        sample.longitude = longitude;
        sample.altitude = input.altitude + ([self nextUnitValue] - 0.5);
        sample.horizontalAccuracy = horizontalAccuracy;
        sample.verticalAccuracy = MAX(horizontalAccuracy, horizontalAccuracy * 1.25);
        sample.speed = speed;
        sample.course = course;
        sample.timestamp = timestamp;
        self.currentLocationSample = sample;
        return sample;
    }
}

- (PXHeadingSample *)nextHeadingSampleWithSourceTimestamp:(NSDate *)sourceTimestamp
                                                       now:(NSDate *)now
                                  orientationOffsetDegrees:(double)orientationOffsetDegrees {
    @synchronized(self) {
        if (![sourceTimestamp isKindOfClass:[NSDate class]] || ![now isKindOfClass:[NSDate class]] ||
            !isfinite(orientationOffsetDegrees)) {
            return nil;
        }
        NSDate *timestamp = [sourceTimestamp compare:now] == NSOrderedDescending ? now : sourceTimestamp;
        if (self.currentHeadingSample &&
            [timestamp compare:self.currentHeadingSample.timestamp] == NSOrderedAscending) {
            timestamp = self.currentHeadingSample.timestamp;
        }
        double targetHeading = 0.0;
        if (self.currentLocationSample && self.currentLocationSample.course >= 0.0) {
            targetHeading = self.currentLocationSample.course + orientationOffsetDegrees;
        } else {
            self.stationaryOrientation = PXNormalizeDirection(
                self.stationaryOrientation + ([self nextUnitValue] - 0.5) * 2.0
            );
            targetHeading = self.stationaryOrientation + orientationOffsetDegrees;
        }
        targetHeading = PXNormalizeDirection(targetHeading);
        double trueHeading = targetHeading;
        if (self.hasHeading) {
            double delta = PXShortestDirectionDelta(self.lastTrueHeading, targetHeading);
            trueHeading = PXNormalizeDirection(self.lastTrueHeading + MAX(-8.0, MIN(8.0, delta)));
        }
        self.hasHeading = YES;
        self.lastTrueHeading = trueHeading;
        double magneticHeading = PXNormalizeDirection(trueHeading - self.declination);
        double magneticRadians = magneticHeading * M_PI / 180.0;
        double horizontalField = 42.0;

        PXHeadingSample *sample = [[PXHeadingSample alloc] init];
        sample.generationID = self.generationID;
        sample.trueHeading = trueHeading;
        sample.magneticHeading = magneticHeading;
        sample.declination = self.declination;
        sample.headingAccuracy = 4.0 + [self nextUnitValue] * 4.0;
        sample.x = horizontalField * cos(magneticRadians);
        sample.y = horizontalField * sin(magneticRadians);
        sample.z = 12.0 + ([self nextUnitValue] - 0.5) * 2.0;
        sample.timestamp = timestamp;
        self.currentHeadingSample = sample;
        return sample;
    }
}

@end

@interface PXLocationSessionCache ()

@property (nonatomic, strong, readwrite, nullable) PXLocationSession *currentSession;
@property (nonatomic, copy, nullable) NSString *currentSeed;

@end


@implementation PXLocationSessionCache

- (PXLocationSession *)sessionForGenerationID:(NSString *)generationID seed:(NSString *)seed {
    @synchronized(self) {
        if ([self.currentSession.generationID caseInsensitiveCompare:generationID] == NSOrderedSame &&
            [self.currentSeed isEqualToString:seed]) {
            return self.currentSession;
        }
        PXLocationSession *replacement = [[PXLocationSession alloc]
            initWithGenerationID:generationID
            seed:seed];
        if (!replacement) {
            return nil;
        }
        self.currentSession = replacement;
        self.currentSeed = [seed copy];
        return replacement;
    }
}

- (void)invalidate {
    @synchronized(self) {
        self.currentSession = nil;
        self.currentSeed = nil;
    }
}

@end

@interface PXLocationDelegateProxy ()

@property (nonatomic, weak, readwrite, nullable) id<CLLocationManagerDelegate> originalDelegate;
@property (nonatomic, copy) PXLocationArrayTransformer locationTransformer;
@property (nonatomic, copy) PXLegacyLocationTransformer legacyTransformer;
@property (nonatomic, copy) PXHeadingTransformer headingTransformer;

@end


@implementation PXLocationDelegateProxy

- (instancetype)initWithOriginalDelegate:(id<CLLocationManagerDelegate>)originalDelegate
                      locationTransformer:(PXLocationArrayTransformer)locationTransformer
                        legacyTransformer:(PXLegacyLocationTransformer)legacyTransformer
                       headingTransformer:(PXHeadingTransformer)headingTransformer {
    _originalDelegate = originalDelegate;
    _locationTransformer = [locationTransformer copy];
    _legacyTransformer = [legacyTransformer copy];
    _headingTransformer = [headingTransformer copy];
    return self;
}

- (BOOL)respondsToSelector:(SEL)selector {
    id<CLLocationManagerDelegate> delegate = self.originalDelegate;
    if (selector == @selector(locationManager:didUpdateLocations:) ||
        selector == @selector(locationManager:didUpdateToLocation:fromLocation:) ||
        selector == @selector(locationManager:didUpdateHeading:)) {
        return [delegate respondsToSelector:selector];
    }
    return [delegate respondsToSelector:selector] || [super respondsToSelector:selector];
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    return [self.originalDelegate conformsToProtocol:protocol] ||
        protocol == @protocol(CLLocationManagerDelegate);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [(id)self.originalDelegate methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    id<CLLocationManagerDelegate> delegate = self.originalDelegate;
    if (delegate && [delegate respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:delegate];
        return;
    }
    [NSException raise:NSInvalidArgumentException
                format:@"Location delegate does not respond to %@",
                       NSStringFromSelector(invocation.selector)];
}

- (void)locationManager:(CLLocationManager *)manager
      didUpdateLocations:(NSArray<CLLocation *> *)locations {
    id<CLLocationManagerDelegate> delegate = self.originalDelegate;
    if (locations.count == 0 || ![delegate respondsToSelector:_cmd]) {
        return;
    }
    NSArray<CLLocation *> *transformed = self.locationTransformer
        ? self.locationTransformer(manager, locations)
        : locations;
    [delegate locationManager:manager didUpdateLocations:transformed ?: locations];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)locationManager:(CLLocationManager *)manager
     didUpdateToLocation:(CLLocation *)newLocation
            fromLocation:(CLLocation *)oldLocation {
    id<CLLocationManagerDelegate> delegate = self.originalDelegate;
    if (!newLocation || ![delegate respondsToSelector:_cmd]) {
        return;
    }
    NSArray<CLLocation *> *transformed = self.legacyTransformer
        ? self.legacyTransformer(manager, newLocation, oldLocation)
        : nil;
    CLLocation *transformedNewLocation = transformed.count > 0 ? transformed[0] : newLocation;
    CLLocation *transformedOldLocation = transformed.count > 1 ? transformed[1] : oldLocation;
    [delegate locationManager:manager
          didUpdateToLocation:transformedNewLocation
                 fromLocation:transformedOldLocation];
}
#pragma clang diagnostic pop

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    id<CLLocationManagerDelegate> delegate = self.originalDelegate;
    if (!newHeading || ![delegate respondsToSelector:_cmd]) {
        return;
    }
    CLHeading *transformed = self.headingTransformer
        ? self.headingTransformer(manager, newHeading)
        : newHeading;
    [delegate locationManager:manager didUpdateHeading:transformed ?: newHeading];
}

@end
