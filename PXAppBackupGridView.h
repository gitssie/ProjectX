#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface PXAppBackupGridView : UIStackView
- (instancetype)initWithApplications:(NSArray<NSDictionary *> *)applications
                          openHandler:(void (^)(NSDictionary *application))openHandler;
@end
NS_ASSUME_NONNULL_END
