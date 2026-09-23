#import <UIKit/UIKit.h>

// Keep an icon-only exit action available for the whole search presentation,
// including after the keyboard has been dismissed.
static inline UIButton *PXInstallSearchExitButton(UISearchController *searchController,
                                                  id target,
                                                  SEL action) {
    UISearchBar *searchBar = searchController.searchBar;
    UISearchTextField *searchField = searchBar.searchTextField;
    searchField.clearButtonMode = UITextFieldViewModeNever;
    searchField.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 1)];
    searchField.rightViewMode = UITextFieldViewModeAlways;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    button.tintColor = UIColor.secondaryLabelColor;
    button.hidden = YES;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [searchBar addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:searchBar.trailingAnchor constant:-8],
        [button.centerYAnchor constraintEqualToAnchor:searchBar.centerYAnchor],
        [button.widthAnchor constraintEqualToConstant:44],
        [button.heightAnchor constraintEqualToConstant:44]
    ]];
    return button;
}
