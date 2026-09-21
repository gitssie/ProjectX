#import "PXProcessKeychainSecurityAdapter.h"

#import <Security/Security.h>

#include <dlfcn.h>

typedef CFTypeRef (*PXSecTaskCreateFromSelfFunction)(CFAllocatorRef allocator);
typedef CFTypeRef (*PXSecTaskCopyValueForEntitlementFunction)(CFTypeRef task,
                                                              CFStringRef entitlement,
                                                              CFErrorRef *error);

@interface PXProcessKeychainSecurityAdapter ()

@property (nonatomic, copy) NSString *expectedBundleIdentifier;

@end


@implementation PXProcessKeychainSecurityAdapter

- (instancetype)initWithExpectedBundleIdentifier:(NSString *)expectedBundleIdentifier {
    self = [super init];
    if (self) {
        NSParameterAssert(expectedBundleIdentifier.length > 0);
        _expectedBundleIdentifier = [expectedBundleIdentifier copy];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)entitlementsForBundleIdentifier:(NSString *)bundleIdentifier
                                                             error:(NSError * _Nullable * _Nullable)error {
    if (![bundleIdentifier isEqualToString:self.expectedBundleIdentifier]) {
        if (error) {
            *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Entitlement target does not match current process authority"}];
        }
        return nil;
    }
    PXSecTaskCreateFromSelfFunction createTask = (PXSecTaskCreateFromSelfFunction)
        dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    PXSecTaskCopyValueForEntitlementFunction copyEntitlement =
        (PXSecTaskCopyValueForEntitlementFunction)
        dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!createTask || !copyEntitlement) {
        if (error) {
            *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Security entitlement APIs are unavailable"}];
        }
        return nil;
    }
    CFTypeRef task = createTask(kCFAllocatorDefault);
    if (!task) {
        if (error) {
            *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Unable to inspect current process entitlements"}];
        }
        return nil;
    }
    NSMutableDictionary<NSString *, id> *entitlements = [NSMutableDictionary dictionary];
    for (NSString *key in @[
        @"application-identifier",
        @"com.apple.application-identifier",
        @"keychain-access-groups"
    ]) {
        CFTypeRef value = copyEntitlement(task, (__bridge CFStringRef)key, NULL);
        if (value) {
            entitlements[key] = CFBridgingRelease(value);
        }
    }
    CFRelease(task);
    if (entitlements.count == 0 && error) {
        *error = [NSError errorWithDomain:PXKeychainCommandErrorDomain
                                     code:4
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     @"Current process has no readable Keychain entitlements"}];
    }
    return entitlements.count > 0 ? [entitlements copy] : nil;
}

- (id)securityClassForName:(NSString *)keychainClass {
    if ([keychainClass isEqualToString:PXKeychainClassGenericPassword]) {
        return (__bridge id)kSecClassGenericPassword;
    }
    if ([keychainClass isEqualToString:PXKeychainClassInternetPassword]) {
        return (__bridge id)kSecClassInternetPassword;
    }
    if ([keychainClass isEqualToString:PXKeychainClassCertificate]) {
        return (__bridge id)kSecClassCertificate;
    }
    if ([keychainClass isEqualToString:PXKeychainClassKey]) {
        return (__bridge id)kSecClassKey;
    }
    if ([keychainClass isEqualToString:PXKeychainClassIdentity]) {
        return (__bridge id)kSecClassIdentity;
    }
    return nil;
}

- (NSUInteger)countItemsForClass:(NSString *)keychainClass
                     accessGroup:(NSString *)accessGroup
                  synchronizable:(BOOL)synchronizable
                          status:(int32_t *)status {
    id securityClass = [self securityClassForName:keychainClass];
    if (!securityClass || accessGroup.length == 0) {
        if (status) *status = errSecParam;
        return 0;
    }
    NSDictionary *query = @{
        (__bridge id)kSecClass: securityClass,
        (__bridge id)kSecAttrAccessGroup: accessGroup,
        (__bridge id)kSecAttrSynchronizable: synchronizable ? @YES : @NO,
        (__bridge id)kSecReturnPersistentRef: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
    };
    CFTypeRef result = NULL;
    OSStatus queryStatus = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status) *status = (int32_t)queryStatus;
    if (queryStatus != errSecSuccess || !result) {
        if (result) CFRelease(result);
        return 0;
    }
    id bridgedResult = CFBridgingRelease(result);
    return [bridgedResult isKindOfClass:[NSArray class]] ? [bridgedResult count] : 1;
}

- (int32_t)deleteItemsForClass:(NSString *)keychainClass
                   accessGroup:(NSString *)accessGroup
                synchronizable:(BOOL)synchronizable {
    id securityClass = [self securityClassForName:keychainClass];
    if (!securityClass || accessGroup.length == 0) {
        return errSecParam;
    }
    NSDictionary *query = @{
        (__bridge id)kSecClass: securityClass,
        (__bridge id)kSecAttrAccessGroup: accessGroup,
        (__bridge id)kSecAttrSynchronizable: synchronizable ? @YES : @NO
    };
    return (int32_t)SecItemDelete((__bridge CFDictionaryRef)query);
}

@end
