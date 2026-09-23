#import <Foundation/Foundation.h>

@interface DeviceModelManager : NSObject

// Returns the user-friendly name for a given device string (e.g., iPhone15,2 -> iPhone 14 Pro)
- (NSString *)deviceModelNameForString:(NSString *)deviceString;

// Device Specifications for a given device model
- (NSDictionary *)deviceSpecificationsForModel:(NSString *)deviceString;
- (NSString *)screenResolutionForModel:(NSString *)deviceString;
- (NSString *)viewportResolutionForModel:(NSString *)deviceString;
- (CGFloat)devicePixelRatioForModel:(NSString *)deviceString;
- (NSInteger)screenDensityForModel:(NSString *)deviceString;
- (NSString *)cpuArchitectureForModel:(NSString *)deviceString;
- (NSInteger)deviceMemoryForModel:(NSString *)deviceString;
- (NSDictionary *)webGLInfoForModel:(NSString *)deviceString;
- (NSString *)gpuFamilyForModel:(NSString *)deviceString;
- (NSInteger)cpuCoreCountForModel:(NSString *)deviceString;
- (NSString *)metalFeatureSetForModel:(NSString *)deviceString;
- (BOOL)supports5GForModel:(NSString *)deviceString;
- (NSArray<NSDictionary<NSString *, id> *> *)allDeviceSpecificationRecords;
- (NSString *)physicalDeviceModelIdentifier;
- (NSDictionary<NSString *, id> *)physicalDeviceSpecificationRecord;

// Board ID and Hardware Model
- (NSString *)boardIDForModel:(NSString *)deviceString;
- (NSString *)hwModelForModel:(NSString *)deviceString;

// Processor name (e.g., "Apple A11 Bionic")
- (NSString *)processorNameForModel:(NSString *)deviceString;

// CPU information dictionary
- (NSDictionary *)cpuInfoForModel:(NSString *)deviceString;

+ (instancetype)sharedManager;

// Validation
- (BOOL)isValidDeviceModel:(NSString *)deviceModel;

@end
