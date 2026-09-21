#import <Foundation/Foundation.h>

#import "KeychainCommand.h"

NS_ASSUME_NONNULL_BEGIN

@interface PXProcessKeychainSecurityAdapter : NSObject <PXKeychainSecurityAdapter>

- (instancetype)initWithExpectedBundleIdentifier:(NSString *)expectedBundleIdentifier;

@end

NS_ASSUME_NONNULL_END
