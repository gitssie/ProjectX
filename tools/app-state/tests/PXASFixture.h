#import "../core/PXAppState.h"

@interface PXASFixture : NSObject <PXASResolver, PXASKeychain, PXASIdentity>
@property (nonatomic, copy) NSDictionary *target;
@property (nonatomic, copy) NSArray *records;
@property (nonatomic, copy) NSDictionary *identityState;
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL failAfterKeychainClear;
@property (nonatomic) BOOL failIdentityOnce;
@property (nonatomic) NSUInteger replacementCount;
@property (nonatomic) BOOL failExportOnce;
@property (nonatomic, copy) void (^exportHook)(void);
@end
