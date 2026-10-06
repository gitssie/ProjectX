#import <UIKit/UIKit.h>

@interface PXAppStateProgressViewController : UIViewController
- (instancetype)initWithOperation:(NSString *)operation name:(NSString *)name icon:(UIImage *)icon;
- (void)configureConfirmationWithTitle:(NSString *)title message:(NSString *)message
                          confirmTitle:(NSString *)confirmTitle fields:(NSArray<NSDictionary *> *)fields
                          discardTitle:(NSString *)discardTitle handler:(void (^)(NSDictionary *values,BOOL discardCurrent))handler;
- (void)configureAutomaticBackupOption;
- (void)beginProgressWithName:(NSString *)name;
- (void)configureChoicesWithTitle:(NSString *)title message:(NSString *)message choices:(NSArray<NSString *> *)choices handler:(void (^)(NSUInteger index))handler;
- (void)updateProgress:(NSDictionary *)event;
// Completion remains visible until dismissed by the owner; failure offers a close action.
- (void)finishWithError:(NSString *)message;
@property (nonatomic, copy) void (^closeHandler)(void);
@end
