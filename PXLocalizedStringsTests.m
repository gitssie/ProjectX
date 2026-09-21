#import <Foundation/Foundation.h>

#include <assert.h>

#import "PXLocalizedStrings.h"

static void testModelCompatibilityReasonLocalization(void) {
    PXSetUILanguagePreference(PXUILanguagePreferenceEnglish);
    NSString *englishFields = [@[
        PXLocalizedString(@"image.model.incompatible.field.cpu"),
        PXLocalizedString(@"image.model.incompatible.field.display")
    ] componentsJoinedByString:@", "];
    NSString *englishReason = PXLocalizedFormat(
        @"image.model.incompatible.reason.immutable_hardware",
        englishFields);
    assert([englishReason containsString:@"CPU class"]);
    assert([englishReason containsString:@"display class"]);
    assert([englishReason containsString:@"same detected hardware signature"]);

    PXSetUILanguagePreference(PXUILanguagePreferenceSimplifiedChinese);
    NSString *chineseFields = [@[
        PXLocalizedString(@"image.model.incompatible.field.cpu"),
        PXLocalizedString(@"image.model.incompatible.field.display")
    ] componentsJoinedByString:@"、"];
    NSString *chineseReason = PXLocalizedFormat(
        @"image.model.incompatible.reason.immutable_hardware",
        chineseFields);
    assert([chineseReason containsString:@"CPU 类别"]);
    assert([chineseReason containsString:@"显示类别"]);
    assert([chineseReason containsString:@"与已检测硬件特征相同"]);
}

static void testKeychainProtectedGroupResultLocalization(void) {
    PXSetUILanguagePreference(PXUILanguagePreferenceEnglish);
    NSString *englishMessage = PXLocalizedFormat(
        @"image.home.cleanup.keychain.protected_groups_retained",
        2L);
    assert([englishMessage containsString:@"2"]);
    assert([englishMessage containsString:@"exclusive Keychain groups"]);
    assert([englishMessage containsString:@"retained"]);

    PXSetUILanguagePreference(PXUILanguagePreferenceSimplifiedChinese);
    NSString *chineseMessage = PXLocalizedFormat(
        @"image.home.cleanup.keychain.protected_groups_retained",
        2L);
    assert([chineseMessage containsString:@"2"]);
    assert([chineseMessage containsString:@"专属钥匙串组"]);
    assert([chineseMessage containsString:@"保留"]);
}

int main(void) {
    @autoreleasepool {
        __block NSInteger notificationCount = 0;
        __block BOOL notificationWasOnMainThread = NO;
        id observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:PXUILanguagePreferenceDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *notification) {
                        (void)notification;
                        notificationCount++;
                        notificationWasOnMainThread = NSThread.isMainThread;
                    }];

        PXSetUILanguagePreference(PXUILanguagePreferenceSimplifiedChinese);
        assert(PXCurrentUILanguagePreference() == PXUILanguagePreferenceSimplifiedChinese);
        assert([PXLocalizedString(@"image.settings.title") isEqualToString:@"设置"]);
        assert(notificationCount == 1);
        assert(notificationWasOnMainThread);

        PXSetUILanguagePreference(PXUILanguagePreferenceEnglish);
        assert(PXCurrentUILanguagePreference() == PXUILanguagePreferenceEnglish);
        assert([PXLocalizedString(@"image.settings.title") isEqualToString:@"Settings"]);
        assert([PXLocalizedString(@"language.option.simplified_chinese.title") isEqualToString:@"简体中文"]);
        assert(notificationCount == 2);

        PXSetUILanguagePreference(PXUILanguagePreferenceSystem);
        assert(PXCurrentUILanguagePreference() == PXUILanguagePreferenceSystem);
        assert(![PXLocalizedString(@"image.settings.title") isEqualToString:@"image.settings.title"]);
        assert(notificationCount == 3);

        PXSetUILanguagePreference((PXUILanguagePreference)99);
        assert(PXCurrentUILanguagePreference() == PXUILanguagePreferenceSystem);
        assert(notificationCount == 3);

        testModelCompatibilityReasonLocalization();
        testKeychainProtectedGroupResultLocalization();

        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
    return 0;
}
