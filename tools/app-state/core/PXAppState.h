#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const PXAppStateErrorDomain;

// Resolver returns current paths, never the UUID paths saved in a snapshot.
// Keys: bundleID, version, build, executable, bundlePath, containers (ID -> path),
// keychainGroups. All declared target containers/groups must be accounted for.
@protocol PXASResolver <NSObject>
- (nullable NSDictionary *)resolve:(NSString *)bundleID error:(NSError **)error;
- (BOOL)assertStopped:(NSDictionary *)target error:(NSError **)error;
@end

// Implement in a short-lived worker, signed with the target's exact groups.
// Records must be plist objects; their order must not affect equality.
@protocol PXASKeychain <NSObject>
- (nullable NSArray<NSDictionary *> *)exportGroups:(NSArray<NSString *> *)groups error:(NSError **)error;
- (BOOL)validateRecords:(NSArray<NSDictionary *> *)records groups:(NSArray<NSString *> *)groups error:(NSError **)error;
// Check exact target-scope replacement constraints without mutating records.
- (BOOL)validateReplacement:(NSArray<NSDictionary *> *)records groups:(NSArray<NSString *> *)groups error:(NSError **)error;
// Explicit baseline reset: the user authorized clearing all target records,
// including synchronizable ones. Query/delete only the resolved exact scope.
- (BOOL)validateBaselineResetGroups:(NSArray<NSString *> *)groups error:(NSError **)error;
- (BOOL)resetGroupsForBaseline:(NSArray<NSString *> *)groups error:(NSError **)error;
// Preserve archived nonsynchronizable records; replace the archive's sync
// portion with the current sync records. Never writes the live keychain.
- (nullable NSArray<NSDictionary *> *)supplementSynchronizableRecords:(NSArray<NSDictionary *> *)records groups:(NSArray<NSString *> *)groups error:(NSError **)error;
// Remove target records absent from the archive, including synchronizable ones;
// restore archived attributes and verify complete content/ACL equality.
- (BOOL)replaceGroups:(NSArray<NSString *> *)groups records:(NSArray<NSDictionary *> *)records error:(NSError **)error;
@end

// IDFV/vendor state is separate from the filesystem/keychain transaction.
// Implementations must handle authority, daemon/cache reload and verification.
@protocol PXASIdentity <NSObject>
- (nullable NSDictionary *)capture:(NSDictionary *)target error:(NSError **)error;
- (BOOL)validateState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error;
- (BOOL)restoreState:(NSDictionary *)state target:(NSDictionary *)target error:(NSError **)error;
@end

@interface PXAppStateEngine : NSObject
// Advisory operation-thread events; no secrets or archive paths. Never determines success.
@property (nonatomic, copy, nullable) void (^progressHandler)(NSDictionary *event);
// Hold the same store lock across a save-then-restore sequence. Nested calls
// from this block are allowed on its thread; all other workers/CLIs fail busy.
- (nullable id)performExclusive:(id _Nullable (^)(NSError **error))operation error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)catalogBundle:(NSString *)bundleID error:(NSError **)error;
- (BOOL)updateSnapshot:(NSString *)reference bundleID:(NSString *)bundleID metadata:(NSDictionary *)metadata error:(NSError **)error;
- (BOOL)deleteSnapshot:(NSString *)reference bundleID:(NSString *)bundleID error:(NSError **)error;
- (nullable instancetype)initWithRoot:(NSString *)root
                            resolver:(id<PXASResolver>)resolver
                            keychain:(id<PXASKeychain>)keychain
                            identity:(nullable id<PXASIdentity>)identity
                               error:(NSError **)error;
// kind: snapshot | baseline. Baseline name must equal current app version.
// Snapshot name: YYYYMMDD-NN or "auto" for today's next sequence.
// Baselines and snapshots contain data only and are independent of each other.
// Snapshots optionally capture identity when an adapter is provided.
- (nullable NSDictionary *)captureBundle:(NSString *)bundleID
                                    kind:(NSString *)kind
                                    name:(NSString *)name
                                   error:(NSError **)error;
- (nullable NSDictionary *)inspectBundle:(NSString *)bundleID error:(NSError **)error;
// Construct a data-only reset template without copying or modifying live data.
- (nullable NSDictionary *)createBaselineBundle:(NSString *)bundleID error:(NSError **)error;
// Refresh a named snapshot with complete current state; verify capture first.
- (nullable NSDictionary *)captureBundle:(NSString *)bundleID kind:(NSString *)kind name:(NSString *)name
                       replacingSnapshot:(BOOL)replace error:(NSError **)error;
- (nullable NSDictionary *)captureBundle:(NSString *)bundleID kind:(NSString *)kind name:(NSString *)name
                       replacingSnapshot:(BOOL)replace metadata:(nullable NSDictionary *)metadata error:(NSError **)error;
// Explicit repair of an incomplete snapshot; containers and identity unchanged.
- (nullable NSDictionary *)supplementKeychainReference:(NSString *)reference
                                             bundleID:(NSString *)bundleID
                                                error:(NSError **)error;
// Reference is relative to root, e.g. com.example.app/snapshots/20261005-01.
// Baseline restoration empties all target keychain groups and generates a new
// IDFV using the identity adapter, without saving identity in the baseline.
// For snapshots, restoreIdentity opts into replaying the captured identity.
- (nullable NSDictionary *)restoreReference:(NSString *)reference
                                   bundleID:(NSString *)bundleID
                            restoreIdentity:(BOOL)restoreIdentity
                                      error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
