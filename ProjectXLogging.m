#import "ProjectXLogging.h"
#import "PXRootHidePath.h"
#import <Foundation/Foundation.h>
#import <os/log.h>

// Global logging function
void PXLog(NSString *format, ...) {
    static NSDateFormatter *dateFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    });
    
    @try {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        // Get timestamp
        NSString *timestamp = nil;
        @synchronized (dateFormatter) {
            timestamp = [dateFormatter stringFromDate:[NSDate date]];
        }
        
        // Create formatted log with timestamp
        NSString *logMessage = [NSString stringWithFormat:@"[ProjectX %@] %@", timestamp, message];
        
        // Determine log file path
        NSString *logFilePath = nil;
        
        NSString *logsDirectory = PXJBRootPath(@"/var/mobile/Library/Logs/ProjectX");
        NSError *directoryError = nil;
        if ([[NSFileManager defaultManager]
            createDirectoryAtPath:logsDirectory
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0700}
                            error:&directoryError]) {
            logFilePath = [logsDirectory stringByAppendingPathComponent:@"ProjectX.log"];
        }
        
        // Fallback to temp directory if no log paths found
        if (!logFilePath) {
            logFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ProjectX.log"];
            
            // Attempt to create a logs directory in a location we have access to
            NSString *fallbackPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ProjectXLogs"];
            NSError *fallbackError = nil;
            if ([[NSFileManager defaultManager]
                createDirectoryAtPath:fallbackPath
          withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions: @0700}
                                error:&fallbackError]) {
                logFilePath = [fallbackPath stringByAppendingPathComponent:@"ProjectX.log"];
            } else {
                os_log_error(OS_LOG_DEFAULT,
                             "ProjectX log directory creation failed: %{public}@; fallback failed: %{public}@",
                             directoryError.localizedDescription,
                             fallbackError.localizedDescription);
            }
        }
        
        // Write to file
        if (logFilePath) {
            @try {
                NSFileHandle *fileHandle = nil;
                
                // Create file if it doesn't exist
                if (![[NSFileManager defaultManager] fileExistsAtPath:logFilePath]) {
                    NSError *writeError = nil;
                    if (![[logMessage stringByAppendingString:@"\n"] writeToFile:logFilePath
                                                                         atomically:YES
                                                                           encoding:NSUTF8StringEncoding
                                                                              error:&writeError]) {
                        os_log_error(OS_LOG_DEFAULT,
                                     "ProjectX log write failed: %{public}@",
                                     writeError.localizedDescription);
                    }
                } else {
                    // Append to existing file
                    fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
                    if (fileHandle) {
                        [fileHandle seekToEndOfFile];
                        [fileHandle writeData:[[logMessage stringByAppendingString:@"\n"]
                                              dataUsingEncoding:NSUTF8StringEncoding]];
                        [fileHandle closeFile];
                    } else {
                        os_log_error(OS_LOG_DEFAULT,
                                     "ProjectX log file could not be opened for writing");
                    }
                }
            } @catch (NSException *e) {
                os_log_error(OS_LOG_DEFAULT,
                             "ProjectX log write exception: %{public}@",
                             e.reason);
            }
        }
        
        // Modern logging via os_log if available (iOS 10+)
        if (@available(iOS 10.0, *)) {
            os_log_t logObject = os_log_create("com.hydra.projectx", "general");
            os_log_with_type(logObject, OS_LOG_TYPE_DEFAULT, "%{public}@", message);
        }
        
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT,
                     "ProjectX logging exception: %{public}@",
                     exception.reason);
    }
}

// Error recovery helper
void PXLogError(NSError *error, NSString *context) {
    if (!error) {
        return;
    }
    
    PXLog(@"[%@] Error %ld: %@", context, (long)error.code, error.localizedDescription);
    
    // Attempt recovery based on error
    switch (error.code) {
        case 4001: // Settings save error
            [[NSUserDefaults standardUserDefaults] synchronize];
            break;
            
        case 3001: // Invalid bundle ID
        case 3002: // App not found
            break;
            
        default:
            if ([error.domain isEqualToString:NSCocoaErrorDomain]) {
                // Check permissions silently
            }
            break;
    }
} 
