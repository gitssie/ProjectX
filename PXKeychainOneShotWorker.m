#import "PXRootHidePath.h"
#import <Foundation/Foundation.h>

#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#import "KeychainCommand.h"
#import "PXProcessKeychainSecurityAdapter.h"

static int PXKeychainWorkerFail(int exitCode, NSError *error, NSString *fallbackReason) {
    NSString *reason = error.localizedDescription ?: fallbackReason;
    if (reason.length > 0) {
        fputs(reason.UTF8String, stderr);
        fputc('\n', stderr);
    }
    return exitCode;
}

static BOOL PXKeychainWorkerPathsAreSafe(NSString *workerPath,
                                         NSString *requestPath,
                                         NSString *responsePath) {
    if (!workerPath.isAbsolutePath || !requestPath.isAbsolutePath || !responsePath.isAbsolutePath ||
        ![workerPath.lastPathComponent isEqualToString:@"worker"] ||
        ![requestPath.lastPathComponent isEqualToString:@"request.plist"] ||
        ![responsePath.lastPathComponent isEqualToString:@"response.plist"] ||
        ![workerPath.stringByDeletingLastPathComponent
            isEqualToString:requestPath.stringByDeletingLastPathComponent] ||
        ![requestPath.stringByDeletingLastPathComponent
            isEqualToString:responsePath.stringByDeletingLastPathComponent]) {
        return NO;
    }
    NSString *operationDirectory = requestPath.stringByDeletingLastPathComponent;
    struct stat directoryInfo;
    struct stat workerInfo;
    struct stat requestInfo;
    if (lstat(operationDirectory.fileSystemRepresentation, &directoryInfo) != 0 ||
        !S_ISDIR(directoryInfo.st_mode) || S_ISLNK(directoryInfo.st_mode) ||
        (directoryInfo.st_mode & 077) != 0 ||
        directoryInfo.st_uid != geteuid() ||
        lstat(workerPath.fileSystemRepresentation, &workerInfo) != 0 ||
        !S_ISREG(workerInfo.st_mode) || S_ISLNK(workerInfo.st_mode) ||
        lstat(requestPath.fileSystemRepresentation, &requestInfo) != 0 ||
        !S_ISREG(requestInfo.st_mode) || S_ISLNK(requestInfo.st_mode) ||
        (requestInfo.st_mode & 077) != 0 || requestInfo.st_uid != geteuid()) {
        return NO;
    }
    struct stat responseInfo;
    return lstat(responsePath.fileSystemRepresentation, &responseInfo) != 0 && errno == ENOENT;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            return 64;
        }
        NSString *workerPath = [NSString stringWithUTF8String:argv[0]];
        NSString *requestPath = [NSString stringWithUTF8String:argv[1]];
        NSString *responsePath = [NSString stringWithUTF8String:argv[2]];
        if (!PXKeychainWorkerPathsAreSafe(workerPath, requestPath, responsePath)) {
            return 65;
        }
        NSDictionary<NSString *, id> *requestPropertyList =
            PXProfileReadDictionary(requestPath);
        NSError *requestError = nil;
        PXKeychainCommandRequest *request = [PXKeychainCommandRequest
            requestWithPropertyList:requestPropertyList
            error:&requestError];
        if (!request || request.includesSynchronizableItems ||
            ![request.requestID isEqualToString:
                requestPath.stringByDeletingLastPathComponent.lastPathComponent.lowercaseString]) {
            return PXKeychainWorkerFail(66, requestError, @"One-shot Keychain request is invalid");
        }
        NSString *entitlementsPath = [requestPath.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"entitlements.plist"];
        if (unlink(workerPath.fileSystemRepresentation) != 0 ||
            unlink(entitlementsPath.fileSystemRepresentation) != 0 ||
            unlink(requestPath.fileSystemRepresentation) != 0) {
            return PXKeychainWorkerFail(73, nil,
                @"One-shot Keychain authority artifacts could not be removed");
        }
        PXKeychainCommandContext *context = [[PXKeychainCommandContext alloc]
            initWithBundleIdentifier:request.targetBundleID
                        generationID:request.generationID
                  applicationEnabled:YES
                    extensionEnabled:NO];
        PXProcessKeychainSecurityAdapter *securityAdapter =
            [[PXProcessKeychainSecurityAdapter alloc]
                initWithExpectedBundleIdentifier:request.targetBundleID];
        PXKeychainCommandExecutor *executor = [[PXKeychainCommandExecutor alloc]
            initWithValidator:[[PXKeychainCommandValidator alloc] init]
            securityAdapter:securityAdapter];
        NSError *executionError = nil;
        PXKeychainCommandResponse *response = [executor executeRequest:request
                                                               context:context
                                                                   now:[NSDate date]
                                                                 error:&executionError];
        if (!response) {
            return PXKeychainWorkerFail(67, executionError,
                @"One-shot Keychain operation was rejected");
        }
        NSError *serializationError = nil;
        NSData *responseData = [NSPropertyListSerialization
            dataWithPropertyList:[response propertyListRepresentation]
            format:NSPropertyListBinaryFormat_v1_0
            options:0
            error:&serializationError];
        if (!responseData || ![responseData writeToFile:responsePath
                                                options:NSDataWritingAtomic
                                                  error:&serializationError] ||
            chmod(responsePath.fileSystemRepresentation, 0600) != 0) {
            return PXKeychainWorkerFail(74, serializationError,
                @"One-shot Keychain response could not be published");
        }
        return 0;
    }
}
