#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PXLocationSample;
@class PXHeadingSample;

typedef NS_ENUM(NSInteger, PXLocationMovementMode) {
    PXLocationMovementModeStationary = 0,
    PXLocationMovementModeWalking = 1,
    PXLocationMovementModeDriving = 2
};

FOUNDATION_EXPORT BOOL PXInitializeLocationHooksOnce(void (^initializer)(void));
FOUNDATION_EXPORT double PXNormalizeDirection(double direction);
FOUNDATION_EXPORT void PXBeginLocationSourceRead(void);
FOUNDATION_EXPORT void PXEndLocationSourceRead(void);
FOUNDATION_EXPORT BOOL PXLocationSourceReadInProgress(void);

@interface PXLocationPoint : NSObject

@property (nonatomic, assign, readonly) double latitude;
@property (nonatomic, assign, readonly) double longitude;

- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude;

@end

@interface PXLocationSampleInput : NSObject

@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) double longitude;
@property (nonatomic, assign) double altitude;
@property (nonatomic, assign) double desiredHorizontalAccuracy;
@property (nonatomic, assign) double driftRadiusMeters;
@property (nonatomic, assign) double requestedSpeed;
@property (nonatomic, assign) PXLocationMovementMode movementMode;
@property (nonatomic, strong, nullable) PXLocationPoint *segmentStart;
@property (nonatomic, strong, nullable) PXLocationPoint *segmentEnd;

@end


@interface PXLocationSample : NSObject

@property (nonatomic, copy, readonly) NSString *generationID;
@property (nonatomic, copy, readonly) NSString *source;
@property (nonatomic, assign, readonly) double latitude;
@property (nonatomic, assign, readonly) double longitude;
@property (nonatomic, assign, readonly) double altitude;
@property (nonatomic, assign, readonly) double horizontalAccuracy;
@property (nonatomic, assign, readonly) double verticalAccuracy;
@property (nonatomic, assign, readonly) double speed;
@property (nonatomic, assign, readonly) double course;
@property (nonatomic, strong, readonly) NSDate *timestamp;

@end


@interface PXHeadingSample : NSObject

@property (nonatomic, copy, readonly) NSString *generationID;
@property (nonatomic, assign, readonly) double magneticHeading;
@property (nonatomic, assign, readonly) double trueHeading;
@property (nonatomic, assign, readonly) double declination;
@property (nonatomic, assign, readonly) double headingAccuracy;
@property (nonatomic, assign, readonly) double x;
@property (nonatomic, assign, readonly) double y;
@property (nonatomic, assign, readonly) double z;
@property (nonatomic, strong, readonly) NSDate *timestamp;

@end


@interface PXLocationSession : NSObject

@property (nonatomic, copy, readonly) NSString *generationID;
@property (nonatomic, strong, readonly, nullable) PXLocationSample *currentLocationSample;
@property (nonatomic, strong, readonly, nullable) PXHeadingSample *currentHeadingSample;

- (nullable instancetype)initWithGenerationID:(NSString *)generationID
                                          seed:(NSString *)seed;
- (nullable PXLocationSample *)nextLocationSampleForInput:(PXLocationSampleInput *)input
                                           sourceTimestamp:(NSDate *)sourceTimestamp
                                                       now:(NSDate *)now;
- (nullable PXHeadingSample *)nextHeadingSampleWithSourceTimestamp:(NSDate *)sourceTimestamp
                                                                now:(NSDate *)now
                                           orientationOffsetDegrees:(double)orientationOffsetDegrees;

@end

@interface PXLocationSessionCache : NSObject

@property (nonatomic, strong, readonly, nullable) PXLocationSession *currentSession;

- (nullable PXLocationSession *)sessionForGenerationID:(NSString *)generationID
                                                   seed:(NSString *)seed;
- (void)invalidate;

@end

FOUNDATION_EXPORT CLLocation *PXLocationFromSample(PXLocationSample *sample);
FOUNDATION_EXPORT PXLocationSample * _Nullable PXLocationSampleForLocation(CLLocation *location);
FOUNDATION_EXPORT CLHeading *PXSyntheticHeadingFromSample(PXHeadingSample *sample,
                                                          CLHeading * _Nullable sourceHeading);
FOUNDATION_EXPORT PXHeadingSample * _Nullable PXHeadingSampleForHeading(CLHeading *heading);

typedef NSArray<CLLocation *> * _Nonnull (^PXLocationArrayTransformer)(
    CLLocationManager *manager,
    NSArray<CLLocation *> *locations
);
typedef NSArray<CLLocation *> * _Nonnull (^PXLegacyLocationTransformer)(
    CLLocationManager *manager,
    CLLocation *newLocation,
    CLLocation * _Nullable oldLocation
);
typedef CLHeading * _Nonnull (^PXHeadingTransformer)(
    CLLocationManager *manager,
    CLHeading *heading
);

@interface PXLocationDelegateProxy : NSProxy

@property (nonatomic, weak, readonly, nullable) id<CLLocationManagerDelegate> originalDelegate;

- (instancetype)initWithOriginalDelegate:(id<CLLocationManagerDelegate>)originalDelegate
                      locationTransformer:(PXLocationArrayTransformer)locationTransformer
                        legacyTransformer:(PXLegacyLocationTransformer)legacyTransformer
                       headingTransformer:(PXHeadingTransformer)headingTransformer;

@end


NS_ASSUME_NONNULL_END
