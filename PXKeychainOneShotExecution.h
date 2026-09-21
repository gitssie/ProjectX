#import <Foundation/Foundation.h>

#import "PXKeychainOneShot.h"

NS_ASSUME_NONNULL_BEGIN

@protocol PXKeychainOneShotProcessRunning <NSObject>

- (BOOL)runExecutable:(NSString *)executablePath
             arguments:(NSArray<NSString *> *)arguments
               timeout:(NSTimeInterval)timeout
        standardOutput:(NSData * _Nullable * _Nullable)standardOutput
                 error:(NSError * _Nullable * _Nullable)error;

@end

@protocol PXKeychainOneShotTargetResolving <NSObject>

- (nullable NSString *)executablePathForBundleIdentifier:(NSString *)bundleIdentifier
                                                    error:(NSError * _Nullable * _Nullable)error;

@end

@interface PXKeychainOneShotProcessRunner : NSObject <PXKeychainOneShotProcessRunning>
@end

@interface PXKeychainOneShotTargetResolver : NSObject <PXKeychainOneShotTargetResolving>
@end

@interface PXKeychainOneShotExecution : NSObject <PXKeychainOneShotExecuting>

- (instancetype)initWithFileManager:(NSFileManager *)fileManager
                       processRunner:(id<PXKeychainOneShotProcessRunning>)processRunner
                      targetResolver:(id<PXKeychainOneShotTargetResolving>)targetResolver
                  workerTemplatePath:(NSString *)workerTemplatePath
                            ldidPath:(NSString *)ldidPath
             operationsRootDirectory:(NSString *)operationsRootDirectory
                       workerTimeout:(NSTimeInterval)workerTimeout;

@end

NS_ASSUME_NONNULL_END
