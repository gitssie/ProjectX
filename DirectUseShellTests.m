#import <UIKit/UIKit.h>
#import <assert.h>

#import "ProjectXViewController.h"
#import "TabBarController.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ProjectXViewController
@end
#pragma clang diagnostic pop

int main(void) {
    @autoreleasepool {
        TabBarController *shell = [[TabBarController alloc] init];
        [shell loadViewIfNeeded];

        assert(shell.viewControllers.count == 1);
        assert(shell.selectedIndex == 0);
        assert(shell.tabBar.hidden);
        assert(!shell.tabBar.userInteractionEnabled);
        assert(shell.tabBar.accessibilityElementsHidden);

        UIViewController *viewController = shell.viewControllers.firstObject;
        assert([viewController isKindOfClass:UINavigationController.class]);
        UINavigationController *navigationController = (UINavigationController *)viewController;
        assert([navigationController.topViewController isKindOfClass:ProjectXViewController.class]);
        assert(navigationController.viewControllers.count == 1);
        assert(navigationController.topViewController.navigationItem.leftBarButtonItem == nil);

        [shell showHomeForDeepLink];
        assert(shell.selectedViewController == navigationController);
        assert(navigationController.viewControllers.count == 1);
    }
    return 0;
}
