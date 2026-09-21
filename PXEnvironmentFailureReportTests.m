#import <Foundation/Foundation.h>

#include <assert.h>

#import "PXEnvironmentFailureReport.h"
#import "PXLocalizedStrings.h"
#import "PXRootHidePath.h"

static NSString *PXDiagnosticsTestRoot;

static NSString *PXTestPath(NSString *logicalPath) {
    NSString *relativePath = [logicalPath substringFromIndex:1];
    return [PXDiagnosticsTestRoot stringByAppendingPathComponent:relativePath];
}

int main(void) {
    @autoreleasepool {
        PXDiagnosticsTestRoot = [NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        PXSetRootHidePathConvertersForTesting(PXTestPath, PXTestPath);
        PXSetUILanguagePreference(PXUILanguagePreferenceEnglish);

        PXEnvironmentFailureDiagnostic *diagnostic = [[PXEnvironmentFailureDiagnostic alloc]
            initWithStage:@"Activate environment"
                   target:@"com.example.target"
                  message:@"Validation failed at /private/var/mobile/profile.plist token=top-secret-value identifier 0123456789abcdef0123456789abcdef user@example.com 192.168.1.22"
              errorDomain:@"com.hydra.projectx.profile-manifest"
                errorCode:3];
        NSMutableArray<PXEnvironmentFailureDiagnostic *> *diagnostics = [NSMutableArray array];
        for (NSUInteger index = 0; index < 12; index++) {
            [diagnostics addObject:diagnostic];
        }
        PXEnvironmentFailureReport *report = [[PXEnvironmentFailureReport alloc]
            initWithSummary:@"The environment could not be completed."
                 diagnostics:diagnostics
                   timestamp:[NSDate dateWithTimeIntervalSince1970:1700000000]
                   reference:@"PX-test-reference"];

        assert(report.diagnostics.count == 8);
        NSString *redacted = [report redactedTextRepresentation];
        assert([redacted containsString:@"com.example.target"]);
        assert([redacted containsString:@"com.hydra.projectx.profile-manifest"]);
        assert([redacted containsString:@"(3)"]);
        assert([redacted rangeOfString:@"top-secret-value"].location == NSNotFound);
        assert([redacted rangeOfString:@"/private/var/mobile/profile.plist"].location == NSNotFound);
        assert([redacted rangeOfString:@"0123456789abcdef0123456789abcdef"].location == NSNotFound);
        assert([redacted rangeOfString:@"user@example.com"].location == NSNotFound);
        assert([redacted rangeOfString:@"192.168.1.22"].location == NSNotFound);

        NSError *persistenceError = nil;
        assert([report persistAsLastReportWithError:&persistenceError]);
        assert(persistenceError == nil);
        PXEnvironmentFailureReport *restored = [PXEnvironmentFailureReport
            lastPersistedReportWithError:&persistenceError];
        assert(restored != nil);
        assert(persistenceError == nil);
        assert([restored.reference isEqualToString:report.reference]);
        assert(restored.diagnostics.count == 8);
        assert([restored.diagnostics.firstObject.errorDomain
            isEqualToString:@"com.hydra.projectx.profile-manifest"]);
        assert(restored.diagnostics.firstObject.errorCode == 3);
        assert([restored.redactedTextRepresentation rangeOfString:@"top-secret-value"].location == NSNotFound);

        assert([PXEnvironmentFailureReport clearLastPersistedReportWithError:&persistenceError]);
        assert([PXEnvironmentFailureReport lastPersistedReportWithError:&persistenceError] == nil);
        assert(persistenceError == nil);
        assert([[NSFileManager defaultManager] removeItemAtPath:PXDiagnosticsTestRoot error:nil]);
    }
    return 0;
}
