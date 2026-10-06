#import "PXAppState.h"
#import <CommonCrypto/CommonDigest.h>
#include <copyfile.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <errno.h>
#include <string.h>

NSString *const PXAppStateErrorDomain = @"PXAppState";
static NSString *const MetadataName = @".com.apple.mobile_container_manager.metadata.plist";
static void Check(BOOL value, NSString *message) {
    if (!value) @throw [NSException exceptionWithName:PXAppStateErrorDomain reason:message userInfo:nil];
}
static void AdapterCheck(BOOL ok, NSError *error, NSString *fallback) {
    Check(ok, error.localizedDescription ?: fallback);
}
static NSString *Canonical(NSString *path) {
    char *p = realpath(path.fileSystemRepresentation, NULL);
    Check(p != NULL, @"Path is missing or inaccessible");
    NSString *result = @(p); free(p); return result;
}
static BOOL Inside(NSString *path, NSString *root) {
    return [path hasPrefix:[root stringByAppendingString:@"/"]];
}
static BOOL SafeComponent(NSString *s) {
    if (![s isKindOfClass:NSString.class] || s.length == 0 || s.length > 180 ||
        [s isEqual:@"."] || [s isEqual:@".."]) return NO;
    return [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"].invertedSet].location == NSNotFound;
}
static BOOL SnapshotName(NSString *name) {
    NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"^[0-9]{8}-[0-9]{2}$" options:0 error:NULL];
    if([regex numberOfMatchesInString:name options:0 range:NSMakeRange(0,name.length)]!=1 || [[name substringFromIndex:9] integerValue]==0)return NO;
    NSDateFormatter *formatter=[NSDateFormatter new]; formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]; formatter.dateFormat=@"yyyyMMdd"; formatter.lenient=NO;
    NSString *day=[name substringToIndex:8]; NSDate *date=[formatter dateFromString:day];
    return date && [[formatter stringFromDate:date] isEqual:day];
}
static NSString *FileDigest(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path]; [stream open];
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); unsigned char buffer[65536], hash[CC_SHA256_DIGEST_LENGTH];
    NSInteger n; while ((n = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)n);
    [stream close]; Check(n == 0, @"Core file could not be read"); CC_SHA256_Final(hash, &ctx);
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(hash); i++) [s appendFormat:@"%02x", hash[i]];
    return s;
}
static NSData *PlistData(id value) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    Check(data != nil, @"Object is not a property list"); return data;
}
static void Save(id value, NSString *path) {
    NSData *data = PlistData(value); NSError *error = nil;
    Check([data writeToFile:path options:NSDataWritingAtomic error:&error], @"Cannot persist state");
    Check(chmod(path.fileSystemRepresentation, 0600) == 0, @"Cannot protect state file");
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    Check(fd >= 0, @"Cannot open persisted state"); int status = fsync(fd); close(fd);
    Check(status == 0, @"Cannot flush persisted state");
}
static id Load(NSString *path) {
    struct stat st; Check(lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode), @"State file missing or symlink");
    NSData *data = [NSData dataWithContentsOfFile:path];
    Check(data != nil, @"Cannot read state file");
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    Check(value != nil, @"Invalid state property list"); return value;
}
static void MakeDirectory(NSString *path) {
    NSError *error = nil; Check([NSFileManager.defaultManager createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error], @"Cannot create private directory");
}
// Hash only core files; retain path/size/mode/ownership for everything else.
static BOOL SplashBoardContent(NSString *relative) {
    return [relative isEqual:@"Library/SplashBoard"] || [relative hasPrefix:@"Library/SplashBoard/"];
}
static NSArray *InventoryWithCapturePolicy(NSString *root, NSString *executable, BOOL excludePreviews) {
    struct stat rootInfo;
    Check(lstat(root.fileSystemRepresentation,&rootInfo)==0 && S_ISDIR(rootInfo.st_mode) &&
        [Canonical(root) isEqual:root],@"Payload root is not a canonical directory");
    NSFileManager *fm = NSFileManager.defaultManager; NSError *error = nil;
    NSMutableArray *paths = [NSMutableArray array];
    NSMutableArray *directories = [NSMutableArray arrayWithObject:@""];
    while (directories.count) {
        NSString *relativeDirectory = directories.lastObject;
        [directories removeLastObject];
        NSArray *children = [fm contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:relativeDirectory] error:&error];
        Check(children != nil, @"Cannot enumerate payload");
        for (NSString *child in children) {
            NSString *relative = [relativeDirectory stringByAppendingPathComponent:child];
            struct stat st;
            Check(lstat([root stringByAppendingPathComponent:relative].fileSystemRepresentation, &st) == 0, @"Payload changed while enumerating");
            if(excludePreviews && SplashBoardContent(relative))continue;
            [paths addObject:relative];
            if (S_ISDIR(st.st_mode)) [directories addObject:relative];
        }
    }
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *relative in [paths sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path = [root stringByAppendingPathComponent:relative]; struct stat st;
        Check(lstat(path.fileSystemRepresentation, &st) == 0, @"Payload changed while enumerating");
        Check(S_ISREG(st.st_mode) || S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode), @"Payload special files are unsupported");
        NSMutableDictionary *entry = [@{@"path":relative, @"type":S_ISDIR(st.st_mode)?@"directory":(S_ISLNK(st.st_mode)?@"symlink":@"file"),
            @"mode":@(st.st_mode & 07777), @"uid":@(st.st_uid), @"gid":@(st.st_gid)} mutableCopy];
        if (S_ISLNK(st.st_mode)) {
            NSString *linkTarget = [fm destinationOfSymbolicLinkAtPath:path error:&error];
            Check(linkTarget != nil, @"Cannot read symbolic link target");
            entry[@"target"] = linkTarget;
        } else if (S_ISREG(st.st_mode)) {
            entry[@"size"] = @(st.st_size);
            NSString *extension = relative.pathExtension.lowercaseString;
            BOOL core = [relative isEqual:executable] || [relative isEqual:@"Info.plist"] ||
                [relative isEqual:@"_CodeSignature/CodeResources"] ||
                [@[@"plist", @"sqlite", @"db", @"sqlite-wal", @"db-wal"] containsObject:extension];
            if (core) entry[@"sha256"] = FileDigest(path);
        }
        [entries addObject:entry];
    }
    return entries;
}
static NSArray *Inventory(NSString *root, NSString *executable) {
    return InventoryWithCapturePolicy(root,executable,NO);
}
static NSArray *CaptureInventory(NSString *root,NSString *containerID) {
    return InventoryWithCapturePolicy(root,@"",[containerID isEqual:@"data"]);
}
static NSArray *ContentInventory(NSArray *inventory, BOOL omitMetadata) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *entry in inventory) {
        if (omitMetadata && [entry[@"path"] isEqual:MetadataName]) continue;
        NSMutableDictionary *copy = [entry mutableCopy]; [copy removeObjectsForKeys:@[@"uid", @"gid"]];
        [result addObject:copy];
    }
    return result;
}
// Normalize path components without following links or consulting their targets.
static NSString *LexicalPath(NSString *path) {
    Check(path.isAbsolutePath, @"Expected an absolute link path");
    NSMutableArray *components = [NSMutableArray array];
    for (NSString *component in path.pathComponents) {
        if ([component isEqual:@"/"] || [component isEqual:@"."]) continue;
        if ([component isEqual:@".."]) {
            if (components.count) [components removeLastObject];
        } else [components addObject:component];
    }
    NSString *result = [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
    // iOS /var is the real-rootfs alias of /private/var.
    if ([result isEqual:@"/var"] || [result hasPrefix:@"/var/"]) result = [@"/private" stringByAppendingString:result];
    return result;
}
static NSString *RelativeLink(NSString *parent, NSString *target) {
    NSArray *from = LexicalPath(parent).pathComponents, *to = LexicalPath(target).pathComponents;
    NSUInteger common = 0;
    while (common < from.count && common < to.count && [from[common] isEqual:to[common]]) common++;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = common; i < from.count; i++) [parts addObject:@".."];
    for (NSUInteger i = common; i < to.count; i++) [parts addObject:to[i]];
    return parts.count ? [parts componentsJoinedByString:@"/"] : @".";
}
static NSString *RootFSAlias(NSString *path) {
    if ([path isEqual:@"/var"] || [path hasPrefix:@"/var/"]) return [@"/private" stringByAppendingString:path];
    return path;
}
static NSDictionary *RelativeContainerTarget(NSString *raw, NSString *oldParent, NSString *containerID, NSDictionary *sourceRoots, NSDictionary *allInventories) {
    NSString *cursor = RootFSAlias(oldParent);
    NSArray *parts = raw.pathComponents;
    for (NSUInteger index = 0; index < parts.count; index++) {
        NSString *component = parts[index];
        if ([component isEqual:@"."]) continue;
        cursor = [component isEqual:@".."] ? cursor.stringByDeletingLastPathComponent : [cursor stringByAppendingPathComponent:component];
        BOOL knownDirectory = NO;
        for (NSString *key in sourceRoots) {
            NSString *root = RootFSAlias(sourceRoots[key]);
            if ([cursor isEqual:root]) {
                if (![key isEqual:containerID]) {
                    NSString *suffix = [[parts subarrayWithRange:NSMakeRange(index + 1, parts.count - index - 1)] componentsJoinedByString:@"/"];
                    return @{@"containerID":key, @"suffix":suffix};
                }
                knownDirectory = YES;
            } else if (Inside(root, cursor)) {
                // Ancestors of captured canonical roots are directory paths.
                knownDirectory = YES;
            } else if (Inside(cursor, root)) {
                NSString *relative = [cursor substringFromIndex:root.length + 1];
                for (NSDictionary *entry in allInventories[key]) {
                    if (![entry[@"path"] isEqual:relative]) continue;
                    // Do not interpret '..' through a link using string arithmetic.
                    if (![entry[@"type"] isEqual:@"directory"]) return nil;
                    knownDirectory = YES;
                    break;
                }
            }
        }
        if (!knownDirectory) return nil;
    }
    return nil;
}
static NSArray *RelocatedInventory(NSArray *inventory, NSString *containerID, NSDictionary *sourceRoots, NSDictionary *destinations, NSDictionary *allInventories) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *entry in inventory) {
        NSMutableDictionary *relocated = [entry mutableCopy];
        if ([entry[@"type"] isEqual:@"symlink"]) {
            Check([sourceRoots isKindOfClass:NSDictionary.class] && [sourceRoots[containerID] isKindOfClass:NSString.class],
                @"Symbolic links need captured container source paths");
            NSString *raw = entry[@"target"];
            Check([raw isKindOfClass:NSString.class] && raw.length > 0, @"Invalid symbolic link target");
            // Relative targets already retain their meaning in the same container
            // layout. Do not collapse '..' through intermediate symbolic links.
            if (!raw.isAbsolutePath) {
                NSString *oldParent = [[sourceRoots[containerID] stringByAppendingPathComponent:entry[@"path"]] stringByDeletingLastPathComponent];
                NSDictionary *peer = RelativeContainerTarget(raw, oldParent, containerID, sourceRoots, allInventories);
                if (peer) {
                    NSString *newParent = [[destinations[containerID] stringByAppendingPathComponent:entry[@"path"]] stringByDeletingLastPathComponent];
                    NSString *relativeRoot = RelativeLink(newParent, destinations[peer[@"containerID"]]);
                    relocated[@"target"] = [peer[@"suffix"] length] ? [relativeRoot stringByAppendingPathComponent:peer[@"suffix"]] : relativeRoot;
                }
                [result addObject:relocated];
                continue;
            }
            NSString *absolute = RootFSAlias(raw);
            for (NSString *key in sourceRoots) {
                Check([sourceRoots[key] isKindOfClass:NSString.class] && destinations[key] != nil, @"Invalid captured link scope");
                NSString *oldRoot = RootFSAlias(sourceRoots[key]);
                if (![absolute isEqual:oldRoot] && !Inside(absolute, oldRoot)) continue;
                NSString *suffix = [absolute isEqual:oldRoot] ? @"" : [absolute substringFromIndex:oldRoot.length + 1];
                NSDictionary *peer = RelativeContainerTarget(suffix, oldRoot, key, sourceRoots, allInventories);
                NSString *destinationKey = peer ? peer[@"containerID"] : key;
                if (peer) suffix = peer[@"suffix"];
                NSString *newParent = [[destinations[containerID] stringByAppendingPathComponent:entry[@"path"]] stringByDeletingLastPathComponent];
                NSString *relativeRoot = RelativeLink(newParent, destinations[destinationKey]);
                // Preserve the suffix verbatim: it may contain link/.. semantics.
                if ([suffix.pathComponents containsObject:@".."]) {
                    relocated[@"target"] = [relativeRoot stringByAppendingPathComponent:suffix];
                } else {
                    relocated[@"target"] = RelativeLink(newParent, [destinations[destinationKey] stringByAppendingPathComponent:suffix]);
                }
                break;
            }
            // Targets outside captured containers retain their original link text.
        }
        [result addObject:relocated];
    }
    return result;
}
// Historical roots are explicit per-container aliases, never guessed from UUIDs.
// A snapshot may itself have been captured after an earlier installation.
static NSArray *RelocatedHistoricalInventory(NSArray *inventory, NSString *containerID, NSDictionary *sourceRoots,
    NSDictionary *destinations, NSDictionary *allInventories, NSDictionary *aliases) {
    NSArray *result = RelocatedInventory(inventory, containerID, sourceRoots, destinations, allInventories);
    if (!aliases) return result;
    Check([aliases isKindOfClass:NSDictionary.class], @"Invalid historical container aliases");
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *key in sourceRoots) [seen addObject:RootFSAlias(sourceRoots[key])];
    for (NSString *key in aliases) {
        Check(sourceRoots[key] != nil && destinations[key] != nil && [aliases[key] isKindOfClass:NSArray.class], @"Historical alias scope is not captured");
        for (NSString *alias in aliases[key]) {
            Check([alias isKindOfClass:NSString.class] && alias.isAbsolutePath, @"Invalid historical container root");
            NSString *root = RootFSAlias(alias);
            Check([LexicalPath(root) isEqual:root] &&
                [root.stringByDeletingLastPathComponent isEqual:RootFSAlias(sourceRoots[key]).stringByDeletingLastPathComponent] &&
                ![seen containsObject:root], @"Historical alias root is ambiguous or outside container scope");
            for (NSString *destination in destinations.allValues)
                Check(![RootFSAlias(destination) isEqual:root], @"Historical alias is a current container");
            [seen addObject:root];
            NSMutableDictionary *roots = [sourceRoots mutableCopy]; roots[key] = root;
            result = RelocatedInventory(result, containerID, roots, destinations, allInventories);
        }
    }
    return result;
}
static int CopyStatus(int operation,int stage,copyfile_state_t state,const char *source,const char *destination,void *context) {
    (void)state;(void)destination;
    NSMutableDictionary *failure=(__bridge NSMutableDictionary *)context;
    if((operation==COPYFILE_RECURSE_FILE || operation==COPYFILE_RECURSE_DIR) && stage==COPYFILE_START && [failure[@"excludePreviews"] boolValue] && source){
        NSString *path=@(source),*prefix=[failure[@"sourceRoot"] stringByAppendingString:@"/"];
        if([path hasPrefix:prefix] && SplashBoardContent([path substringFromIndex:prefix.length]))return COPYFILE_SKIP;
    }
    if(operation==COPYFILE_RECURSE_ERROR || stage==COPYFILE_ERR){
        int code=errno;
        failure[@"path"]=source?@(source):@"";failure[@"errno"]=@(code);failure[@"operation"]=@(operation);
        return COPYFILE_QUIT;
    }
    if(operation==COPYFILE_RECURSE_FILE && stage==COPYFILE_FINISH && source && failure[@"progress"]){
        struct stat info;
        if(lstat(source,&info)==0 && S_ISREG(info.st_mode)) {
            void (^progress)(unsigned long long)=failure[@"progress"];
            NSMutableSet *reported=failure[@"reportedPaths"];
            if(!reported){reported=[NSMutableSet set];failure[@"reportedPaths"]=reported;}
            [reported addObject:@(source)];
            progress((unsigned long long)info.st_size);
        }
    }
    return COPYFILE_CONTINUE;
}
static void CopyVerified(NSString *source, NSString *destination, NSString *containerID, void (^progress)(unsigned long long)) {
    NSArray *before = CaptureInventory(source, containerID);
    NSMutableDictionary *failure=[@{@"sourceRoot":source,@"excludePreviews":@([containerID isEqual:@"data"])} mutableCopy];copyfile_state_t state=copyfile_state_alloc();
    if(progress)failure[@"progress"]=[progress copy];
    Check(state!=NULL,@"Cannot allocate container copy state");
    copyfile_state_set(state,COPYFILE_STATE_STATUS_CB,(void *)CopyStatus);
    copyfile_state_set(state,COPYFILE_STATE_STATUS_CTX,(__bridge void *)failure);
    int copied=copyfile(source.fileSystemRepresentation, destination.fileSystemRepresentation, state,
        COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW);
    int copyError=failure[@"errno"]?[failure[@"errno"] intValue]:errno;copyfile_state_free(state);
    Check(copied==0,[NSString stringWithFormat:@"Payload copy failed (%d: %s; operation %@) at %@",copyError,strerror(copyError),failure[@"operation"]?:@"unknown",failure[@"path"]?:source]);
    // copyfile creates an empty destination directory even when its recursion is skipped.
    // Remove that placeholder only under the copied, canonical Library directory.
    BOOL libraryDirectory=NO;
    for(NSDictionary *entry in before)if([entry[@"path"] isEqual:@"Library"] && [entry[@"type"] isEqual:@"directory"])libraryDirectory=YES;
    if([containerID isEqual:@"data"] && libraryDirectory){
        NSString *library=[destination stringByAppendingPathComponent:@"Library"];struct stat parent;
        Check(lstat(library.fileSystemRepresentation,&parent)==0 && S_ISDIR(parent.st_mode) && [Canonical(library) isEqual:library],@"Copied Library is not a canonical directory");
        NSString *excluded=[library stringByAppendingPathComponent:@"SplashBoard"];struct stat st;
        if(lstat(excluded.fileSystemRepresentation,&st)==0)
            Check([NSFileManager.defaultManager removeItemAtPath:excluded error:NULL],@"Cannot remove excluded SplashBoard placeholder");
        else Check(errno==ENOENT,@"Cannot inspect excluded SplashBoard placeholder");
    }
    Check([before isEqual:CaptureInventory(source, containerID)], @"Source changed during capture");
    Check([ContentInventory(before, NO) isEqual:ContentInventory(Inventory(destination, @""), NO)], @"Payload verification failed");
}


@interface PXAppStateEngine () {
    pthread_mutex_t _operationMutex;
    BOOL _mutexReady;
    NSUInteger _lockDepth;
}
@property (nonatomic, copy) NSString *root;
@property (nonatomic, strong) id<PXASResolver> resolver;
@property (nonatomic, strong) id<PXASKeychain> keychain;
@property (nonatomic, strong, nullable) id<PXASIdentity> identity;
@property (nonatomic) int rootFD;
@property (nonatomic) dev_t rootDevice;
@property (nonatomic) ino_t rootInode;
@end

@implementation PXAppStateEngine
- (void)reportPhase:(NSString *)phase stage:(NSString *)stage detail:(NSDictionary *)detail {
    if (!self.progressHandler) return;
    NSMutableDictionary *event=[detail mutableCopy]?:[NSMutableDictionary dictionary];
    event[@"phase"]=phase; event[@"stage"]=stage;
    // Progress reporting must never change storage or identity semantics.
    @try { self.progressHandler(event); } @catch(NSException *ignored) { (void)ignored; }
}
- (instancetype)initWithRoot:(NSString *)root resolver:(id<PXASResolver>)resolver
    keychain:(id<PXASKeychain>)keychain identity:(id<PXASIdentity>)identity error:(NSError **)error {
    self = [super init]; if (!self) return nil; _rootFD = -1;
    @try {
        pthread_mutexattr_t attributes; Check(pthread_mutexattr_init(&attributes)==0,@"Cannot initialize mutex attributes");
        int configured=pthread_mutexattr_settype(&attributes,PTHREAD_MUTEX_RECURSIVE);
        int initialized=configured==0?pthread_mutex_init(&_operationMutex,&attributes):configured;
        pthread_mutexattr_destroy(&attributes);
        Check(initialized==0,@"Cannot initialize operation mutex"); _mutexReady=YES;
        _root = Canonical(root); struct stat st;
        Check(lstat(_root.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) &&
            st.st_uid == geteuid() && (st.st_mode & 077) == 0, @"Store root must be private and owned by this process");
        _rootFD = open(_root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        Check(_rootFD >= 0, @"Cannot pin store root"); _rootDevice = st.st_dev; _rootInode = st.st_ino;
        _resolver = resolver; _keychain = keychain; _identity = identity;
    } @catch (NSException *e) {
        if (error) { *error = [NSError errorWithDomain:PXAppStateErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey:e.reason ?: @"Initialization failed"}]; }
        return nil;
    }
    return self;
}
- (void)dealloc { if (_rootFD >= 0) close(_rootFD); if (_mutexReady) pthread_mutex_destroy(&_operationMutex); }
- (NSDictionary *)createBaselineBundle:(NSString *)bundleID error:(NSError **)error {
    BOOL locked=NO;NSString *stage=nil;
    @try {
        Check(SafeComponent(bundleID),@"Invalid Bundle ID");locked=[self lock];Check(locked,@"Store is busy");
        NSDictionary *target=[self target:bundleID requireStopped:NO];
        NSString *version=target[@"version"];Check(SafeComponent(version),@"Invalid app version");
        NSString *reference=[NSString stringWithFormat:@"%@/baselines/%@",bundleID,version];
        NSString *destination=[self storePath:reference];
        Check(![NSFileManager.defaultManager fileExistsAtPath:destination],@"Baseline already exists");
        [self reportPhase:@"baseline" stage:@"prepare" detail:nil];
        stage=[self storePath:[NSString stringWithFormat:@"%@/baselines/.capture-%@",bundleID,NSUUID.UUID.UUIDString]];
        MakeDirectory([stage stringByAppendingPathComponent:@"containers"]);
        NSMutableDictionary *inventories=[NSMutableDictionary dictionary];
        [self reportPhase:@"baseline" stage:@"copy" detail:nil];
        for(NSString *key in target[@"containers"]) {
            NSString *payload=[[stage stringByAppendingPathComponent:@"containers"] stringByAppendingPathComponent:key];
            MakeDirectory(payload);
            // Container-manager metadata belongs to the active installation and
            // is retained by restore. Never capture live business data here.
            for(NSString *relative in @[@"Documents",@"Library",@"Library/Caches",@"Library/Preferences",@"tmp"]) {
                NSString *directory=[payload stringByAppendingPathComponent:relative];MakeDirectory(directory);
                Check(chmod(directory.fileSystemRepresentation,0755)==0,@"Cannot set baseline directory permissions");
            }
            inventories[key]=Inventory(payload,@"");
        }
        NSDictionary *manifest=@{@"formatVersion":@2,@"status":@"complete",@"kind":@"baseline",@"name":version,
            @"bundleID":bundleID,@"version":version,@"build":target[@"build"],@"date":NSDate.date,
            @"containerIDs":[[target[@"containers"] allKeys] sortedArrayUsingSelector:@selector(compare:)],
            @"containerSourcePaths":target[@"containers"],@"containerInventories":inventories,
            @"keychainGroups":target[@"keychainGroups"],@"keychainIncluded":@NO,@"identityIncluded":@NO};
        [self reportPhase:@"baseline" stage:@"verify_files" detail:nil];
        for(NSString *key in inventories)Check([inventories[key] isEqual:Inventory([[stage stringByAppendingPathComponent:@"containers"] stringByAppendingPathComponent:key],@"")],@"Baseline payload changed");
        Save(manifest,[stage stringByAppendingPathComponent:@"manifest.plist"]);
        Check([Load([stage stringByAppendingPathComponent:@"manifest.plist"]) isEqual:manifest],@"Baseline manifest differs");
        NSDictionary *again=[self target:bundleID requireStopped:NO];
        for(NSString *key in @[@"containers",@"containerPins",@"bundlePath",@"version",@"build",@"keychainGroups"])Check([again[key] isEqual:target[key]],@"Target installation changed");
        [self reportPhase:@"baseline" stage:@"publish" detail:nil];
        MakeDirectory(destination.stringByDeletingLastPathComponent);
        Check([NSFileManager.defaultManager moveItemAtPath:stage toPath:destination error:NULL],@"Cannot publish baseline");
        return @{@"status":@"complete",@"reference":reference};
    } @catch(NSException *e) {
        if(stage){@try{[self pinRoot];NSString *safe=[self storePath:[stage substringFromIndex:self.root.length+1]];[NSFileManager.defaultManager removeItemAtPath:safe error:NULL];}@catch(NSException *ignored){(void)ignored;}}
        if(error)*error=[NSError errorWithDomain:PXAppStateErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:e.reason?:@"Baseline creation failed"}];
        return nil;
    } @finally {if(locked)[self unlock];}
}
- (void)pinRoot {
    struct stat st; Check(lstat(self.root.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) &&
        st.st_dev == self.rootDevice && st.st_ino == self.rootInode && st.st_uid == geteuid() && (st.st_mode & 077) == 0,
        @"Store root was replaced or its permissions changed");
}
- (NSString *)storePath:(NSString *)relative {
    [self pinRoot]; Check(relative.length > 0 && !relative.isAbsolutePath, @"Invalid store reference");
    for (NSString *piece in relative.pathComponents) Check(SafeComponent(piece), @"Unsafe store component");
    NSString *path = [self.root stringByAppendingPathComponent:relative];
    NSString *parent = path;
    while (![NSFileManager.defaultManager fileExistsAtPath:parent]) parent = parent.stringByDeletingLastPathComponent;
    Check([Canonical(parent) isEqual:parent] && ([parent isEqual:self.root] || Inside(parent, self.root)), @"Store path escapes root or follows a link");
    return path;
}
- (NSDictionary *)target:(NSString *)bundleID {
    return [self target:bundleID requireStopped:YES];
}
- (NSDictionary *)target:(NSString *)bundleID requireStopped:(BOOL)requireStopped {
    Check(SafeComponent(bundleID), @"Invalid Bundle ID"); NSError *error = nil;
    NSDictionary *target = [self.resolver resolve:bundleID error:&error];
    AdapterCheck(target != nil, error, @"Target resolution failed");
    Check([target[@"bundleID"] isEqual:bundleID] && SafeComponent(target[@"version"]) &&
        SafeComponent(target[@"build"]) && SafeComponent(target[@"executable"]), @"Invalid target identity");
    NSString *bundle = target[@"bundlePath"]; Check([Canonical(bundle) isEqual:bundle], @"Bundle path is not canonical");
    NSDictionary *containers = target[@"containers"];
    Check([containers isKindOfClass:NSDictionary.class] && containers[@"data"] != nil, @"Missing main data container");
    NSMutableArray *roots = [NSMutableArray arrayWithObject:bundle];
    NSMutableDictionary *pins = [NSMutableDictionary dictionary];
    for (NSString *key in containers) {
        Check(SafeComponent(key), @"Unsafe container identifier"); NSString *path = containers[key];
        Check([Canonical(path) isEqual:path] && ![path isEqual:self.root] && !Inside(self.root, path) &&
            !Inside(path, self.root), @"Container overlaps store or follows symlink");
        for (NSString *other in roots) Check(![path isEqual:other] && !Inside(path, other) && !Inside(other, path), @"Target paths overlap");
        [roots addObject:path];
        struct stat st; Check(lstat(path.fileSystemRepresentation,&st)==0 && S_ISDIR(st.st_mode),@"Container is not a directory");
        pins[path]=@{@"device":@(st.st_dev),@"inode":@(st.st_ino)};
    }
    NSArray *groups = target[@"keychainGroups"]; Check([groups isKindOfClass:NSArray.class], @"Missing keychain scope");
    for (NSString *group in groups) Check(SafeComponent(group) && [group containsString:@"."] &&
        ![group hasPrefix:@"com.apple."] && ![group containsString:@"*"], @"Unsafe keychain group");
    NSMutableDictionary *pinned=[target mutableCopy]; pinned[@"containerPins"]=pins;
    if(requireStopped)[self stopped:pinned]; return pinned;
}
- (void)stopped:(NSDictionary *)target {
    NSError *error = nil; AdapterCheck([self.resolver assertStopped:target error:&error], error, @"Target is running");
    for (NSString *path in [target[@"containers"] allValues]) {
        struct stat st; NSDictionary *pin=target[@"containerPins"][path];
        Check([Canonical(path) isEqual:path] && lstat(path.fileSystemRepresentation,&st)==0 &&
            S_ISDIR(st.st_mode) && [pin[@"device"] isEqual:@(st.st_dev)] && [pin[@"inode"] isEqual:@(st.st_ino)], @"Container path changed");
    }
    [self pinRoot];
}
- (NSArray *)export:(NSDictionary *)target {
    NSError *error = nil; NSArray *records = [self.keychain exportGroups:target[@"keychainGroups"] error:&error];
    AdapterCheck(records != nil, error, @"Keychain export failed");
    AdapterCheck([self.keychain validateRecords:records groups:target[@"keychainGroups"] error:&error], error, @"Invalid keychain records");
    return records;
}
- (BOOL)lock {
    if (pthread_mutex_trylock(&_operationMutex)!=0) return NO;
    @try {
        [self pinRoot];
        if (_lockDepth>0 || flock(self.rootFD,LOCK_EX|LOCK_NB)==0) { _lockDepth++; return YES; }
        pthread_mutex_unlock(&_operationMutex); return NO;
    } @catch (NSException *e) { pthread_mutex_unlock(&_operationMutex); @throw e; }
}
- (void)unlock { if (--_lockDepth==0) flock(self.rootFD, LOCK_UN); pthread_mutex_unlock(&_operationMutex); }
- (id)performExclusive:(id (^)(NSError **))operation error:(NSError **)error {
    BOOL locked=NO;
    @try { locked=[self lock]; Check(locked,@"Store is busy"); return operation(error); }
    @catch (NSException *exception) { [self publishError:exception error:error]; return nil; }
    @finally { if (locked) [self unlock]; }
}
- (NSString *)nextSnapshotName:(NSString *)bundleID {
    NSDateFormatter *formatter=[NSDateFormatter new]; formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]; formatter.dateFormat=@"yyyyMMdd";
    NSString *day=[formatter stringFromDate:[NSDate date]];
    for(NSUInteger i=1;i<=99;i++) {
        NSString *name=[NSString stringWithFormat:@"%@-%02lu",day,(unsigned long)i];
        NSString *path=[self storePath:[NSString stringWithFormat:@"%@/snapshots/%@",bundleID,name]];
        if(![NSFileManager.defaultManager fileExistsAtPath:path])return name;
    }
    Check(NO,@"All 99 daily snapshot names are already used"); return @"";
}
- (void)publishError:(NSException *)e error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:PXAppStateErrorDomain code:2
        userInfo:@{NSLocalizedDescriptionKey:e.reason ?: @"Operation failed"}];
}
- (NSDictionary *)inspectBundle:(NSString *)bundleID error:(NSError **)error {
    BOOL locked=NO;
    @try { locked=[self lock]; Check(locked,@"Store is busy");
        NSDictionary *target = [self target:bundleID]; NSArray *records = [self export:target];
        return @{@"bundleID":bundleID, @"version":target[@"version"], @"build":target[@"build"],
            @"containers":target[@"containers"], @"keychainCount":@(records.count)};
    } @catch (NSException *e) { [self publishError:e error:error]; return nil; }
    @finally { if(locked)[self unlock]; }
}
- (NSDictionary *)supplementKeychainReference:(NSString *)reference bundleID:(NSString *)bundleID error:(NSError **)error {
    BOOL locked=NO,archiveChanged=NO;
    @try {
        locked=[self lock];Check(locked,@"Store is busy");NSDictionary *target=[self target:bundleID];
        NSString *expected=[NSString stringWithFormat:@"%@/snapshots/%@",bundleID,reference.lastPathComponent];
        Check([reference isEqual:expected] && SnapshotName(reference.lastPathComponent),@"Supplement requires an exact snapshot reference");
        NSString *manifestPath=[self storePath:[reference stringByAppendingPathComponent:@"manifest.plist"]];
        NSDictionary *original=Load(manifestPath);NSMutableDictionary *manifest=[original mutableCopy];
        Check([manifest[@"formatVersion"] isEqual:@2] && [manifest[@"status"] isEqual:@"complete"] &&
            [manifest[@"kind"] isEqual:@"snapshot"] && [manifest[@"bundleID"] isEqual:bundleID] &&
            [manifest[@"keychainIncluded"] boolValue],@"Snapshot format or target differs");
        Check([[NSSet setWithArray:manifest[@"keychainGroups"]] isEqual:[NSSet setWithArray:target[@"keychainGroups"]]] &&
            [[NSSet setWithArray:manifest[@"containerIDs"]] isEqual:[NSSet setWithArray:[target[@"containers"] allKeys]]],@"Snapshot scopes differ");
        NSString *recordsPath=[self storePath:[reference stringByAppendingPathComponent:@"keychain/records.plist"]];
        Check([FileDigest(recordsPath) isEqual:manifest[@"keychainSHA256"]],@"Keychain archive checksum differs");
        NSArray *saved=Load(recordsPath);NSError *adapterError=nil;
        AdapterCheck([self.keychain validateRecords:saved groups:target[@"keychainGroups"] error:&adapterError],adapterError,@"Invalid keychain archive");
        Check([manifest[@"keychainCount"] isEqual:@(saved.count)],@"Keychain archive count differs");
        NSArray *merged=[self.keychain supplementSynchronizableRecords:saved groups:target[@"keychainGroups"] error:&adapterError];
        AdapterCheck(merged!=nil,adapterError,@"Cannot supplement synchronizable keychain records");
        [self stopped:target];
        Check([Load([self storePath:[reference stringByAppendingPathComponent:@"manifest.plist"]]) isEqual:original] &&
            [FileDigest([self storePath:[reference stringByAppendingPathComponent:@"keychain/records.plist"]]) isEqual:manifest[@"keychainSHA256"]],@"Archive changed during export");
        archiveChanged=YES;Save(merged,recordsPath);
        Check([[NSSet setWithArray:Load(recordsPath)] isEqual:[NSSet setWithArray:merged]],@"Supplemented keychain readback differs");
        manifest[@"keychainCount"]=@(merged.count);manifest[@"keychainSHA256"]=FileDigest(recordsPath);
        NSISO8601DateFormatter *formatter=[NSISO8601DateFormatter new];manifest[@"keychainUpdatedUTC"]=[formatter stringFromDate:NSDate.date];
        Save(manifest,[self storePath:[reference stringByAppendingPathComponent:@"manifest.plist"]]);
        Check([Load(manifestPath) isEqual:manifest],@"Updated manifest readback differs");
        return @{@"status":@"complete",@"reference":reference,@"keychainCount":@(merged.count),@"liveKeychainModified":@NO};
    } @catch(NSException *e){
        if(error)*error=[NSError errorWithDomain:PXAppStateErrorDomain code:4 userInfo:@{
            NSLocalizedDescriptionKey:e.reason?:@"Keychain supplement failed",@"archiveMayBePartial":@(archiveChanged)}];
        return nil;
    } @finally{if(locked)[self unlock];}
}
- (NSDictionary *)captureBundle:(NSString *)bundleID kind:(NSString *)kind name:(NSString *)name error:(NSError **)error {
    return [self captureBundle:bundleID kind:kind name:name replacingSnapshot:NO error:error];
}
- (NSDictionary *)captureBundle:(NSString *)bundleID kind:(NSString *)kind name:(NSString *)name replacingSnapshot:(BOOL)replace error:(NSError **)error {
    return [self captureBundle:bundleID kind:kind name:name replacingSnapshot:replace metadata:nil error:error];
}
- (NSDictionary *)validatedMetadata:(NSDictionary *)metadata {
    Check([metadata isKindOfClass:NSDictionary.class],@"Invalid account description");
    Check(metadata.count==2 && [metadata[@"displayName"] isKindOfClass:NSString.class] &&
        [metadata[@"note"] isKindOfClass:NSString.class] &&
        [metadata[@"displayName"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length>0 &&
        [metadata[@"displayName"] length]<=100 && [metadata[@"note"] length]<=1000,@"Invalid account name or note");
    return metadata;
}
- (NSDictionary *)accountMetadata:(NSDictionary *)manifest {
    if([manifest[@"title"] isKindOfClass:NSString.class])return [self validatedMetadata:@{@"displayName":manifest[@"title"],@"note":manifest[@"note"]?:@""}];
    return manifest[@"account"]?[self validatedMetadata:manifest[@"account"]]:nil;
}
- (NSDictionary *)snapshotManifest:(NSString *)reference bundleID:(NSString *)bundleID {
    Check(SafeComponent(bundleID) && SnapshotName(reference.lastPathComponent) &&
        [reference isEqual:[NSString stringWithFormat:@"%@/snapshots/%@",bundleID,reference.lastPathComponent]],@"Invalid snapshot reference");
    NSDictionary *manifest=Load([self storePath:[reference stringByAppendingPathComponent:@"manifest.plist"]]);
    Check([manifest[@"formatVersion"] isEqual:@2] && [manifest[@"status"] isEqual:@"complete"] &&
        [manifest[@"kind"] isEqual:@"snapshot"] && [manifest[@"bundleID"] isEqual:bundleID],@"Invalid snapshot manifest");
    return manifest;
}
- (NSArray *)catalogBundle:(NSString *)bundleID error:(NSError **)error {
    BOOL locked=NO;
    @try {
        locked=[self lock];Check(locked,@"Store is busy");Check(SafeComponent(bundleID),@"Invalid Bundle ID");
        NSMutableArray *items=[NSMutableArray array];
        for(NSString *kind in @[@"snapshots",@"baselines"]){
            NSString *directory=[self storePath:[NSString stringWithFormat:@"%@/%@",bundleID,kind]];
            if(![NSFileManager.defaultManager fileExistsAtPath:directory])continue;
            NSError *listingError=nil;NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&listingError];
            AdapterCheck(names!=nil,listingError,@"Cannot list saved environments");
            for(NSString *name in names){
                if([name hasPrefix:@"."])continue;
                Check(SafeComponent(name),@"Unsafe archive name");
                NSString *ref=[NSString stringWithFormat:@"%@/%@/%@",bundleID,kind,name];
                NSDictionary *m=Load([self storePath:[ref stringByAppendingPathComponent:@"manifest.plist"]]);
                Check([m[@"formatVersion"] isEqual:@2] && [m[@"status"] isEqual:@"complete"] &&
                    [m[@"bundleID"] isEqual:bundleID] && [m[@"kind"] isEqual:([kind isEqual:@"snapshots"]?@"snapshot":@"baseline")],@"Invalid archive manifest");
                if([kind isEqual:@"snapshots"])Check(SnapshotName(name),@"Invalid snapshot name");
                // Version and date describe the archive; they do not govern restoration.
                NSString *version=[m[@"version"] isKindOfClass:NSString.class]?m[@"version"]:
                    ([m[@"version"] isKindOfClass:NSNumber.class]?[m[@"version"] stringValue]:name);
                id date=m[@"date"]?:m[@"createdUTC"];
                if([date isKindOfClass:NSString.class]) {
                    NSISO8601DateFormatter *formatter=[NSISO8601DateFormatter new];
                    NSDate *parsed=[formatter dateFromString:date];
                    if(!parsed){formatter.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;parsed=[formatter dateFromString:date];}
                    date=parsed;
                }
                NSMutableDictionary *item=[@{@"reference":ref,@"name":name,@"kind":m[@"kind"],@"version":version} mutableCopy];
                if([date isKindOfClass:NSDate.class])item[@"savedAt"]=date;
                if([m[@"kind"] isEqual:@"snapshot"] && [m[@"identityIncluded"] boolValue]) {
                    NSUUID *identifier=[m[@"idfv"] isKindOfClass:NSString.class]?[[NSUUID alloc] initWithUUIDString:m[@"idfv"]]:nil;
                    if(!identifier) {
                        NSString *identityPath=[self storePath:[ref stringByAppendingPathComponent:@"identity/state.plist"]];
                        NSDictionary *identity=[NSDictionary dictionaryWithContentsOfFile:identityPath];
                        if([identity[@"bundleID"] isEqual:bundleID] && [identity[@"IDFV"] isKindOfClass:NSString.class])identifier=[[NSUUID alloc] initWithUUIDString:identity[@"IDFV"]];
                    }
                    if(identifier)item[@"IDFV"]=identifier.UUIDString;
                }
                NSDictionary *account=[self accountMetadata:m];if(account)item[@"account"]=account;
                [items addObject:item];
            }
        }
        return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            NSDate *ad=a[@"savedAt"],*bd=b[@"savedAt"];
            if(ad && bd){NSComparisonResult order=[bd compare:ad];if(order!=NSOrderedSame)return order;}
            else if(ad || bd)return ad?NSOrderedAscending:NSOrderedDescending;
            return [a[@"reference"] compare:b[@"reference"]];
        }];
    }@catch(NSException *e){[self publishError:e error:error];return nil;}@finally{if(locked)[self unlock];}
}
- (BOOL)updateSnapshot:(NSString *)reference bundleID:(NSString *)bundleID metadata:(NSDictionary *)metadata error:(NSError **)error {
    BOOL locked=NO;
    @try{locked=[self lock];Check(locked,@"Store is busy");NSMutableDictionary *m=[[self snapshotManifest:reference bundleID:bundleID] mutableCopy];
        NSDictionary *account=[self validatedMetadata:metadata];m[@"title"]=account[@"displayName"];m[@"note"]=account[@"note"];
        [m removeObjectForKey:@"account"];Save(m,[self storePath:[reference stringByAppendingPathComponent:@"manifest.plist"]]);return YES;
    }@catch(NSException *e){[self publishError:e error:error];return NO;}@finally{if(locked)[self unlock];}
}
- (BOOL)deleteSnapshot:(NSString *)reference bundleID:(NSString *)bundleID error:(NSError **)error {
    BOOL locked=NO;
    @try{locked=[self lock];Check(locked,@"Store is busy");[self snapshotManifest:reference bundleID:bundleID];
        NSError *deletionError=nil;BOOL ok=[NSFileManager.defaultManager removeItemAtPath:[self storePath:reference] error:&deletionError];
        AdapterCheck(ok,deletionError,@"Cannot remove selected snapshot");return YES;
    }@catch(NSException *e){[self publishError:e error:error];return NO;}@finally{if(locked)[self unlock];}
}
- (NSDictionary *)captureBundle:(NSString *)bundleID kind:(NSString *)kind name:(NSString *)name replacingSnapshot:(BOOL)replace metadata:(NSDictionary *)metadata error:(NSError **)error {
    BOOL locked = NO,archiveChanged=NO; NSString *stage = nil;
    __block unsigned long long copiedBytes=0; __block NSUInteger copiedFiles=0;
    void (^copiedFile)(unsigned long long)=^(unsigned long long size) {
        copiedBytes+=size; copiedFiles++; [self reportPhase:@"backup" stage:@"copy" detail:@{@"bytes":@(copiedBytes),@"files":@(copiedFiles)}];
    };
    @try {
        [self reportPhase:@"backup" stage:@"prepare" detail:nil];
        Check([kind isEqual:@"snapshot"] || [kind isEqual:@"baseline"], @"Unknown capture kind");
        Check(SafeComponent(name), @"Unsafe capture name"); Check(SafeComponent(bundleID),@"Invalid Bundle ID"); locked = [self lock]; Check(locked, @"Store is busy");
        NSDictionary *target = [self target:bundleID]; BOOL baseline = [kind isEqual:@"baseline"];
        Check(!replace || (!baseline && ![name isEqual:@"auto"]),@"Replacement requires an explicit snapshot name");
        Check(!baseline || [name isEqual:target[@"version"]], @"Baseline name must equal app version");
        NSArray *capturedRecords=nil;
        if (!baseline) {
            if ([name isEqual:@"auto"]) name=[self nextSnapshotName:bundleID];
            Check(SnapshotName(name),@"Snapshot name must be YYYYMMDD-NN (01-99) with a valid date");
        }
        NSString *reference = [NSString stringWithFormat:@"%@/%@/%@",bundleID,baseline?@"baselines":@"snapshots",name];
        NSString *destination = [self storePath:reference];NSDictionary *previous=nil;
        if(replace){
            previous=Load([self storePath:[reference stringByAppendingPathComponent:@"manifest.plist"]]);
            Check([previous[@"formatVersion"] isEqual:@2] && [previous[@"status"] isEqual:@"complete"] &&
                [previous[@"kind"] isEqual:@"snapshot"] && [previous[@"bundleID"] isEqual:bundleID],@"Existing snapshot target differs");
        }else Check(![NSFileManager.defaultManager fileExistsAtPath:destination], @"Capture already exists");
        stage=[self storePath:[NSString stringWithFormat:@"%@/%@/.capture-%@",bundleID,baseline?@"baselines":@"snapshots",NSUUID.UUID.UUIDString]];
        MakeDirectory(stage);
        NSMutableDictionary *inventories = [NSMutableDictionary dictionary];
        MakeDirectory([stage stringByAppendingPathComponent:@"containers"]);
        [self reportPhase:@"backup" stage:@"copy" detail:@{@"bytes":@0,@"files":@0}];
        for (NSString *key in target[@"containers"]) {
            [self stopped:target]; NSString *source = target[@"containers"][key];
            NSString *dest = [[stage stringByAppendingPathComponent:@"containers"] stringByAppendingPathComponent:key];
            CopyVerified(source,dest,key,copiedFile); inventories[key] = CaptureInventory(source,key);
        }
        NSMutableDictionary *manifest = [@{@"formatVersion":@2, @"status":@"complete", @"kind":kind, @"name":name,
            @"bundleID":bundleID, @"version":target[@"version"], @"build":target[@"build"],
            @"containerIDs":[[target[@"containers"] allKeys] sortedArrayUsingSelector:@selector(compare:)],
            @"containerSourcePaths":target[@"containers"],
            @"keychainGroups":target[@"keychainGroups"], @"keychainIncluded":@(!baseline), @"identityIncluded":@NO,
            @"date":[NSDate date], @"captureExclusions":@[@"data:Library/SplashBoard"],
            @"verificationPolicy":@"core hashes; other files path/type/size/mode inventory"} mutableCopy];
        NSDictionary *account=metadata?:[self accountMetadata:previous];
        if(account){Check(!baseline,@"Baseline cannot contain an account description");account=[self validatedMetadata:account];manifest[@"title"]=account[@"displayName"];manifest[@"note"]=account[@"note"];}
        else if(!baseline){manifest[@"title"]=name;manifest[@"note"]=@"";}
        if (!baseline) {
            [self reportPhase:@"backup" stage:@"keychain" detail:nil];
            NSArray *records = [self export:target]; MakeDirectory([stage stringByAppendingPathComponent:@"keychain"]);
            capturedRecords=records;
            Save(records,[stage stringByAppendingPathComponent:@"keychain/records.plist"]);
            manifest[@"keychainSHA256"] = FileDigest([stage stringByAppendingPathComponent:@"keychain/records.plist"]);
            manifest[@"keychainCount"] = @(records.count);
            if (self.identity) { [self reportPhase:@"backup" stage:@"identity" detail:nil]; NSError *adapterError = nil; NSDictionary *state = [self.identity capture:target error:&adapterError];
                AdapterCheck(state != nil,adapterError,@"Identity capture failed"); MakeDirectory([stage stringByAppendingPathComponent:@"identity"]);
                Save(state,[stage stringByAppendingPathComponent:@"identity/state.plist"]); manifest[@"identityIncluded"] = @YES;
                NSUUID *identifier=[state[@"IDFV"] isKindOfClass:NSString.class]?[[NSUUID alloc] initWithUUIDString:state[@"IDFV"]]:nil;
                if(identifier)manifest[@"idfv"]=identifier.UUIDString;
                manifest[@"identitySHA256"] = FileDigest([stage stringByAppendingPathComponent:@"identity/state.plist"]);
            }
        }
        manifest[@"containerInventories"] = inventories;
        [self reportPhase:@"backup" stage:@"verify_files" detail:@{@"bytes":@(copiedBytes),@"files":@(copiedFiles)}];
        [self stopped:target];
        for (NSString *key in inventories) Check([inventories[key] isEqual:CaptureInventory(target[@"containers"][key],key)],@"Container changed before snapshot publication");
        if(capturedRecords) {
            [self reportPhase:@"backup" stage:@"verify_keychain" detail:@{@"records":@(capturedRecords.count)}];
            NSArray *again=[self export:target];
            Check(capturedRecords.count==again.count && [[NSSet setWithArray:capturedRecords] isEqual:[NSSet setWithArray:again]], @"Keychain changed during capture");
        }
        Save(manifest,[stage stringByAppendingPathComponent:@"manifest.plist"]);
        [self reportPhase:@"backup" stage:@"publish" detail:nil];
        MakeDirectory(destination.stringByDeletingLastPathComponent);
        if(replace){
            Check([Load([self storePath:[reference stringByAppendingPathComponent:@"manifest.plist"]]) isEqual:previous],@"Existing snapshot changed before replacement");
            destination=[self storePath:reference];archiveChanged=YES;
            Check([NSFileManager.defaultManager removeItemAtPath:destination error:NULL],@"Cannot remove selected previous snapshot");
        }
        Check([NSFileManager.defaultManager moveItemAtPath:stage toPath:destination error:NULL], @"Cannot publish capture");
        return @{@"status":@"complete", @"reference":reference, @"keychainIncluded":@(!baseline)};
    } @catch (NSException *e) {
        if (stage && !archiveChanged) { @try { [self pinRoot]; NSString *safe=[self storePath:[stage substringFromIndex:self.root.length+1]];
            if ([NSFileManager.defaultManager fileExistsAtPath:safe]) Check([NSFileManager.defaultManager removeItemAtPath:safe error:NULL],@"Cannot remove incomplete capture");
        } @catch (NSException *ignored) { (void)ignored; } }
        if(archiveChanged && error)*error=[NSError errorWithDomain:PXAppStateErrorDomain code:4 userInfo:@{
            NSLocalizedDescriptionKey:e.reason?:@"Snapshot replacement failed",@"archiveMayBePartial":@YES,
            @"pendingCaptureReference":[stage substringFromIndex:self.root.length+1]}];
        else [self publishError:e error:error]; return nil;
    }
    @finally { if (locked) [self unlock]; }
}

- (NSDictionary *)restoreReference:(NSString *)reference bundleID:(NSString *)bundleID
    restoreIdentity:(BOOL)restoreIdentity error:(NSError **)error {
    BOOL locked = NO, mutationStarted = NO;
    NSDictionary *target = nil;
    __block unsigned long long copiedBytes=0; __block NSUInteger copiedFiles=0;
    void (^copiedFile)(unsigned long long)=^(unsigned long long size) {
        copiedBytes+=size; copiedFiles++; [self reportPhase:@"restore" stage:@"copy" detail:@{@"bytes":@(copiedBytes),@"files":@(copiedFiles)}];
    };
    @try {
        [self reportPhase:@"restore" stage:@"preflight" detail:nil];
        locked = [self lock]; Check(locked,@"Store is busy"); target = [self target:bundleID];
        NSString *source = [self storePath:reference]; NSDictionary *manifest = Load([source stringByAppendingPathComponent:@"manifest.plist"]);
        Check([manifest[@"formatVersion"] isEqual:@2] && [manifest[@"status"] isEqual:@"complete"] &&
            [manifest[@"bundleID"] isEqual:bundleID], @"Snapshot format or target differs");
        Check([@[@"snapshot",@"baseline"] containsObject:manifest[@"kind"]],@"Invalid manifest kind");
        Check([[NSSet setWithArray:manifest[@"keychainGroups"]] isEqual:[NSSet setWithArray:target[@"keychainGroups"]]] &&
            [[NSSet setWithArray:manifest[@"containerIDs"]] isEqual:[NSSet setWithArray:[target[@"containers"] allKeys]]], @"Target scopes differ from capture");
        NSDictionary *inventory = manifest[@"containerInventories"];
        Check([inventory isKindOfClass:NSDictionary.class],@"Container inventories missing from manifest");
        BOOL baseline = [manifest[@"kind"] isEqual:@"baseline"];
        NSArray *desired = @[];
        restoreIdentity = restoreIdentity || baseline;
        if (!baseline) {
            Check([manifest[@"keychainIncluded"] boolValue],@"Snapshot lacks keychain");
            NSString *kp = [source stringByAppendingPathComponent:@"keychain/records.plist"];
            Check([FileDigest(kp) isEqual:manifest[@"keychainSHA256"]],@"Keychain archive checksum differs"); desired = Load(kp);
        } else Check(![manifest[@"keychainIncluded"] boolValue] && ![manifest[@"identityIncluded"] boolValue],@"Baseline contains identity or keychain");
        NSError *adapterError = nil;
        AdapterCheck([self.keychain validateRecords:desired groups:target[@"keychainGroups"] error:&adapterError],adapterError,@"Invalid keychain archive");
        BOOL keychainReady=baseline?[self.keychain validateBaselineResetGroups:target[@"keychainGroups"] error:&adapterError]:
            [self.keychain validateReplacement:desired groups:target[@"keychainGroups"] error:&adapterError];
        AdapterCheck(keychainReady,adapterError,@"Keychain replacement preflight failed");
        NSDictionary *identityDesired = nil;
        if (restoreIdentity) {
            Check(self.identity != nil, @"Identity restoration needs an adapter");
            if (baseline) {
                NSDictionary *current = [self.identity capture:target error:&adapterError];
                AdapterCheck(current != nil, adapterError, @"Cannot read current identity");
                NSMutableDictionary *fresh = [current mutableCopy];
                fresh[@"IDFV"] = NSUUID.UUID.UUIDString;
                identityDesired = fresh;
            } else {
                Check([manifest[@"identityIncluded"] boolValue],@"Snapshot lacks captured identity");
                NSString *ip=[source stringByAppendingPathComponent:@"identity/state.plist"];
                Check([FileDigest(ip) isEqual:manifest[@"identitySHA256"]],@"Identity archive checksum differs"); identityDesired=Load(ip);
            }
            AdapterCheck([self.identity validateState:identityDesired target:target error:&adapterError],adapterError,@"Identity preflight failed");
        }
        NSMutableDictionary *restoredInventories = [NSMutableDictionary dictionary];
        for (NSString *key in target[@"containers"]) {
            NSString *payload = [[source stringByAppendingPathComponent:@"containers"] stringByAppendingPathComponent:key];
            Check([inventory[key] isKindOfClass:NSArray.class],@"Container inventory missing");
            Check([ContentInventory(inventory[key],NO) isEqual:ContentInventory(Inventory(payload,@""),NO)],@"Container payload differs");
            restoredInventories[key] = RelocatedHistoricalInventory(inventory[key], key, manifest[@"containerSourcePaths"], target[@"containers"], inventory, manifest[@"containerSourceAliases"]);
        }
        [self stopped:target];
        mutationStarted = YES;
        [self reportPhase:@"restore" stage:@"keychain" detail:@{@"records":@(desired.count)}];
        BOOL keychainRestored=baseline?[self.keychain resetGroupsForBaseline:target[@"keychainGroups"] error:&adapterError]:
            [self.keychain replaceGroups:target[@"keychainGroups"] records:desired error:&adapterError];
        AdapterCheck(keychainRestored,adapterError,@"Keychain restore failed");
        for (NSString *key in target[@"containers"]) {
            [self reportPhase:@"restore" stage:@"clear" detail:nil];
            NSString *destination = target[@"containers"][key];
            NSString *payload = [[source stringByAppendingPathComponent:@"containers"] stringByAppendingPathComponent:key];
            NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:destination error:NULL];
            Check(children != nil,@"Cannot enumerate current container");
            for (NSString *child in children) {
                if ([child isEqual:MetadataName]) continue;
                [self stopped:target];
                Check([NSFileManager.defaultManager removeItemAtPath:[destination stringByAppendingPathComponent:child] error:NULL],@"Cannot remove current container contents");
            }
            children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:payload error:NULL];
            Check(children != nil,@"Cannot enumerate snapshot container");
            [self reportPhase:@"restore" stage:@"copy" detail:@{@"bytes":@(copiedBytes),@"files":@(copiedFiles)}];
            for (NSString *child in children) {
                if ([child isEqual:MetadataName]) continue;
                [self stopped:target];
                NSString *childSource=[payload stringByAppendingPathComponent:child];
                NSMutableDictionary *copyContext=[@{@"progress":[copiedFile copy]} mutableCopy];
                copyfile_state_t copyState=copyfile_state_alloc(); Check(copyState!=NULL,@"Cannot allocate restore copy state");
                copyfile_state_set(copyState,COPYFILE_STATE_STATUS_CB,(void *)CopyStatus);
                copyfile_state_set(copyState,COPYFILE_STATE_STATUS_CTX,(__bridge void *)copyContext);
                int copied=copyfile(childSource.fileSystemRepresentation,[destination stringByAppendingPathComponent:child].fileSystemRepresentation,copyState,
                    COPYFILE_ALL|COPYFILE_RECURSIVE|COPYFILE_NOFOLLOW);
                copyfile_state_free(copyState); Check(copied==0,@"Container copy failed");
                struct stat directFile;
                if(lstat(childSource.fileSystemRepresentation,&directFile)==0 && S_ISREG(directFile.st_mode) &&
                    ![copyContext[@"reportedPaths"] containsObject:childSource])copiedFile((unsigned long long)directFile.st_size);
            }
            for (NSDictionary *entry in restoredInventories[key]) {
                if ([entry[@"path"] isEqual:MetadataName]) continue;
                NSString *path=[destination stringByAppendingPathComponent:entry[@"path"]]; struct stat st;
                Check(lstat(path.fileSystemRepresentation,&st)==0,@"Restored metadata target changed");
                uid_t uid=[entry[@"uid"] unsignedIntValue]; gid_t gid=[entry[@"gid"] unsignedIntValue];
                if ([entry[@"type"] isEqual:@"symlink"]) {
                    Check(S_ISLNK(st.st_mode), @"Restored link type differs");
                    [self stopped:target];
                    Check(unlink(path.fileSystemRepresentation) == 0 && symlink([entry[@"target"] fileSystemRepresentation], path.fileSystemRepresentation) == 0,
                        @"Cannot relocate restored symbolic link");
                    Check(lchown(path.fileSystemRepresentation, uid, gid) == 0, @"Cannot restore link ownership");
                    Check(lchmod(path.fileSystemRepresentation, [entry[@"mode"] unsignedIntValue]) == 0, @"Cannot restore link mode");
                    continue;
                }
                Check(!S_ISLNK(st.st_mode), @"Restored file type differs");
                if(st.st_uid!=uid || st.st_gid!=gid) Check(chown(path.fileSystemRepresentation,uid,gid)==0,@"Cannot restore original file ownership");
                Check(chmod(path.fileSystemRepresentation,[entry[@"mode"] unsignedIntValue])==0,@"Cannot restore original file mode");
            }
        }
        [self reportPhase:@"restore" stage:@"verify_files" detail:@{@"bytes":@(copiedBytes),@"files":@(copiedFiles)}];
        for(NSString *key in restoredInventories) {
            NSString *destination=target[@"containers"][key];
            Check([ContentInventory(restoredInventories[key],YES) isEqual:ContentInventory(Inventory(destination,@""),YES)],@"Restored container differs");
        }
        if (restoreIdentity) {
            [self reportPhase:@"restore" stage:@"identity" detail:nil];
            AdapterCheck([self.identity restoreState:identityDesired target:target error:&adapterError],adapterError,@"Identity restore failed");
            [self reportPhase:@"restore" stage:@"verify_identity" detail:nil];
            NSDictionary *readback = [self.identity capture:target error:&adapterError];
            Check([readback isEqual:identityDesired],@"Identity readback differs");
        }
        [self reportPhase:@"restore" stage:@"verify_keychain" detail:@{@"records":@(desired.count)}];
        [self stopped:target]; NSArray *again=[self export:target];
        Check(desired.count==again.count && [[NSSet setWithArray:desired] isEqual:[NSSet setWithArray:again]],@"Keychain readback differs");
        return @{@"status":@"complete",@"reference":reference,@"keychainCount":@(desired.count),
            @"identityRestored":@(restoreIdentity),@"identityRegenerated":@(baseline)};
    } @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:PXAppStateErrorDomain code:2
            userInfo:@{NSLocalizedDescriptionKey:e.reason ?: @"Restore failed",
                @"stateMayBePartial":@(mutationStarted)}];
        return nil;
    } @finally { if (locked) [self unlock]; }
}
@end
