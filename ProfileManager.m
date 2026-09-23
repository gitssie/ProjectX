#import "ProfileManager.h"
#import "PXRootHidePath.h"

@implementation ProfileManager

+ (instancetype)sharedManager {
    static ProfileManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        PXProfileUpdateContentsAtPath(PXCurrentProfileInfoPath(), ^(NSMutableDictionary *contents) {
            contents[@"ProfileName"] = @"ProjectX";
        });
    }
    return self;
}

@end
