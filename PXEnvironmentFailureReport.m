#import "PXEnvironmentFailureReport.h"

#import "ProjectXLogging.h"
#import "PXLocalizedStrings.h"
#import "PXRootHidePath.h"

static NSString *const PXEnvironmentFailureReportErrorDomain = @"com.hydra.projectx.environment-failure-report";
static NSString *const PXEnvironmentFailureReportFileName = @"com.hydra.projectx.last-environment-failure.plist";
static const NSUInteger PXMaximumPersistedDiagnostics = 8;

static NSString *PXBoundedDiagnosticString(NSString *value, NSUInteger maximumLength) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"";
    }
    NSString *bounded = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *patterns = @[
        @"(?i)(authorization|bearer|token|password|secret|private[ _-]?key|api[ _-]?key)(\\s*[:=]?\\s*)[^\\s|]+",
        @"(?i)(serial|imei|meid|idfa|idfv|uuid)(\\s*[:=]?\\s*)[A-Za-z0-9-]+",
        @"(?:file://)?/(?:[^\\s|]+)",
        @"\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}\\b",
        @"\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b",
        @"\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b",
        @"\\b[0-9]{10,15}\\b",
        @"\\b[0-9A-Fa-f]{24,}\\b",
        @"\\b[A-Za-z0-9+/]{32,}={0,2}\\b"
    ];
    NSArray<NSString *> *templates = @[
        @"$1$2[redacted]",
        @"$1$2[redacted]",
        @"[path redacted]",
        @"[identifier redacted]",
        @"[email redacted]",
        @"[network address redacted]",
        @"[identifier redacted]",
        @"[identifier redacted]",
        @"[value redacted]"
    ];
    for (NSUInteger index = 0; index < patterns.count; index++) {
        NSError *expressionError = nil;
        NSRegularExpression *expression = [NSRegularExpression
            regularExpressionWithPattern:patterns[index]
                                 options:0
                                   error:&expressionError];
        if (!expression) {
            PXLog(@"[environment-diagnostics] Redaction expression failed: %@",
                  expressionError.localizedDescription);
            continue;
        }
        bounded = [expression stringByReplacingMatchesInString:bounded
                                                        options:0
                                                          range:NSMakeRange(0, bounded.length)
                                                   withTemplate:templates[index]];
    }
    if (bounded.length > maximumLength) {
        bounded = [[bounded substringToIndex:maximumLength] stringByAppendingString:@"…"];
    }
    return bounded;
}

static NSString *PXValidatedTargetBundleIdentifier(NSString *target) {
    NSString *candidate = PXBoundedDiagnosticString(target, 255);
    if (candidate.length == 0) {
        return nil;
    }
    NSError *expressionError = nil;
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"
                             options:0
                               error:&expressionError];
    if (!expression) {
        PXLog(@"[environment-diagnostics] Target validation expression failed: %@",
              expressionError.localizedDescription);
        return nil;
    }
    NSRange fullRange = NSMakeRange(0, candidate.length);
    return [expression firstMatchInString:candidate options:0 range:fullRange] ? candidate : nil;
}

static NSError *PXFailureReportError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:PXEnvironmentFailureReportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@interface PXEnvironmentFailureDiagnostic ()
@property (nonatomic, copy, readwrite) NSString *stage;
@property (nonatomic, copy, readwrite, nullable) NSString *target;
@property (nonatomic, copy, readwrite) NSString *message;
@property (nonatomic, copy, readwrite) NSString *errorDomain;
@property (nonatomic, assign, readwrite) NSInteger errorCode;
@end

@implementation PXEnvironmentFailureDiagnostic

- (instancetype)initWithStage:(NSString *)stage
                        target:(NSString *)target
                       message:(NSString *)message {
    return [self initWithStage:stage
                       target:target
                      message:message
                  errorDomain:@"com.hydra.projectx.environment"
                    errorCode:0];
}

- (instancetype)initWithStage:(NSString *)stage
                        target:(NSString *)target
                       message:(NSString *)message
                   errorDomain:(NSString *)errorDomain
                     errorCode:(NSInteger)errorCode {
    self = [super init];
    if (self) {
        _stage = [PXBoundedDiagnosticString(stage, 128) copy];
        _target = [PXValidatedTargetBundleIdentifier(target) copy];
        _message = [PXBoundedDiagnosticString(message, 768) copy];
        NSString *safeDomain = PXBoundedDiagnosticString(errorDomain, 128);
        _errorDomain = safeDomain.length > 0 ? [safeDomain copy] : @"com.hydra.projectx.unknown";
        _errorCode = errorCode;
    }
    return self;
}

@end


@interface PXEnvironmentFailureReport ()
@property (nonatomic, copy, readwrite) NSString *summary;
@property (nonatomic, copy, readwrite) NSArray<PXEnvironmentFailureDiagnostic *> *diagnostics;
@property (nonatomic, strong, readwrite) NSDate *timestamp;
@property (nonatomic, copy, readwrite) NSString *reference;
@end

@implementation PXEnvironmentFailureReport

- (instancetype)initWithSummary:(NSString *)summary
                     diagnostics:(NSArray<PXEnvironmentFailureDiagnostic *> *)diagnostics
                       timestamp:(NSDate *)timestamp
                       reference:(NSString *)reference {
    self = [super init];
    if (self) {
        _summary = [PXBoundedDiagnosticString(summary, 512) copy];
        NSUInteger count = MIN(diagnostics.count, PXMaximumPersistedDiagnostics);
        _diagnostics = count > 0
            ? [[diagnostics subarrayWithRange:NSMakeRange(0, count)] copy]
            : @[];
        _timestamp = [timestamp isKindOfClass:[NSDate class]] ? timestamp : [NSDate date];
        _reference = [PXBoundedDiagnosticString(reference, 64) copy];
    }
    return self;
}

- (NSString *)localizedTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    return [formatter stringFromDate:self.timestamp];
}

- (NSString *)redactedTextRepresentation {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        PXLocalizedString(@"diagnostics.copy.heading"),
        PXLocalizedFormat(@"diagnostics.copy.reference", self.reference),
        PXLocalizedFormat(@"diagnostics.copy.timestamp", [self localizedTimestamp]),
        PXLocalizedFormat(@"diagnostics.copy.summary", self.summary)
    ]];
    for (PXEnvironmentFailureDiagnostic *diagnostic in self.diagnostics) {
        [lines addObject:PXLocalizedFormat(@"diagnostics.copy.item",
            diagnostic.stage,
            diagnostic.target ?: PXLocalizedString(@"diagnostics.target.none"),
            diagnostic.message)];
        [lines addObject:PXLocalizedFormat(@"diagnostics.copy.error",
            diagnostic.errorDomain,
            (long)diagnostic.errorCode)];
    }
    [lines addObject:PXLocalizedString(@"diagnostics.copy.redaction_note")];
    return PXBoundedDiagnosticString([lines componentsJoinedByString:@"\n"], 8192);
}

- (NSDictionary<NSString *, id> *)persistedPropertyList {
    NSMutableArray<NSDictionary<NSString *, id> *> *diagnostics = [NSMutableArray array];
    for (PXEnvironmentFailureDiagnostic *diagnostic in self.diagnostics) {
        [diagnostics addObject:@{
            @"stage": diagnostic.stage,
            @"target": diagnostic.target ?: @"",
            @"message": diagnostic.message,
            @"errorDomain": diagnostic.errorDomain,
            @"errorCode": @(diagnostic.errorCode)
        }];
    }
    return @{
        @"schemaVersion": @1,
        @"summary": self.summary,
        @"diagnostics": [diagnostics copy],
        @"timestamp": self.timestamp,
        @"reference": self.reference
    };
}

- (BOOL)persistAsLastReportWithError:(NSError **)error {
    NSString *filePath = PXPreferencesFilePath(PXEnvironmentFailureReportFileName);
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager]
        createDirectoryAtPath:filePath.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions: @0700}
                        error:&directoryError]) {
        if (error) {
            *error = directoryError;
        }
        return NO;
    }
    if (![[self persistedPropertyList] writeToFile:filePath atomically:YES]) {
        if (error) {
            *error = PXFailureReportError(1, @"The last environment diagnostic could not be saved");
        }
        return NO;
    }
    NSError *permissionsError = nil;
    if (![[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions: @0600}
         ofItemAtPath:filePath
                error:&permissionsError]) {
        if (error) {
            *error = permissionsError;
        }
        return NO;
    }
    PXLog(@"[environment-diagnostics] %@", [self redactedTextRepresentation]);
    return YES;
}

+ (instancetype)lastPersistedReportWithError:(NSError **)error {
    NSString *filePath = PXPreferencesFilePath(PXEnvironmentFailureReportFileName);
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return nil;
    }
    NSDictionary<NSString *, id> *propertyList = [NSDictionary dictionaryWithContentsOfFile:filePath];
    NSArray *storedDiagnostics = [propertyList[@"diagnostics"] isKindOfClass:[NSArray class]]
        ? propertyList[@"diagnostics"]
        : nil;
    NSString *summary = [propertyList[@"summary"] isKindOfClass:[NSString class]]
        ? propertyList[@"summary"]
        : nil;
    NSDate *timestamp = [propertyList[@"timestamp"] isKindOfClass:[NSDate class]]
        ? propertyList[@"timestamp"]
        : nil;
    NSString *reference = [propertyList[@"reference"] isKindOfClass:[NSString class]]
        ? propertyList[@"reference"]
        : nil;
    if ([propertyList[@"schemaVersion"] integerValue] != 1 || !storedDiagnostics ||
        summary.length == 0 || !timestamp || reference.length == 0) {
        if (error) {
            *error = PXFailureReportError(2, @"The saved environment diagnostic is invalid");
        }
        return nil;
    }
    NSMutableArray<PXEnvironmentFailureDiagnostic *> *diagnostics = [NSMutableArray array];
    for (id storedValue in storedDiagnostics) {
        if (![storedValue isKindOfClass:[NSDictionary class]] ||
            diagnostics.count >= PXMaximumPersistedDiagnostics) {
            continue;
        }
        NSDictionary<NSString *, id> *storedDiagnostic = storedValue;
        NSString *stage = [storedDiagnostic[@"stage"] isKindOfClass:[NSString class]]
            ? storedDiagnostic[@"stage"] : @"";
        NSString *target = [storedDiagnostic[@"target"] isKindOfClass:[NSString class]]
            ? storedDiagnostic[@"target"] : nil;
        NSString *message = [storedDiagnostic[@"message"] isKindOfClass:[NSString class]]
            ? storedDiagnostic[@"message"] : @"";
        NSString *domain = [storedDiagnostic[@"errorDomain"] isKindOfClass:[NSString class]]
            ? storedDiagnostic[@"errorDomain"] : @"com.hydra.projectx.unknown";
        NSInteger code = [storedDiagnostic[@"errorCode"] integerValue];
        if (stage.length == 0 || message.length == 0) {
            continue;
        }
        [diagnostics addObject:[[PXEnvironmentFailureDiagnostic alloc]
            initWithStage:stage
                   target:target
                  message:message
              errorDomain:domain
                errorCode:code]];
    }
    if (diagnostics.count == 0) {
        if (error) {
            *error = PXFailureReportError(2, @"The saved environment diagnostic has no valid failures");
        }
        return nil;
    }
    return [[self alloc] initWithSummary:summary
                            diagnostics:diagnostics
                              timestamp:timestamp
                              reference:reference];
}

+ (BOOL)clearLastPersistedReportWithError:(NSError **)error {
    NSString *filePath = PXPreferencesFilePath(PXEnvironmentFailureReportFileName);
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return YES;
    }
    return [[NSFileManager defaultManager] removeItemAtPath:filePath error:error];
}

@end
