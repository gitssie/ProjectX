#import <Foundation/Foundation.h>

#import "PXTargetSelectionReconciler.h"

NS_ASSUME_NONNULL_BEGIN

@interface PXTargetSelectionServices : NSObject

@property (nonatomic, strong, readonly) id<PXInstalledAppSnapshotProviding> snapshotProvider;
@property (nonatomic, strong, readonly) PXTargetSelectionReconciler *reconciler;

+ (instancetype)sharedServices;
- (instancetype)init NS_UNAVAILABLE;

@end


NS_ASSUME_NONNULL_END
