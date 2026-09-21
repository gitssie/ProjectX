#import <Foundation/Foundation.h>

#import "PXAutomaticEnvironmentCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface PXProjectXEnvironmentOperations : NSObject <PXAutomaticEnvironmentOperations>

@property (nonatomic, copy) NSSet<NSString *> *targetBundleIdentifiers;

+ (instancetype)sharedOperations;
- (BOOL)isServiceReady;

@end

NS_ASSUME_NONNULL_END
