#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>

#import "LocationSpoofingManager.h"
#import "PXProcessHookPolicy.h"
#import "ProjectXLogging.h"

@interface PXMotionDataProxy : NSProxy
- (instancetype)initWithSource:(id)source vector:(CMAcceleration)vector selector:(SEL)selector;
@end

@implementation PXMotionDataProxy {
    id _source;
    CMAcceleration _vector;
    SEL _vectorSelector;
}

- (instancetype)initWithSource:(id)source vector:(CMAcceleration)vector selector:(SEL)selector {
    _source = source;
    _vector = vector;
    _vectorSelector = selector;
    return self;
}

- (CMAcceleration)acceleration { return _vector; }
- (CMRotationRate)rotationRate {
    return (CMRotationRate){ _vector.x, _vector.y, _vector.z };
}
- (CMMagneticField)magneticField {
    return (CMMagneticField){ _vector.x, _vector.y, _vector.z };
}
- (NSTimeInterval)timestamp {
    return [_source respondsToSelector:_cmd]
        ? [(CMLogItem *)_source timestamp]
        : NSProcessInfo.processInfo.systemUptime;
}
- (BOOL)respondsToSelector:(SEL)selector {
    return selector == _vectorSelector || selector == @selector(timestamp) ||
        [_source respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_source methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    if ([_source respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:_source];
    } else {
        [NSException raise:NSInvalidArgumentException
                    format:@"Unrecognized selector %@ sent to sensor proxy",
                           NSStringFromSelector(invocation.selector)];
    }
}
- (Class)class { return [_source class]; }
- (BOOL)isKindOfClass:(Class)aClass { return [_source isKindOfClass:aClass]; }
@end

@interface PXAltitudeDataProxy : NSProxy
- (instancetype)initWithSource:(CMAltitudeData *)source
              relativeAltitude:(NSNumber *)relativeAltitude
                       pressure:(NSNumber *)pressure;
@end

@implementation PXAltitudeDataProxy {
    CMAltitudeData *_source;
    NSNumber *_relativeAltitude;
    NSNumber *_pressure;
}
- (instancetype)initWithSource:(CMAltitudeData *)source
              relativeAltitude:(NSNumber *)relativeAltitude
                       pressure:(NSNumber *)pressure {
    _source = source;
    _relativeAltitude = relativeAltitude;
    _pressure = pressure;
    return self;
}
- (NSNumber *)relativeAltitude { return _relativeAltitude; }
- (NSNumber *)pressure { return _pressure; }
- (NSTimeInterval)timestamp {
    return [_source respondsToSelector:_cmd]
        ? _source.timestamp
        : NSProcessInfo.processInfo.systemUptime;
}
- (BOOL)respondsToSelector:(SEL)selector {
    return selector == @selector(relativeAltitude) || selector == @selector(pressure) ||
        selector == @selector(timestamp) || [_source respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_source methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    if ([_source respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:_source];
    } else {
        [NSException raise:NSInvalidArgumentException
                    format:@"Unrecognized selector %@ sent to altitude proxy",
                           NSStringFromSelector(invocation.selector)];
    }
}
- (Class)class { return [_source class]; }
- (BOOL)isKindOfClass:(Class)aClass { return [_source isKindOfClass:aClass]; }
@end

static LocationSpoofingManager *PXActiveSensorManager(void) {
    LocationSpoofingManager *manager = [LocationSpoofingManager sharedManager];
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    return manager.isSpoofingEnabled && bundleIdentifier.length > 0 &&
        [manager shouldSpoofApp:bundleIdentifier] ? manager : nil;
}

static CMAcceleration PXAccelerationForManager(LocationSpoofingManager *manager) {
    double radians = manager.lastReportedCourse * M_PI / 180.0;
    double movement = MIN(MAX(manager.lastReportedSpeed, 0.0) * 0.01, 0.2);
    return (CMAcceleration){ cos(radians) * movement,
                             sin(radians) * movement,
                             -1.0 };
}

static CMRotationRate PXRotationForManager(LocationSpoofingManager *manager) {
    double radians = manager.lastReportedCourse * M_PI / 180.0;
    double scale = manager.transportationMode == TransportationModeDriving ? 0.025 : 0.01;
    return (CMRotationRate){ sin(radians) * scale, cos(radians) * scale, 0.0 };
}

static CMMagneticField PXMagneticFieldForManager(LocationSpoofingManager *manager) {
    double radians = manager.lastReportedCourse * M_PI / 180.0;
    return (CMMagneticField){ 30.0 * cos(radians), 30.0 * sin(radians), 0.0 };
}

static id PXMotionProxy(id source, CMAcceleration vector, SEL selector) {
    if (!source) return nil;
    return [[PXMotionDataProxy alloc] initWithSource:source vector:vector selector:selector];
}

%hook CMMotionManager

- (CMAccelerometerData *)accelerometerData {
    CMAccelerometerData *source = %orig;
    LocationSpoofingManager *manager = PXActiveSensorManager();
    return manager ? PXMotionProxy(source, PXAccelerationForManager(manager), @selector(acceleration)) : source;
}

- (CMGyroData *)gyroData {
    CMGyroData *source = %orig;
    LocationSpoofingManager *manager = PXActiveSensorManager();
    CMRotationRate value = manager ? PXRotationForManager(manager) : (CMRotationRate){0, 0, 0};
    return manager ? PXMotionProxy(source, (CMAcceleration){value.x, value.y, value.z}, @selector(rotationRate)) : source;
}

- (CMMagnetometerData *)magnetometerData {
    CMMagnetometerData *source = %orig;
    LocationSpoofingManager *manager = PXActiveSensorManager();
    CMMagneticField value = manager ? PXMagneticFieldForManager(manager) : (CMMagneticField){0, 0, 0};
    return manager ? PXMotionProxy(source, (CMAcceleration){value.x, value.y, value.z}, @selector(magneticField)) : source;
}

- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue
                             withHandler:(CMAccelerometerHandler)handler {
    CMAccelerometerHandler wrapped = ^(CMAccelerometerData *source, NSError *error) {
        LocationSpoofingManager *manager = PXActiveSensorManager();
        handler(manager ? PXMotionProxy(source, PXAccelerationForManager(manager), @selector(acceleration)) : source,
                error);
    };
    %orig(queue, handler ? wrapped : nil);
}

- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {
    CMGyroHandler wrapped = ^(CMGyroData *source, NSError *error) {
        LocationSpoofingManager *manager = PXActiveSensorManager();
        CMRotationRate value = manager ? PXRotationForManager(manager) : (CMRotationRate){0, 0, 0};
        handler(manager ? PXMotionProxy(source, (CMAcceleration){value.x, value.y, value.z}, @selector(rotationRate)) : source,
                error);
    };
    %orig(queue, handler ? wrapped : nil);
}

- (void)startMagnetometerUpdatesToQueue:(NSOperationQueue *)queue
                            withHandler:(CMMagnetometerHandler)handler {
    CMMagnetometerHandler wrapped = ^(CMMagnetometerData *source, NSError *error) {
        LocationSpoofingManager *manager = PXActiveSensorManager();
        CMMagneticField value = manager ? PXMagneticFieldForManager(manager) : (CMMagneticField){0, 0, 0};
        handler(manager ? PXMotionProxy(source, (CMAcceleration){value.x, value.y, value.z}, @selector(magneticField)) : source,
                error);
    };
    %orig(queue, handler ? wrapped : nil);
}

%end


%hook CMAltimeter

- (void)startRelativeAltitudeUpdatesToQueue:(NSOperationQueue *)queue
                                withHandler:(CMAltitudeHandler)handler {
    CMAltitudeHandler wrapped = ^(CMAltitudeData *source, NSError *error) {
        LocationSpoofingManager *manager = PXActiveSensorManager();
        if (!manager || !source) {
            handler(source, error);
            return;
        }
        double range = manager.transportationMode == TransportationModeDriving ? 5.0 :
            (manager.transportationMode == TransportationModeWalking ? 2.5 : 1.0);
        double relativeAltitude = (double)arc4random_uniform(1001) / 1000.0 * 2.0 * range - range;
        NSNumber *pressure = @((1013.25 - relativeAltitude * 0.12) / 10.0);
        handler((CMAltitudeData *)[[PXAltitudeDataProxy alloc]
            initWithSource:source
            relativeAltitude:@(relativeAltitude)
            pressure:pressure], error);
    };
    %orig(queue, handler ? wrapped : nil);
}

%end


%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) return;
        %init;
        PXLog(@"[WeaponX] CoreMotion sensor proxy hooks initialized");
    }
}
