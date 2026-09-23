#import <Foundation/Foundation.h>
#import <Security/Security.h>

#import "AppIdentity.h"
#import "IdentifierManager.h"
#import "KeychainCommand.h"
#import "ProfileManifest.h"
#import "PXProcessKeychainSecurityAdapter.h"
#import "PXRootHidePath.h"

static PXKeychainCommandContext *PXKeychainCurrentCommandContext(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (bundleIdentifier.length == 0 ||
        !PXProfileReadContentsAtPath(PXCurrentProfileInfoPath())) {
        return nil;
    }
    NSString *identityDirectory = PXCurrentProfileIdentityValuesPath();
    PXProfileManifest *manifest = [[[PXProfileStore alloc]
        initWithIdentityDirectory:identityDirectory] activeManifestWithError:nil];
    if (!manifest ||
        ![[NSUUID alloc] initWithUUIDString:manifest.generationID]) {
        return nil;
    }
    IdentifierManager *manager = [IdentifierManager sharedManager];
    [manager reloadApplicationScope];
    return [[PXKeychainCommandContext alloc]
        initWithBundleIdentifier:bundleIdentifier
                    generationID:manifest.generationID.lowercaseString
              applicationEnabled:[manager isApplicationEnabled:bundleIdentifier]
                extensionEnabled:[manager isExtensionEnabled:bundleIdentifier]];
}

static PXKeychainCommandFileStore *PXTargetKeychainFileStore(void) {
    static PXKeychainCommandFileStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[PXKeychainCommandFileStore alloc]
            initWithRootDirectory:PXKeychainCommandDefaultRootDirectory()];
    });
    return store;
}

static dispatch_queue_t PXTargetKeychainCommandQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.hydra.projectx.target-keychain", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void PXProcessPendingKeychainRequests(void) {
    @autoreleasepool {
        PXKeychainCommandFileStore *store = PXTargetKeychainFileStore();
        NSString *currentBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        NSArray<NSDictionary<NSString *, NSString *> *> *rejectedHeaders =
            [store rejectedRequestHeadersWithError:nil];
        for (NSDictionary<NSString *, NSString *> *header in rejectedHeaders) {
            if (![header[@"targetBundleID"] isEqualToString:currentBundleIdentifier]) {
                continue;
            }
            NSString *requestID = header[@"requestID"];
            NSString *failureCode = @"invalid-request";
            if (![store claimRequestID:requestID error:nil]) {
                if (![store isRequestIDCompleted:requestID]) {
                    continue;
                }
                failureCode = @"replayed";
            }
            PXKeychainCommandResponse *response = [PXKeychainCommandResponse
                failureResponseForRequestID:requestID
                targetBundleID:currentBundleIdentifier
                code:failureCode];
            if ([store writeResponse:response error:nil] &&
                [store markRequestIDCompleted:requestID error:nil]) {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                     (__bridge CFStringRef)PXKeychainCommandResponseNotification,
                                                     NULL,
                                                     NULL,
                                                     YES);
            }
        }
        NSArray<PXKeychainCommandRequest *> *requests = [store pendingRequestsWithError:nil];
        for (PXKeychainCommandRequest *request in requests) {
            if (![request.targetBundleID isEqualToString:currentBundleIdentifier]) {
                continue;
            }
            if (![store claimRequestID:request.requestID error:nil]) {
                if ([store isRequestIDCompleted:request.requestID]) {
                    PXKeychainCommandResponse *replayResponse =
                        [PXKeychainCommandResponse failureResponseForRequest:request code:@"replayed"];
                    if ([store writeResponse:replayResponse error:nil]) {
                        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                             (__bridge CFStringRef)PXKeychainCommandResponseNotification,
                                                             NULL,
                                                             NULL,
                                                             YES);
                    }
                }
                continue;
            }
            PXKeychainCommandContext *context = PXKeychainCurrentCommandContext();
            PXKeychainCommandResponse *response = nil;
            if (context) {
                PXKeychainCommandExecutor *executor = [[PXKeychainCommandExecutor alloc]
                    initWithValidator:[[PXKeychainCommandValidator alloc] init]
                    securityAdapter:[[PXProcessKeychainSecurityAdapter alloc]
                        initWithExpectedBundleIdentifier:currentBundleIdentifier]];
                response = [executor executeRequest:request context:context now:[NSDate date] error:nil];
            }
            if (!response) {
                response = [PXKeychainCommandResponse failureResponseForRequest:request
                                                                           code:@"rejected"];
            }
            if ([store writeResponse:response error:nil] &&
                [store markRequestIDCompleted:request.requestID error:nil]) {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                     (__bridge CFStringRef)PXKeychainCommandResponseNotification,
                                                     NULL,
                                                     NULL,
                                                     YES);
            } else {
                [store removeTransactionForRequestID:request.requestID];
            }
        }
    }
}

static void PXPublishTargetKeychainReadiness(void) {
    PXKeychainCommandContext *context = PXKeychainCurrentCommandContext();
    if (!context || (!context.isApplicationEnabled && !context.isExtensionEnabled) ||
        ![PXTargetKeychainFileStore()
        writeReadinessForBundleIdentifier:context.bundleIdentifier
        generationID:context.generationID
        now:[NSDate date]
        error:nil]) {
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)PXKeychainCommandReadyNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

static void PXKeychainRequestNotificationCallback(CFNotificationCenterRef center,
                                                   void *observer,
                                                   CFStringRef name,
                                                   const void *object,
                                                   CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(PXTargetKeychainCommandQueue(), ^{
        PXProcessPendingKeychainRequests();
    });
}

static void PXKeychainProbeNotificationCallback(CFNotificationCenterRef center,
                                                 void *observer,
                                                 CFStringRef name,
                                                 const void *object,
                                                 CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(PXTargetKeychainCommandQueue(), ^{
        PXPublishTargetKeychainReadiness();
    });
}

%ctor {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (!PXKeychainCommandReceiverShouldRegisterForBundleIdentifier(bundleIdentifier)) {
            return;
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        PXKeychainRequestNotificationCallback,
                                        (__bridge CFStringRef)PXKeychainCommandRequestNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        PXKeychainProbeNotificationCallback,
                                        (__bridge CFStringRef)PXKeychainCommandProbeNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        PXPublishTargetKeychainReadiness();
        dispatch_async(PXTargetKeychainCommandQueue(), ^{
            PXProcessPendingKeychainRequests();
        });
    }
}
