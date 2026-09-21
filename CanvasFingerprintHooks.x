#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#import "AppIdentityHookSupport.h"
#import "ProjectXLogging.h"
#import "PXProcessHookPolicy.h"

static NSHashTable<WKWebView *> *PXLiveGraphicsWebViews = nil;

static NSString *PXGraphicsDisabledJavaScriptSource(void) {
    return @"(function(){const state=globalThis.__pxGraphicsIdentity_v1;"
            "if(state&&typeof state.disable==='function'){state.disable();}})();";
}

static NSString *PXGraphicsJavaScriptSource(NSString **generationID) {
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    if (generationID) {
        *generationID = identity.generationID;
    }
    return identity ? [identity javaScriptSource] : nil;
}

static BOOL PXAddGraphicsUserScript(WKUserContentController *controller,
                                    NSString **generationID) {
    NSString *source = PXGraphicsJavaScriptSource(generationID);
    if (!controller) {
        return NO;
    }
    NSMutableArray<NSString *> *existingSources = [NSMutableArray array];
    for (WKUserScript *script in controller.userScripts) {
        [existingSources addObject:script.source ?: @""];
    }
    if (source.length == 0) {
        BOOL hasProjectXScript = [existingSources indexOfObjectPassingTest:
            ^BOOL(NSString *existingSource, NSUInteger index, BOOL *stop) {
                (void)index;
                (void)stop;
                return [existingSource containsString:@"__pxGraphicsIdentity_v1"];
            }] != NSNotFound;
        if (!hasProjectXScript) {
            return NO;
        }
        source = PXGraphicsDisabledJavaScriptSource();
    }
    if (!PXGraphicsUserScriptsNeedCurrentSource(existingSources, source)) {
        return NO;
    }
    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:source
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO];
    [controller addUserScript:script];
    return YES;
}

static void PXEvaluateGraphicsScriptInWebView(WKWebView *webView) {
    NSString *source = PXGraphicsJavaScriptSource(NULL);
    if (!webView) {
        return;
    }
    if (source.length == 0) {
        source = PXGraphicsDisabledJavaScriptSource();
    }
    [webView evaluateJavaScript:source completionHandler:^(id result, NSError *error) {
        (void)result;
        if (error) {
            PXLog(@"[GraphicsIdentity] live injection failed domain=%@ code=%ld",
                  error.domain,
                  (long)error.code);
        }
    }];
}

static void PXReinjectGraphicsScriptInLiveWebViews(void) {
    NSMutableOrderedSet<WKWebView *> *webViews = [NSMutableOrderedSet orderedSet];
    @synchronized(PXLiveGraphicsWebViews) {
        [webViews addObjectsFromArray:PXLiveGraphicsWebViews.allObjects];
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *pendingViews = [NSMutableArray arrayWithObject:window];
            while (pendingViews.count > 0) {
                UIView *view = pendingViews.lastObject;
                [pendingViews removeLastObject];
                if ([view isKindOfClass:[WKWebView class]]) {
                    [webViews addObject:(WKWebView *)view];
                }
                [pendingViews addObjectsFromArray:view.subviews];
            }
        }
    }
    NSUInteger updatedConfigurationCount = 0;
    NSString *generationID = nil;
    for (WKWebView *webView in webViews) {
        NSString *webViewGenerationID = nil;
        if (PXAddGraphicsUserScript(webView.configuration.userContentController,
                                    &webViewGenerationID)) {
            updatedConfigurationCount++;
        }
        generationID = webViewGenerationID ?: generationID;
        PXEvaluateGraphicsScriptInWebView(webView);
    }
    PXLog(@"[GraphicsIdentity] profile refresh bundle=%@ generation=%@ liveWebViews=%lu updatedConfigurations=%lu",
          NSBundle.mainBundle.bundleIdentifier ?: @"<none>",
          generationID ?: @"<unavailable>",
          (unsigned long)webViews.count,
          (unsigned long)updatedConfigurationCount);
}

static void PXGraphicsProfileChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    PXInvalidateCurrentProcessGraphicsIdentity();
    dispatch_async(dispatch_get_main_queue(), ^{
        PXReinjectGraphicsScriptInLiveWebViews();
    });
}

%hook WKWebViewConfiguration

- (void)setUserContentController:(WKUserContentController *)userContentController {
    PXAddGraphicsUserScript(userContentController, NULL);
    %orig;
}

%end

%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    NSString *generationID = nil;
    BOOL added = PXAddGraphicsUserScript(configuration.userContentController, &generationID);
    WKWebView *webView = %orig;
    if (webView) {
        @synchronized(PXLiveGraphicsWebViews) {
            [PXLiveGraphicsWebViews addObject:webView];
        }
    }
    PXLog(@"[GraphicsIdentity] WKWebView configured bundle=%@ generation=%@ script=%@ frames=all",
          NSBundle.mainBundle.bundleIdentifier ?: @"<none>",
          generationID ?: @"<unavailable>",
          added ? @"added" : (generationID ? @"current" : @"inactive"));
    return webView;
}

%end

%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXLiveGraphicsWebViews = [NSHashTable weakObjectsHashTable];
        NSArray<NSString *> *names = @[
            @"com.hydra.projectx.profileChanged",
            @"com.hydra.projectx.settings.changed",
            @"com.hydra.projectx.toggleCanvasFingerprint",
            @"com.hydra.projectx.canvasFingerprintToggleChanged",
            @"com.hydra.projectx.enableCanvasFingerprintProtection",
            @"com.hydra.projectx.disableCanvasFingerprintProtection",
            @"com.hydra.projectx.resetCanvasNoise"
        ];
        for (NSString *name in names) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL,
                                            PXGraphicsProfileChanged,
                                            (__bridge CFStringRef)name,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        %init();
        PXLog(@"[GraphicsIdentity] hooks initialized process=%@ bundle=%@",
              NSProcessInfo.processInfo.processName,
              NSBundle.mainBundle.bundleIdentifier ?: @"<none>");
    }
}
