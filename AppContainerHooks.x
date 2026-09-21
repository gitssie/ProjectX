#import <Foundation/Foundation.h>

#import "AppIdentityHookSupport.h"
#import "PXProcessHookPolicy.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static __thread BOOL PXAppPathTranslationInProgress = NO;

static NSString *PXRealPath(NSString *path) {
    if (PXAppPathTranslationInProgress || PXAppIdentityMappingsChangedSinceLaunch()) {
        return path;
    }
    PXAppPathTranslationInProgress = YES;
    NSString *translatedPath = nil;
    @try {
        translatedPath = [[PXAppIdentityRuntime sharedRuntime] translatedRealPathForPath:path];
    } @finally {
        PXAppPathTranslationInProgress = NO;
    }
    return translatedPath ?: path;
}

static NSString *PXObservablePath(NSString *path) {
    if (PXAppPathTranslationInProgress || PXAppIdentityMappingsChangedSinceLaunch()) {
        return path;
    }
    PXAppPathTranslationInProgress = YES;
    NSString *translatedPath = nil;
    @try {
        translatedPath = [[PXAppIdentityRuntime sharedRuntime] translatedObservablePathForPath:path];
    } @finally {
        PXAppPathTranslationInProgress = NO;
    }
    return translatedPath ?: path;
}

static NSURL *PXRealURL(NSURL *url) {
    if (PXAppPathTranslationInProgress || PXAppIdentityMappingsChangedSinceLaunch()) {
        return url;
    }
    PXAppPathTranslationInProgress = YES;
    NSURL *translatedURL = nil;
    @try {
        translatedURL = [[PXAppIdentityRuntime sharedRuntime] translatedRealFileURLForURL:url];
    } @finally {
        PXAppPathTranslationInProgress = NO;
    }
    return translatedURL ?: url;
}

static NSURL *PXObservableURL(NSURL *url) {
    if (PXAppPathTranslationInProgress || PXAppIdentityMappingsChangedSinceLaunch()) {
        return url;
    }
    PXAppPathTranslationInProgress = YES;
    NSURL *translatedURL = nil;
    @try {
        translatedURL = [[PXAppIdentityRuntime sharedRuntime] translatedObservableFileURLForURL:url];
    } @finally {
        PXAppPathTranslationInProgress = NO;
    }
    return translatedURL ?: url;
}

static const char *PXRealFileSystemPath(const char *path, char translatedPath[PATH_MAX]) {
    if (!path || path[0] != '/') {
        return path;
    }
    @autoreleasepool {
        NSString *originalPath = [NSString stringWithUTF8String:path];
        NSString *realPath = originalPath ? PXRealPath(originalPath) : nil;
        if (!realPath || [realPath isEqualToString:originalPath]) {
            return path;
        }
        const char *fileSystemPath = realPath.fileSystemRepresentation;
        if (strlen(fileSystemPath) >= PATH_MAX) {
            return path;
        }
        strlcpy(translatedPath, fileSystemPath, PATH_MAX);
        return translatedPath;
    }
}

static ssize_t PXRewriteReadlinkResultAsObservable(char *buffer,
                                                   size_t bufferSize,
                                                   ssize_t originalLength) {
    if (!buffer || originalLength <= 0 || (size_t)originalLength >= bufferSize) {
        return originalLength;
    }
    @autoreleasepool {
        NSString *originalTarget = [[NSString alloc] initWithBytes:buffer
                                                            length:(NSUInteger)originalLength
                                                          encoding:NSUTF8StringEncoding];
        NSString *observableTarget = originalTarget ? PXObservablePath(originalTarget) : nil;
        if (!observableTarget || [observableTarget isEqualToString:originalTarget]) {
            return originalLength;
        }
        NSData *observableData = [observableTarget dataUsingEncoding:NSUTF8StringEncoding];
        size_t observableLength = MIN(observableData.length, bufferSize);
        memcpy(buffer, observableData.bytes, observableLength);
        return (ssize_t)observableLength;
    }
}

%group PXAppContainerIdentityHooks

%hookf(NSString *, NSHomeDirectory) {
    NSString *originalHomeDirectory = %orig;
    return PXObservablePath(originalHomeDirectory);
}

%hookf(NSString *, NSHomeDirectoryForUser, NSString *userName) {
    NSString *originalHomeDirectory = %orig(userName);
    return PXObservablePath(originalHomeDirectory);
}

%hookf(NSArray *, NSSearchPathForDirectoriesInDomains, NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask, BOOL expandTilde) {
    NSArray<NSString *> *originalPaths = %orig(directory, domainMask, expandTilde);
    NSMutableArray<NSString *> *observablePaths = [NSMutableArray arrayWithCapacity:originalPaths.count];
    for (NSString *path in originalPaths) {
        [observablePaths addObject:PXObservablePath(path)];
    }
    return [observablePaths copy];
}

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    return %orig(PXRealPath(path));
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    return %orig(PXRealPath(path), isDirectory);
}

- (NSData *)contentsAtPath:(NSString *)path {
    return %orig(PXRealPath(path));
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    return %orig(PXRealPath(path), error);
}

- (NSArray<NSString *> *)subpathsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    return %orig(PXRealPath(path), error);
}

- (NSArray<NSString *> *)subpathsAtPath:(NSString *)path {
    return %orig(PXRealPath(path));
}

- (NSDirectoryEnumerator<NSString *> *)enumeratorAtPath:(NSString *)path {
    return %orig(PXRealPath(path));
}

- (BOOL)changeCurrentDirectoryPath:(NSString *)path {
    return %orig(PXRealPath(path));
}

- (NSString *)currentDirectoryPath {
    NSString *originalPath = %orig;
    return PXObservablePath(originalPath);
}

- (NSDirectoryEnumerator<NSURL *> *)enumeratorAtURL:(NSURL *)url
                         includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys
                                            options:(NSDirectoryEnumerationOptions)mask
                                       errorHandler:(BOOL (^)(NSURL *url, NSError *error))handler {
    return %orig(PXRealURL(url), keys, mask, handler);
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    return %orig(PXRealPath(path), error);
}

- (BOOL)createDirectoryAtPath:(NSString *)path
  withIntermediateDirectories:(BOOL)createIntermediates
                   attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
                        error:(NSError **)error {
    return %orig(PXRealPath(path), createIntermediates, attributes, error);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes {
    return %orig(PXRealPath(path), data, attributes);
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    return %orig(PXRealPath(path), error);
}

- (BOOL)copyItemAtPath:(NSString *)sourcePath toPath:(NSString *)destinationPath error:(NSError **)error {
    return %orig(PXRealPath(sourcePath), PXRealPath(destinationPath), error);
}

- (BOOL)moveItemAtPath:(NSString *)sourcePath toPath:(NSString *)destinationPath error:(NSError **)error {
    return %orig(PXRealPath(sourcePath), PXRealPath(destinationPath), error);
}

- (BOOL)linkItemAtPath:(NSString *)sourcePath toPath:(NSString *)destinationPath error:(NSError **)error {
    return %orig(PXRealPath(sourcePath), PXRealPath(destinationPath), error);
}

- (BOOL)createSymbolicLinkAtPath:(NSString *)path
             withDestinationPath:(NSString *)destinationPath
                           error:(NSError **)error {
    return %orig(PXRealPath(path), PXRealPath(destinationPath), error);
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path error:(NSError **)error {
    NSString *destination = %orig(PXRealPath(path), error);
    return destination ? PXObservablePath(destination) : nil;
}

- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
          ofItemAtPath:(NSString *)path
                 error:(NSError **)error {
    return %orig(attributes, PXRealPath(path), error);
}

- (BOOL)contentsEqualAtPath:(NSString *)path1 andPath:(NSString *)path2 {
    return %orig(PXRealPath(path1), PXRealPath(path2));
}

- (NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url
                    includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys
                                       options:(NSDirectoryEnumerationOptions)mask
                                         error:(NSError **)error {
    NSArray<NSURL *> *originalURLs = %orig(PXRealURL(url), keys, mask, error);
    NSMutableArray<NSURL *> *observableURLs = [NSMutableArray arrayWithCapacity:originalURLs.count];
    for (NSURL *originalURL in originalURLs) {
        [observableURLs addObject:PXObservableURL(originalURL)];
    }
    return [observableURLs copy];
}

- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory
                             inDomains:(NSSearchPathDomainMask)domainMask {
    NSArray<NSURL *> *originalURLs = %orig;
    NSMutableArray<NSURL *> *observableURLs = [NSMutableArray arrayWithCapacity:originalURLs.count];
    for (NSURL *originalURL in originalURLs) {
        [observableURLs addObject:PXObservableURL(originalURL)];
    }
    return [observableURLs copy];
}

- (NSURL *)temporaryDirectory {
    NSURL *originalURL = %orig;
    return PXObservableURL(originalURL);
}

- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error {
    return %orig(PXRealURL(url), error);
}

- (BOOL)copyItemAtURL:(NSURL *)sourceURL toURL:(NSURL *)destinationURL error:(NSError **)error {
    return %orig(PXRealURL(sourceURL), PXRealURL(destinationURL), error);
}

- (BOOL)moveItemAtURL:(NSURL *)sourceURL toURL:(NSURL *)destinationURL error:(NSError **)error {
    return %orig(PXRealURL(sourceURL), PXRealURL(destinationURL), error);
}

- (BOOL)linkItemAtURL:(NSURL *)sourceURL toURL:(NSURL *)destinationURL error:(NSError **)error {
    return %orig(PXRealURL(sourceURL), PXRealURL(destinationURL), error);
}

%end


%hook NSDirectoryEnumerator

- (id)nextObject {
    id result = %orig;
    if ([result isKindOfClass:[NSURL class]]) {
        return PXObservableURL(result);
    }
    if ([result isKindOfClass:[NSString class]] && [result isAbsolutePath]) {
        return PXObservablePath(result);
    }
    return result;
}

- (NSArray *)allObjects {
    NSArray *results = %orig;
    NSMutableArray *observableResults = [NSMutableArray arrayWithCapacity:results.count];
    for (id result in results) {
        if ([result isKindOfClass:[NSURL class]]) {
            [observableResults addObject:PXObservableURL(result)];
        } else if ([result isKindOfClass:[NSString class]] && [result isAbsolutePath]) {
            [observableResults addObject:PXObservablePath(result)];
        } else {
            [observableResults addObject:result];
        }
    }
    return [observableResults copy];
}

%end


%hookf(int, open, const char *path, int flags, ...) {
    char translatedPath[PATH_MAX];
    const char *realPath = PXRealFileSystemPath(path, translatedPath);
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode_t mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
        return %orig(realPath, flags, mode);
    }
    return %orig(realPath, flags);
}

%hookf(int, openat, int directoryDescriptor, const char *path, int flags, ...) {
    char translatedPath[PATH_MAX];
    const char *realPath = PXRealFileSystemPath(path, translatedPath);
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode_t mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
        return %orig(directoryDescriptor, realPath, flags, mode);
    }
    return %orig(directoryDescriptor, realPath, flags);
}

%hookf(FILE *, fopen, const char *path, const char *mode) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath), mode);
}

%hookf(int, access, const char *path, int mode) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath), mode);
}

%hookf(DIR *, opendir, const char *path) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath));
}

%hookf(int, stat, const char *path, struct stat *buffer) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath), buffer);
}

%hookf(int, lstat, const char *path, struct stat *buffer) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath), buffer);
}

%hookf(int, unlink, const char *path) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath));
}

%hookf(int, remove, const char *path) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath));
}

%hookf(int, rename, const char *sourcePath, const char *destinationPath) {
    char translatedSourcePath[PATH_MAX];
    char translatedDestinationPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(sourcePath, translatedSourcePath),
                 PXRealFileSystemPath(destinationPath, translatedDestinationPath));
}

%hookf(int, mkdir, const char *path, mode_t mode) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath), mode);
}

%hookf(int, rmdir, const char *path) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath));
}

%hookf(int, symlink, const char *target, const char *linkPath) {
    char translatedTarget[PATH_MAX];
    char translatedLinkPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(target, translatedTarget),
                 PXRealFileSystemPath(linkPath, translatedLinkPath));
}

%hookf(int, symlinkat, const char *target, int directoryDescriptor, const char *linkPath) {
    char translatedTarget[PATH_MAX];
    char translatedLinkPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(target, translatedTarget),
                 directoryDescriptor,
                 PXRealFileSystemPath(linkPath, translatedLinkPath));
}

%hookf(ssize_t, readlink, const char *path, char *buffer, size_t bufferSize) {
    char translatedPath[PATH_MAX];
    ssize_t originalLength = %orig(PXRealFileSystemPath(path, translatedPath), buffer, bufferSize);
    return PXRewriteReadlinkResultAsObservable(buffer, bufferSize, originalLength);
}

%hookf(ssize_t, readlinkat, int directoryDescriptor, const char *path, char *buffer, size_t bufferSize) {
    char translatedPath[PATH_MAX];
    ssize_t originalLength = %orig(directoryDescriptor,
                                   PXRealFileSystemPath(path, translatedPath),
                                   buffer,
                                   bufferSize);
    return PXRewriteReadlinkResultAsObservable(buffer, bufferSize, originalLength);
}

%hookf(int, chdir, const char *path) {
    char translatedPath[PATH_MAX];
    return %orig(PXRealFileSystemPath(path, translatedPath));
}

%hookf(char *, realpath, const char *path, char *resolvedPath) {
    char translatedPath[PATH_MAX];
    char *originalResult = %orig(PXRealFileSystemPath(path, translatedPath), resolvedPath);
    if (!originalResult) {
        return NULL;
    }
    @autoreleasepool {
        NSString *originalResolvedPath = [NSString stringWithUTF8String:originalResult];
        NSString *observablePath = originalResolvedPath ? PXObservablePath(originalResolvedPath) : nil;
        if (!observablePath || [observablePath isEqualToString:originalResolvedPath]) {
            return originalResult;
        }
        const char *observableFileSystemPath = observablePath.fileSystemRepresentation;
        if (resolvedPath) {
            if (strlen(observableFileSystemPath) >= PATH_MAX) {
                errno = ENAMETOOLONG;
                return NULL;
            }
            strlcpy(resolvedPath, observableFileSystemPath, PATH_MAX);
            return resolvedPath;
        }
        free(originalResult);
        return strdup(observableFileSystemPath);
    }
}

%hookf(char *, getcwd, char *buffer, size_t size) {
    char *originalResult = %orig(buffer, size);
    if (!originalResult) {
        return NULL;
    }
    @autoreleasepool {
        NSString *originalPath = [NSString stringWithUTF8String:originalResult];
        NSString *observablePath = originalPath ? PXObservablePath(originalPath) : nil;
        if (!observablePath || [observablePath isEqualToString:originalPath]) {
            return originalResult;
        }
        const char *observableFileSystemPath = observablePath.fileSystemRepresentation;
        size_t requiredLength = strlen(observableFileSystemPath) + 1;
        if (buffer) {
            if (requiredLength > size) {
                errno = ERANGE;
                return NULL;
            }
            strlcpy(buffer, observableFileSystemPath, size);
            return buffer;
        }
        free(originalResult);
        return strdup(observableFileSystemPath);
    }
}

%end


%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXObserveAppIdentityMappingChanges();
        PXAppIdentityRecord *identity = PXPrepareCurrentProcessAppIdentity();
        if (!PXPrepareCurrentProcessDataPathMapping(identity)) {
            return;
        }
        %init(PXAppContainerIdentityHooks);
    }
}
