#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PXEnvironmentFailureDiagnostic : NSObject

@property (nonatomic, copy, readonly) NSString *stage;
@property (nonatomic, copy, readonly, nullable) NSString *target;
@property (nonatomic, copy, readonly) NSString *message;
@property (nonatomic, copy, readonly) NSString *errorDomain;
@property (nonatomic, assign, readonly) NSInteger errorCode;

- (instancetype)initWithStage:(NSString *)stage
                        target:(nullable NSString *)target
                       message:(NSString *)message;
- (instancetype)initWithStage:(NSString *)stage
                        target:(nullable NSString *)target
                       message:(NSString *)message
                   errorDomain:(NSString *)errorDomain
                     errorCode:(NSInteger)errorCode NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PXEnvironmentFailureReport : NSObject

@property (nonatomic, copy, readonly) NSString *summary;
@property (nonatomic, copy, readonly) NSArray<PXEnvironmentFailureDiagnostic *> *diagnostics;
@property (nonatomic, strong, readonly) NSDate *timestamp;
@property (nonatomic, copy, readonly) NSString *reference;

- (instancetype)initWithSummary:(NSString *)summary
                     diagnostics:(NSArray<PXEnvironmentFailureDiagnostic *> *)diagnostics
                       timestamp:(NSDate *)timestamp
                       reference:(NSString *)reference NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (NSString *)localizedTimestamp;
- (NSString *)redactedTextRepresentation;
- (BOOL)persistAsLastReportWithError:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)lastPersistedReportWithError:(NSError * _Nullable * _Nullable)error;
+ (BOOL)clearLastPersistedReportWithError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
