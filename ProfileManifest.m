#import "ProfileManifest.h"

#import "NetworkIdentity.h"
#import "RegionIdentity.h"

#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *const PXProfileManifestErrorDomain = @"com.hydra.projectx.profile-manifest";

static NSDictionary<NSString *, NSString *> *PXProfileFieldSourcePolicy(void) {
    return @{
        @"stableSyntheticIdentity": @"profile",
        @"bootUUID": @"virtualSession",
        @"bootTime": @"virtualSession",
        @"modelAndOSValues": @"derived",
        @"location": @"controlled",
        @"network": @"controlled",
        @"region": @"derivedFromCarrier"
    };
}

@interface PXVirtualRuntimeSession ()

@property (nonatomic, copy, readwrite) NSString *bootUUID;
@property (nonatomic, copy, readwrite) NSDate *bootTime;

@end

@implementation PXVirtualRuntimeSession

- (instancetype)initWithBootUUID:(NSString *)bootUUID bootTime:(NSDate *)bootTime {
    self = [super init];
    if (self) {
        _bootUUID = [bootUUID copy];
        _bootTime = [bootTime copy];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{
        @"bootUUID": self.bootUUID,
        @"bootTime": self.bootTime
    };
}

+ (nullable instancetype)sessionWithPropertyList:(NSDictionary<NSString *, id> *)propertyList {
    NSString *bootUUID = propertyList[@"bootUUID"];
    NSDate *bootTime = propertyList[@"bootTime"];
    if (![[NSUUID alloc] initWithUUIDString:bootUUID] || ![bootTime isKindOfClass:[NSDate class]]) {
        return nil;
    }
    return [[self alloc] initWithBootUUID:bootUUID bootTime:bootTime];
}

@end

@interface PXDeterministicRandomSource : NSObject

- (instancetype)initWithSeed:(NSData *)seed;
- (uint64_t)nextUInt64;
- (NSUInteger)indexWithUpperBound:(NSUInteger)upperBound;
- (NSString *)uuidString;
- (NSString *)stringWithAlphabet:(NSString *)alphabet length:(NSUInteger)length;

@end

@implementation PXDeterministicRandomSource {
    uint64_t _state;
}

- (instancetype)initWithSeed:(NSData *)seed {
    self = [super init];
    if (self) {
        const uint8_t *bytes = seed.bytes;
        uint64_t hash = 1469598103934665603ULL;
        for (NSUInteger index = 0; index < seed.length; index++) {
            hash ^= bytes[index];
            hash *= 1099511628211ULL;
        }
        _state = hash ?: 0x9e3779b97f4a7c15ULL;
    }
    return self;
}

- (uint64_t)nextUInt64 {
    _state += 0x9e3779b97f4a7c15ULL;
    uint64_t value = _state;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
    return value ^ (value >> 31);
}

- (NSUInteger)indexWithUpperBound:(NSUInteger)upperBound {
    return upperBound == 0 ? 0 : (NSUInteger)([self nextUInt64] % upperBound);
}

- (NSString *)uuidString {
    uint8_t bytes[16];
    uint64_t first = [self nextUInt64];
    uint64_t second = [self nextUInt64];
    memcpy(bytes, &first, sizeof(first));
    memcpy(bytes + sizeof(first), &second, sizeof(second));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:bytes];
    return uuid.UUIDString.lowercaseString;
}

- (NSString *)stringWithAlphabet:(NSString *)alphabet length:(NSUInteger)length {
    NSMutableString *result = [NSMutableString stringWithCapacity:length];
    for (NSUInteger index = 0; index < length; index++) {
        NSUInteger characterIndex = [self indexWithUpperBound:alphabet.length];
        [result appendString:[alphabet substringWithRange:NSMakeRange(characterIndex, 1)]];
    }
    return [result copy];
}

@end

@implementation PXProfileGenerationInput

- (instancetype)init {
    self = [super init];
    if (self) {
        _seed = [NSData data];
        _generatedAt = [NSDate dateWithTimeIntervalSince1970:0];
        _modelCatalog = @[];
        _physicalModelRecord = @{};
        _usesPhysicalDeviceModel = NO;
        _iOSCatalog = @[];
        _carrierCatalog = @[];
        _trustedCarrierIDs = [NSSet set];
        _pinnedLocation = @{};
        _region = @{};
        _appBundleIdentifiers = [NSSet set];
        _appGroupIdentifiers = [NSSet set];
        _installIdentifierKeysByBundleIdentifier = @{};
        _graphicsHostCapabilities = @{};
    }
    return self;
}

@end

@interface PXProfileManifest ()

@property (nonatomic, readwrite) NSInteger schemaVersion;
@property (nonatomic, copy, readwrite) NSString *generationID;
@property (nonatomic, copy, readwrite) NSString *seed;
@property (nonatomic, copy, readwrite) NSDate *generatedAt;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *device;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *operatingSystem;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *identifiers;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *network;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *region;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *location;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *graphics;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, PXAppIdentityRecord *> *appIdentities;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, PXAppGroupIdentityRecord *> *appGroupIdentities;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *fieldSourcePolicy;
@property (nonatomic, strong, readwrite) PXVirtualRuntimeSession *virtualSession;

@end

static BOOL PXProfileManifestValidationFailure(NSError * _Nullable * _Nullable error, NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                     code:3
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

@implementation PXProfileManifest

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *PXAppIdentityPropertyLists(
    NSDictionary<NSString *, PXAppIdentityRecord *> *identities
) {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *propertyLists = [NSMutableDictionary dictionary];
    [identities enumerateKeysAndObjectsUsingBlock:^(NSString *bundleIdentifier,
                                                     PXAppIdentityRecord *identity,
                                                     BOOL *stop) {
        (void)stop;
        propertyLists[bundleIdentifier] = [identity propertyListRepresentation];
    }];
    return [propertyLists copy];
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *PXAppGroupIdentityPropertyLists(
    NSDictionary<NSString *, PXAppGroupIdentityRecord *> *identities
) {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *propertyLists = [NSMutableDictionary dictionary];
    [identities enumerateKeysAndObjectsUsingBlock:^(NSString *groupIdentifier,
                                                     PXAppGroupIdentityRecord *identity,
                                                     BOOL *stop) {
        (void)stop;
        propertyLists[groupIdentifier] = [identity propertyListRepresentation];
    }];
    return [propertyLists copy];
}

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{
        @"schemaVersion": @(self.schemaVersion),
        @"generationID": self.generationID,
        @"seed": self.seed,
        @"generatedAt": self.generatedAt,
        @"device": self.device,
        @"operatingSystem": self.operatingSystem,
        @"identifiers": self.identifiers,
        @"network": self.network,
        @"region": self.region,
        @"location": self.location,
        @"graphics": self.graphics ?: @{},
        @"appIdentities": PXAppIdentityPropertyLists(self.appIdentities),
        @"appGroupIdentities": PXAppGroupIdentityPropertyLists(self.appGroupIdentities),
        @"fieldSourcePolicy": self.fieldSourcePolicy,
        @"virtualSession": [self.virtualSession propertyListRepresentation]
    };
}

- (BOOL)validateWithError:(NSError * _Nullable * _Nullable)error {
    if (self.schemaVersion != 5 || ![[NSUUID alloc] initWithUUIDString:self.generationID] ||
        self.seed.length == 0 || !self.generatedAt) {
        return PXProfileManifestValidationFailure(error, @"Manifest metadata is incomplete");
    }
    NSArray<NSString *> *requiredDeviceStringFields = @[
        @"identifier", @"hwModel", @"boardID", @"screenResolution",
        @"cpuArchitecture", @"gpuFamily"
    ];
    NSMutableArray<NSString *> *invalidDeviceFields = [NSMutableArray array];
    NSDictionary<NSString *, id> *device = [self.device isKindOfClass:[NSDictionary class]]
        ? self.device
        : @{};
    for (NSString *field in requiredDeviceStringFields) {
        id value = device[field];
        if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) {
            [invalidDeviceFields addObject:field];
        }
    }
    if (invalidDeviceFields.count > 0) {
        return PXProfileManifestValidationFailure(
            error,
            [NSString stringWithFormat:@"Selected device record has missing or invalid fields: %@",
                [invalidDeviceFields componentsJoinedByString:@", "]]);
    }

    NSArray *supportedIOSMajors = self.device[@"supportedIOSMajorVersions"];
    if (![supportedIOSMajors containsObject:self.operatingSystem[@"majorVersion"]] ||
        [self.operatingSystem[@"version"] length] == 0 || [self.operatingSystem[@"build"] length] == 0 ||
        [self.operatingSystem[@"kernel_version"] length] == 0 || [self.operatingSystem[@"darwin"] length] == 0 ||
        [self.operatingSystem[@"xnu"] length] == 0) {
        return PXProfileManifestValidationFailure(error, @"Operating system tuple is incompatible or incomplete");
    }

    NSString *radioTechnology = self.network[@"radioTechnology"];
    NSArray *supportedRadios = self.network[@"supportedRadioTechnologies"];
    NSString *transport = self.network[@"transport"];
    BOOL isOffline = [transport isEqualToString:@"none"] && radioTechnology.length == 0;
    BOOL is5G = [radioTechnology isEqualToString:@"CTRadioAccessTechnologyNR"] ||
        [radioTechnology isEqualToString:@"CTRadioAccessTechnologyNRNSA"];
    if ((!isOffline && ![supportedRadios containsObject:radioTechnology]) ||
        (is5G && ![self.device[@"supports5G"] boolValue]) ||
        [self.network[@"carrierID"] length] == 0 || [self.network[@"carrierName"] length] == 0 ||
        [self.network[@"mcc"] length] == 0 ||
        [self.network[@"mnc"] length] == 0 || [self.network[@"isoCountryCode"] length] == 0 ||
        [self.network[@"serviceIdentifier"] length] == 0 || transport.length == 0) {
        return PXProfileManifestValidationFailure(error, @"Network radio is incompatible with the selected carrier or model");
    }
    PXRegionIdentity *regionIdentity = [PXRegionIdentity identityWithPropertyList:self.region];
    if (!regionIdentity ||
        [regionIdentity.countryCode caseInsensitiveCompare:self.network[@"isoCountryCode"]] != NSOrderedSame) {
        return PXProfileManifestValidationFailure(error, @"Regional identity is incomplete or inconsistent with the selected Carrier");
    }

    if (![self.fieldSourcePolicy isEqualToDictionary:PXProfileFieldSourcePolicy()]) {
        return PXProfileManifestValidationFailure(error, @"Profile field source policy is missing or invalid");
    }
    if (self.graphics.count > 0) {
        PXGraphicsIdentity *graphicsIdentity = [PXGraphicsIdentity
            identityWithPropertyList:self.graphics
            error:error];
        if (!graphicsIdentity ||
            ![graphicsIdentity validateAgainstModelRecord:self.device
                                         hostCapabilities:graphicsIdentity.hostCapabilities
                                                    error:error] ||
            ![graphicsIdentity.generationID isEqualToString:self.generationID]) {
            return NO;
        }
    }
    if (!self.virtualSession) {
        return PXProfileManifestValidationFailure(error, @"Profile session metadata is missing or implausible");
    }
    NSTimeInterval bootMetadataAge = [self.generatedAt timeIntervalSinceDate:self.virtualSession.bootTime];
    if (bootMetadataAge < 12 * 3600 || bootMetadataAge > 48 * 3600) {
        return PXProfileManifestValidationFailure(error, @"Profile session metadata is missing or implausible");
    }

    NSArray<NSString *> *uuidKeys = @[
        @"idfa", @"idfv", @"dyldCacheUUID", @"pasteboardUUID",
        @"keychainUUID", @"userDefaultsUUID", @"coreDataUUID"
    ];
    for (NSString *key in uuidKeys) {
        if (![[NSUUID alloc] initWithUUIDString:self.identifiers[key]]) {
            return PXProfileManifestValidationFailure(
                error,
                [NSString stringWithFormat:@"Identifier %@ is not a UUID", key]
            );
        }
    }
    for (NSString *bundleIdentifier in self.appIdentities) {
        if (bundleIdentifier.length == 0 || ![self.appIdentities[bundleIdentifier] isKindOfClass:[PXAppIdentityRecord class]]) {
            return PXProfileManifestValidationFailure(error, @"Application identity map is invalid");
        }
    }
    for (NSString *groupIdentifier in self.appGroupIdentities) {
        if (groupIdentifier.length == 0 || ![self.appGroupIdentities[groupIdentifier] isKindOfClass:[PXAppGroupIdentityRecord class]]) {
            return PXProfileManifestValidationFailure(error, @"App Group identity map is invalid");
        }
    }

    NSString *serialNumber = self.identifiers[@"serialNumber"];
    NSString *imei = self.identifiers[@"imei"];
    NSString *meid = self.identifiers[@"meid"];
    NSCharacterSet *nonDecimalCharacters = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSCharacterSet *nonHexCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    if (serialNumber.length != 12 || imei.length != 15 ||
        [imei rangeOfCharacterFromSet:nonDecimalCharacters].location != NSNotFound ||
        meid.length != 14 || [meid.uppercaseString rangeOfCharacterFromSet:nonHexCharacters].location != NSNotFound) {
        return PXProfileManifestValidationFailure(error, @"Serial, IMEI, or MEID format is invalid");
    }
    NSInteger imeiSum = 0;
    for (NSUInteger index = 0; index < imei.length; index++) {
        NSInteger digit = [imei characterAtIndex:index] - '0';
        if (index % 2 == 1) {
            digit *= 2;
            if (digit > 9) digit -= 9;
        }
        imeiSum += digit;
    }
    if (imeiSum % 10 != 0) {
        return PXProfileManifestValidationFailure(error, @"IMEI check digit is invalid");
    }
    return YES;
}

+ (nullable instancetype)manifestWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                             error:(NSError * _Nullable * _Nullable)error {
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Manifest property list is not a dictionary"}];
        }
        return nil;
    }

    PXProfileManifest *manifest = [[self alloc] init];
    NSInteger storedSchemaVersion = [propertyList[@"schemaVersion"] integerValue];
    manifest.schemaVersion = (storedSchemaVersion == 3 || storedSchemaVersion == 4) ? 5 : storedSchemaVersion;
    manifest.generationID = propertyList[@"generationID"] ?: @"";
    manifest.seed = propertyList[@"seed"] ?: @"";
    manifest.generatedAt = propertyList[@"generatedAt"];
    manifest.device = propertyList[@"device"] ?: @{};
    manifest.operatingSystem = propertyList[@"operatingSystem"] ?: @{};
    NSMutableDictionary<NSString *, id> *identifiers = [propertyList[@"identifiers"] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    [identifiers removeObjectsForKeys:@[@"appGroupUUID", @"appInstallUUID", @"appContainerUUID"]];
    manifest.identifiers = [identifiers copy];
    manifest.network = propertyList[@"network"] ?: @{};
    NSData *regionSeed = [[NSData alloc] initWithBase64EncodedString:manifest.seed options:0]
        ?: [manifest.seed dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary<NSString *, id> *storedRegion = [propertyList[@"region"] isKindOfClass:[NSDictionary class]]
        ? propertyList[@"region"]
        : @{};
    PXRegionIdentity *regionIdentity = storedSchemaVersion == 3 || storedSchemaVersion == 4
        ? PXRegionIdentityByCompletingPropertyList(storedRegion,
                                                   manifest.network[@"isoCountryCode"] ?: @"",
                                                   regionSeed ?: [NSData data])
        : [PXRegionIdentity identityWithPropertyList:storedRegion];
    manifest.region = [regionIdentity propertyListRepresentation] ?: @{};
    manifest.location = propertyList[@"location"] ?: @{};
    manifest.graphics = [propertyList[@"graphics"] isKindOfClass:[NSDictionary class]]
        ? propertyList[@"graphics"]
        : @{};
    NSMutableDictionary<NSString *, PXAppIdentityRecord *> *appIdentities = [NSMutableDictionary dictionary];
    NSDictionary *storedAppIdentities = [propertyList[@"appIdentities"] isKindOfClass:[NSDictionary class]]
        ? propertyList[@"appIdentities"]
        : @{};
    [storedAppIdentities enumerateKeysAndObjectsUsingBlock:^(NSString *bundleIdentifier,
                                                             NSDictionary *identityPropertyList,
                                                             BOOL *stop) {
        (void)stop;
        PXAppIdentityRecord *identity = [identityPropertyList isKindOfClass:[NSDictionary class]]
            ? [PXAppIdentityRecord identityWithPropertyList:identityPropertyList]
            : nil;
        if (identity && [bundleIdentifier isKindOfClass:[NSString class]]) {
            appIdentities[bundleIdentifier] = identity;
        }
    }];
    if (appIdentities.count != storedAppIdentities.count) {
        PXProfileManifestValidationFailure(error, @"Application identity map is invalid");
        return nil;
    }
    manifest.appIdentities = [appIdentities copy];
    NSMutableDictionary<NSString *, PXAppGroupIdentityRecord *> *appGroupIdentities = [NSMutableDictionary dictionary];
    NSDictionary *storedAppGroupIdentities = [propertyList[@"appGroupIdentities"] isKindOfClass:[NSDictionary class]]
        ? propertyList[@"appGroupIdentities"]
        : @{};
    [storedAppGroupIdentities enumerateKeysAndObjectsUsingBlock:^(NSString *groupIdentifier,
                                                                  NSDictionary *identityPropertyList,
                                                                  BOOL *stop) {
        (void)stop;
        PXAppGroupIdentityRecord *identity = [identityPropertyList isKindOfClass:[NSDictionary class]]
            ? [PXAppGroupIdentityRecord identityWithPropertyList:identityPropertyList]
            : nil;
        if (identity && [groupIdentifier isKindOfClass:[NSString class]]) {
            appGroupIdentities[groupIdentifier] = identity;
        }
    }];
    if (appGroupIdentities.count != storedAppGroupIdentities.count) {
        PXProfileManifestValidationFailure(error, @"App Group identity map is invalid");
        return nil;
    }
    manifest.appGroupIdentities = [appGroupIdentities copy];
    manifest.fieldSourcePolicy = storedSchemaVersion == 3 || storedSchemaVersion == 4
        ? PXProfileFieldSourcePolicy()
        : (propertyList[@"fieldSourcePolicy"] ?: @{});
    manifest.virtualSession = [PXVirtualRuntimeSession sessionWithPropertyList:propertyList[@"virtualSession"] ?: @{}];
    return [manifest validateWithError:error] ? manifest : nil;
}

@end

NSUUID *PXProfileVendorIdentifierForBundleIdentifier(PXProfileManifest *manifest,
                                                      NSString *bundleIdentifier) {
    if (!manifest || ![manifest validateWithError:nil] ||
        !PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO) ||
        !manifest.appIdentities[bundleIdentifier]) {
        return nil;
    }
    return [[NSUUID alloc] initWithUUIDString:manifest.identifiers[@"idfv"]];
}

@implementation PXProfileGenerator

- (nullable PXProfileManifest *)generateManifestWithInput:(PXProfileGenerationInput *)input
                                                     error:(NSError * _Nullable * _Nullable)error {
    if (input.seed.length == 0 || input.modelCatalog.count == 0 ||
        input.iOSCatalog.count == 0 || input.carrierCatalog.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Profile generation requires a seed and non-empty catalogs"}];
        }
        return nil;
    }

    PXDeterministicRandomSource *random = [[PXDeterministicRandomSource alloc] initWithSeed:input.seed];
    NSString *generationID = [random uuidString];
    NSString *profileSeed = [input.seed base64EncodedStringWithOptions:0];
    NSMutableArray<NSDictionary<NSString *, id> *> *validModels = [NSMutableArray array];
    NSMutableArray<PXGraphicsIdentity *> *validGraphics = [NSMutableArray array];
    NSError *firstModelError = nil;
    for (NSDictionary<NSString *, id> *candidate in input.modelCatalog) {
        NSError *graphicsError = nil;
        PXGraphicsIdentity *graphicsIdentity = [PXGraphicsIdentity
            identityWithModelRecord:candidate
            profileSeed:profileSeed
            generationID:generationID
            hostCapabilities:input.graphicsHostCapabilities
            error:&graphicsError];
        NSError *compatibilityError = nil;
        BOOL isAuthoritativePhysicalModel = input.usesPhysicalDeviceModel &&
            [candidate isEqualToDictionary:input.physicalModelRecord];
        BOOL hardwareCompatible = graphicsIdentity &&
            (isAuthoritativePhysicalModel || (!input.usesPhysicalDeviceModel &&
            PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
                candidate,
                input.physicalModelRecord,
                input.graphicsHostCapabilities,
                &compatibilityError)));
        if (input.usesPhysicalDeviceModel && !isAuthoritativePhysicalModel) {
            compatibilityError = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                                      code:18
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                      @"Physical mode requires the authoritative physical model record"}];
        }
        if (hardwareCompatible) {
            [validModels addObject:candidate];
            [validGraphics addObject:graphicsIdentity];
        } else if (!firstModelError) {
            firstModelError = graphicsError ?: compatibilityError;
        }
    }
    if (validModels.count == 0) {
        if (error) {
            *error = input.modelCatalog.count == 1 && firstModelError
                ? firstModelError
                : [NSError errorWithDomain:PXProfileManifestErrorDomain
                                       code:17
                                   userInfo:@{NSLocalizedDescriptionKey:
                                       @"No selected model matches the physical hardware signature"}];
        }
        return nil;
    }
    NSUInteger selectedModelIndex = [random indexWithUpperBound:validModels.count];
    NSDictionary<NSString *, id> *device = validModels[selectedModelIndex];
    PXGraphicsIdentity *graphicsIdentity = validGraphics[selectedModelIndex];

    NSArray<NSNumber *> *supportedIOSMajors = [device[@"supportedIOSMajorVersions"] isKindOfClass:[NSArray class]]
        ? device[@"supportedIOSMajorVersions"]
        : @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *compatibleIOSTuples = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *tuple in input.iOSCatalog) {
        NSNumber *majorVersion = tuple[@"majorVersion"];
        if (supportedIOSMajors.count == 0 || [supportedIOSMajors containsObject:majorVersion]) {
            [compatibleIOSTuples addObject:tuple];
        }
    }
    if (compatibleIOSTuples.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Selected model has no compatible iOS tuple"}];
        }
        return nil;
    }
    NSDictionary<NSString *, id> *operatingSystem = compatibleIOSTuples[
        [random indexWithUpperBound:compatibleIOSTuples.count]
    ];

    NSArray<NSDictionary<NSString *, id> *> *trustedCarrierCatalog = input.trustedCarrierIDs.count > 0
        ? PXCarriersFromCatalog(input.carrierCatalog, input.trustedCarrierIDs)
        : input.carrierCatalog;
    if (trustedCarrierCatalog.count == 0) {
        trustedCarrierCatalog = input.carrierCatalog;
    }
    NSString *requestedCountryCode = input.pinnedLocation[@"countryCode"] ?: input.pinnedLocation[@"isoCountryCode"];
    NSMutableArray<NSDictionary<NSString *, id> *> *matchingCarriers = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *candidateCarrier in trustedCarrierCatalog) {
        if (requestedCountryCode.length == 0 ||
            [candidateCarrier[@"isoCountryCode"] caseInsensitiveCompare:requestedCountryCode] == NSOrderedSame) {
            [matchingCarriers addObject:candidateCarrier];
        }
    }
    NSArray<NSDictionary<NSString *, id> *> *eligibleCarriers = matchingCarriers.count > 0
        ? [matchingCarriers copy]
        : trustedCarrierCatalog;
    NSDictionary<NSString *, id> *carrier = eligibleCarriers[
        [random indexWithUpperBound:eligibleCarriers.count]
    ];
    NSString *serviceIdentifier = [NSString stringWithFormat:@"PX-%@", [random uuidString]];
    NSMutableDictionary<NSString *, id> *network = [PXBuildNetworkIdentity(
        carrier,
        [device[@"supports5G"] boolValue],
        [random indexWithUpperBound:2],
        [random indexWithUpperBound:UINT16_MAX],
        serviceIdentifier
    ) mutableCopy];
    if (input.networkType == PXEnvironmentNetworkType5GNR && ![device[@"supports5G"] boolValue]) {
        if (error) {
            *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                         code:18
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Selected model does not support the configured 5G network"}];
        }
        return nil;
    }
    NSString *configuredRadioTechnology = nil;
    switch (input.networkType) {
        case PXEnvironmentNetworkTypeWiFi:
            network[@"transport"] = @"wifi";
            break;
        case PXEnvironmentNetworkType5GNR: {
            NSArray<NSString *> *supportedTechnologies = network[@"supportedRadioTechnologies"];
            configuredRadioTechnology = [supportedTechnologies containsObject:@"CTRadioAccessTechnologyNR"]
                ? @"CTRadioAccessTechnologyNR"
                : ([supportedTechnologies containsObject:@"CTRadioAccessTechnologyNRNSA"]
                    ? @"CTRadioAccessTechnologyNRNSA"
                    : nil);
            if (!configuredRadioTechnology) {
                if (error) {
                    *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                                 code:19
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"Selected Carrier does not support the configured 5G network"}];
                }
                return nil;
            }
            network[@"transport"] = @"cellular";
            break;
        }
        case PXEnvironmentNetworkType4GLTE:
            configuredRadioTechnology = @"CTRadioAccessTechnologyLTE";
            network[@"transport"] = @"cellular";
            break;
        case PXEnvironmentNetworkType3G:
            configuredRadioTechnology = @"CTRadioAccessTechnologyWCDMA";
            network[@"transport"] = @"cellular";
            break;
        case PXEnvironmentNetworkType2G:
            configuredRadioTechnology = @"CTRadioAccessTechnologyEdge";
            network[@"transport"] = @"cellular";
            break;
        case PXEnvironmentNetworkTypeNone:
            configuredRadioTechnology = @"";
            network[@"transport"] = @"none";
            break;
        case PXEnvironmentNetworkTypeUnspecified:
            break;
    }
    if (configuredRadioTechnology) {
        network[@"radioTechnology"] = configuredRadioTechnology;
        if (configuredRadioTechnology.length > 0 &&
            ![network[@"supportedRadioTechnologies"] containsObject:configuredRadioTechnology]) {
            network[@"supportedRadioTechnologies"] =
                [network[@"supportedRadioTechnologies"] arrayByAddingObject:configuredRadioTechnology];
        }
    }
    network[@"configuredNetworkType"] = PXEnvironmentNetworkTypeIdentifier(input.networkType);
    if (input.networkType == PXEnvironmentNetworkTypeNone) {
        network[@"localIPAddress"] = @"";
        network[@"localIPv6Address"] = @"";
        network[@"ssid"] = @"";
        network[@"bssid"] = @"";
    } else {
        network[@"localIPAddress"] = [network[@"transport"] isEqualToString:@"cellular"]
            ? [NSString stringWithFormat:@"10.%lu.%lu.%lu",
                (unsigned long)(1 + [random indexWithUpperBound:254]),
                (unsigned long)(1 + [random indexWithUpperBound:254]),
                (unsigned long)(1 + [random indexWithUpperBound:254])]
            : [NSString stringWithFormat:@"192.168.%lu.%lu",
                (unsigned long)(1 + [random indexWithUpperBound:254]),
                (unsigned long)(2 + [random indexWithUpperBound:252])];
        network[@"localIPv6Address"] = [NSString stringWithFormat:@"fe80::%04llx:%04llx",
            [random nextUInt64] & 0xffff,
            [random nextUInt64] & 0xffff];
        network[@"ssid"] = [NSString stringWithFormat:@"ProjectX-%04llX", [random nextUInt64] & 0xffff];
        network[@"bssid"] = [NSString stringWithFormat:@"02:%02llX:%02llX:%02llX:%02llX:%02llX",
            [random nextUInt64] & 0xff,
            [random nextUInt64] & 0xff,
            [random nextUInt64] & 0xff,
            [random nextUInt64] & 0xff,
            [random nextUInt64] & 0xff];
    }
    network[@"cellularSignalBars"] = @(1 + [random indexWithUpperBound:5]);
    network[@"wifiSignalStrength"] = @(-20 - (NSInteger)[random indexWithUpperBound:81]);

    NSString *imeiBody = [@"353918" stringByAppendingString:[random stringWithAlphabet:@"0123456789" length:8]];
    NSInteger imeiSum = 0;
    for (NSUInteger index = 0; index < imeiBody.length; index++) {
        NSInteger digit = [imeiBody characterAtIndex:index] - '0';
        if (index % 2 == 1) {
            digit *= 2;
            if (digit > 9) digit -= 9;
        }
        imeiSum += digit;
    }
    NSString *imei = [imeiBody stringByAppendingFormat:@"%ld", (long)((10 - (imeiSum % 10)) % 10)];

    NSDictionary<NSString *, id> *identifiers = @{
        @"deviceName": device[@"name"] ?: @"iPhone",
        @"idfa": [random uuidString],
        @"idfv": [random uuidString],
        @"dyldCacheUUID": [random uuidString],
        @"pasteboardUUID": [random uuidString],
        @"keychainUUID": [random uuidString],
        @"userDefaultsUUID": [random uuidString],
        @"coreDataUUID": [random uuidString],
        @"serialNumber": [random stringWithAlphabet:@"ABCDEFGHJKLMNPQRSTUVWXYZ23456789" length:12],
        @"imei": imei,
        @"meid": [random stringWithAlphabet:@"0123456789ABCDEF" length:14]
    };

    NSString *countryCode = [carrier[@"isoCountryCode"] uppercaseString];
    NSString *requestedRegionCountry = [input.region[@"countryCode"] isKindOfClass:[NSString class]]
        ? input.region[@"countryCode"]
        : nil;
    NSDictionary<NSString *, id> *compatibleRequestedRegion =
        requestedRegionCountry.length > 0 &&
        [requestedRegionCountry caseInsensitiveCompare:countryCode] == NSOrderedSame
            ? input.region
            : @{};
    PXRegionIdentity *regionIdentity = PXRegionIdentityByCompletingPropertyList(
        compatibleRequestedRegion,
        countryCode,
        input.seed);
    if (!regionIdentity) {
        if (error) {
            *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                         code:16
                                     userInfo:@{NSLocalizedDescriptionKey: @"Selected Carrier has no valid regional identity"}];
        }
        return nil;
    }
    NSDictionary<NSString *, id> *region = [regionIdentity propertyListRepresentation];
    NSDictionary<NSString *, id> *location = [input.pinnedLocation copy] ?: @{};
    NSTimeInterval bootMetadataAge = (12 * 3600) + (NSTimeInterval)[random indexWithUpperBound:36 * 3600 + 1];
    PXVirtualRuntimeSession *virtualSession = [[PXVirtualRuntimeSession alloc]
        initWithBootUUID:[random uuidString]
        bootTime:[input.generatedAt dateByAddingTimeInterval:-bootMetadataAge]];

    NSMutableDictionary<NSString *, PXAppIdentityRecord *> *appIdentities = [NSMutableDictionary dictionary];
    for (NSString *bundleIdentifier in input.appBundleIdentifiers) {
        appIdentities[bundleIdentifier] = [PXAppIdentityRecord
            identityForProfileSeed:profileSeed
            bundleIdentifier:bundleIdentifier
            installIdentifierKeys:input.installIdentifierKeysByBundleIdentifier[bundleIdentifier]];
    }
    NSMutableDictionary<NSString *, PXAppGroupIdentityRecord *> *appGroupIdentities = [NSMutableDictionary dictionary];
    for (NSString *groupIdentifier in input.appGroupIdentifiers) {
        appGroupIdentities[groupIdentifier] = [PXAppGroupIdentityRecord
            identityForProfileSeed:profileSeed
            groupIdentifier:groupIdentifier];
    }

    PXProfileManifest *manifest = [[PXProfileManifest alloc] init];
    manifest.schemaVersion = 5;
    manifest.generationID = generationID;
    manifest.seed = [input.seed base64EncodedStringWithOptions:0];
    manifest.generatedAt = input.generatedAt;
    manifest.device = [device copy];
    manifest.operatingSystem = [operatingSystem copy];
    manifest.identifiers = identifiers;
    manifest.network = [network copy];
    manifest.region = region;
    manifest.location = location;
    manifest.graphics = [graphicsIdentity propertyListRepresentation];
    manifest.appIdentities = [appIdentities copy];
    manifest.appGroupIdentities = [appGroupIdentities copy];
    manifest.fieldSourcePolicy = PXProfileFieldSourcePolicy();
    manifest.virtualSession = virtualSession;
    return manifest;
}

@end

@interface PXProfileStore ()

@property (nonatomic, copy) NSString *identityDirectory;

@end


@implementation PXProfileStore

- (instancetype)initWithIdentityDirectory:(NSString *)identityDirectory {
    self = [super init];
    if (self) {
        _identityDirectory = [identityDirectory copy];
    }
    return self;
}

- (NSArray<NSString *> *)projectionFileNames {
    return @[
        @"profile_manifest.plist",
        @"device_model.plist",
        @"ios_version.plist",
        @"device_ids.plist",
        @"wifi_info.plist",
        @"advertising_id.plist",
        @"vendor_id.plist",
        @"device_name.plist",
        @"serial_number.plist",
        @"imei.plist",
        @"meid.plist",
        @"system_boot_uuid.plist",
        @"dyld_cache_uuid.plist",
        @"pasteboard_uuid.plist",
        @"keychain_uuid.plist",
        @"userdefaults_uuid.plist",
        @"coredata_uuid.plist",
        @"network_settings.plist",
        @"carrier_details.plist",
        @"region.plist",
        @"location.plist"
    ];
}

- (NSArray<NSString *> *)retiredAppIdentityProjectionFileNames {
    return @[@"appgroup_uuid.plist", @"appinstall_uuid.plist", @"appcontainer_uuid.plist"];
}

- (void)removeRetiredAppIdentityProjections {
    for (NSString *fileName in [self retiredAppIdentityProjectionFileNames]) {
        NSString *retiredPath = [self.identityDirectory stringByAppendingPathComponent:fileName];
        struct stat pathInfo;
        if (lstat(retiredPath.fileSystemRepresentation, &pathInfo) == 0 && !S_ISDIR(pathInfo.st_mode)) {
            unlink(retiredPath.fileSystemRepresentation);
        }
    }
}

- (NSArray<NSString *> *)legacyProjectionFileNames {
    return [[self projectionFileNames] arrayByAddingObjectsFromArray:[self retiredAppIdentityProjectionFileNames]];
}

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)projectionsForManifest:(PXProfileManifest *)manifest {
    NSString *generationID = manifest.generationID;
    NSDate *generatedAt = manifest.generatedAt;
    NSMutableDictionary *deviceModel = [manifest.device mutableCopy];
    deviceModel[@"value"] = manifest.device[@"identifier"] ?: @"";
    deviceModel[@"generationID"] = generationID;
    deviceModel[@"lastUpdated"] = generatedAt;

    NSMutableDictionary *operatingSystem = [manifest.operatingSystem mutableCopy];
    operatingSystem[@"generationID"] = generationID;
    operatingSystem[@"lastUpdated"] = generatedAt;

    NSMutableDictionary *network = [manifest.network mutableCopy];
    network[@"generationID"] = generationID;
    network[@"lastUpdated"] = generatedAt;

    NSMutableDictionary *deviceIds = [NSMutableDictionary dictionary];
    deviceIds[@"generationID"] = generationID;
    deviceIds[@"DeviceModel"] = manifest.device[@"identifier"] ?: @"";
    deviceIds[@"DeviceModelName"] = manifest.device[@"name"] ?: @"";
    deviceIds[@"DeviceName"] = manifest.identifiers[@"deviceName"] ?: manifest.device[@"name"] ?: @"";
    deviceIds[@"BoardID"] = manifest.device[@"boardID"] ?: @"";
    deviceIds[@"HwModel"] = manifest.device[@"hwModel"] ?: @"";
    deviceIds[@"ScreenResolution"] = manifest.device[@"screenResolution"] ?: @"";
    deviceIds[@"ViewportResolution"] = manifest.device[@"viewportResolution"] ?: @"";
    deviceIds[@"DevicePixelRatio"] = manifest.device[@"devicePixelRatio"] ?: @0;
    deviceIds[@"ScreenDensityPPI"] = manifest.device[@"screenDensity"] ?: @0;
    deviceIds[@"CPUArchitecture"] = manifest.device[@"cpuArchitecture"] ?: @"";
    deviceIds[@"CPUCoreCount"] = manifest.device[@"cpuCoreCount"] ?: @0;
    deviceIds[@"DeviceMemory"] = manifest.device[@"deviceMemory"] ?: @0;
    deviceIds[@"GPUFamily"] = manifest.device[@"gpuFamily"] ?: @"";
    deviceIds[@"MetalFeatureSet"] = manifest.device[@"metalFeatureSet"] ?: @"";
    deviceIds[@"GraphicsGenerationID"] = manifest.graphics[@"generationID"] ?: @"";
    deviceIds[@"GPUName"] = manifest.graphics[@"gpuName"] ?: @"";
    deviceIds[@"MetalFamilies"] = manifest.graphics[@"metalFamilies"] ?: @[];
    deviceIds[@"MetalFeatureSets"] = manifest.graphics[@"metalFeatureSets"] ?: @[];
    deviceIds[@"WebGLInfo"] = manifest.graphics[@"webGL"] ?: @{};
    deviceIds[@"OpenGLInfo"] = manifest.graphics[@"openGL"] ?: @{};
    deviceIds[@"CanvasNoiseSeed"] = manifest.graphics[@"canvasNoiseSeed"] ?: @0;
    deviceIds[@"IOSVersion"] = manifest.operatingSystem[@"version"] ?: @"";
    deviceIds[@"IOSBuild"] = manifest.operatingSystem[@"build"] ?: @"";
    deviceIds[@"IDFA"] = manifest.identifiers[@"idfa"] ?: @"";
    deviceIds[@"IDFV"] = manifest.identifiers[@"idfv"] ?: @"";
    deviceIds[@"SerialNumber"] = manifest.identifiers[@"serialNumber"] ?: @"";
    deviceIds[@"IMEI"] = manifest.identifiers[@"imei"] ?: @"";
    deviceIds[@"MEID"] = manifest.identifiers[@"meid"] ?: @"";
    deviceIds[@"SystemBootUUID"] = manifest.virtualSession.bootUUID;
    deviceIds[@"DyldCacheUUID"] = manifest.identifiers[@"dyldCacheUUID"] ?: @"";
    deviceIds[@"PasteboardUUID"] = manifest.identifiers[@"pasteboardUUID"] ?: @"";
    deviceIds[@"KeychainUUID"] = manifest.identifiers[@"keychainUUID"] ?: @"";
    deviceIds[@"UserDefaultsUUID"] = manifest.identifiers[@"userDefaultsUUID"] ?: @"";
    deviceIds[@"CoreDataUUID"] = manifest.identifiers[@"coreDataUUID"] ?: @"";
    deviceIds[@"CarrierName"] = manifest.network[@"carrierName"] ?: @"";
    deviceIds[@"CarrierID"] = manifest.network[@"carrierID"] ?: @"";
    deviceIds[@"CarrierMCC"] = manifest.network[@"mcc"] ?: @"";
    deviceIds[@"CarrierMNC"] = manifest.network[@"mnc"] ?: @"";
    deviceIds[@"CarrierISOCountryCode"] = manifest.network[@"isoCountryCode"] ?: @"";
    deviceIds[@"RadioAccessTechnology"] = manifest.network[@"radioTechnology"] ?: @"";
    deviceIds[@"NetworkTransport"] = manifest.network[@"transport"] ?: @"";
    deviceIds[@"CellularServiceIdentifier"] = manifest.network[@"serviceIdentifier"] ?: @"";
    deviceIds[@"LocalIPAddress"] = manifest.network[@"localIPAddress"] ?: @"";
    deviceIds[@"LocalIPv6Address"] = manifest.network[@"localIPv6Address"] ?: @"";
    deviceIds[@"SSID"] = manifest.network[@"ssid"] ?: @"";
    deviceIds[@"BSSID"] = manifest.network[@"bssid"] ?: @"";
    deviceIds[@"LastUpdated"] = generatedAt;

    NSDictionary *carrierDetails = @{
        @"generationID": generationID,
        @"carrierID": manifest.network[@"carrierID"] ?: @"",
        @"carrierName": manifest.network[@"carrierName"] ?: @"",
        @"mcc": manifest.network[@"mcc"] ?: @"",
        @"mnc": manifest.network[@"mnc"] ?: @"",
        @"country": manifest.network[@"country"] ?: @"",
        @"isoCountryCode": manifest.network[@"isoCountryCode"] ?: @"",
        @"radioTechnology": manifest.network[@"radioTechnology"] ?: @"",
        @"transport": manifest.network[@"transport"] ?: @"",
        @"serviceIdentifier": manifest.network[@"serviceIdentifier"] ?: @"",
        @"allowsVOIP": manifest.network[@"allowsVOIP"] ?: @YES,
        @"lastUpdated": generatedAt
    };

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *projections = [@{
        @"profile_manifest.plist": [manifest propertyListRepresentation],
        @"device_model.plist": [deviceModel copy],
        @"ios_version.plist": [operatingSystem copy],
        @"device_ids.plist": [deviceIds copy],
        @"wifi_info.plist": @{
            @"generationID": generationID,
            @"ssid": manifest.network[@"ssid"] ?: @"",
            @"bssid": manifest.network[@"bssid"] ?: @"",
            @"networkType": @"Infrastructure",
            @"wifiStandard": @"802.11ax",
            @"autoJoin": @YES,
            @"lastConnectionTime": generatedAt
        },
        @"system_boot_uuid.plist": @{
            @"generationID": generationID,
            @"value": manifest.virtualSession.bootUUID,
            @"lastUpdated": generatedAt
        },
        @"network_settings.plist": [network copy],
        @"carrier_details.plist": carrierDetails,
        @"region.plist": @{
            @"generationID": generationID,
            @"value": manifest.region,
            @"lastUpdated": generatedAt
        },
        @"location.plist": @{
            @"generationID": generationID,
            @"value": manifest.location,
            @"lastUpdated": generatedAt
        }
    } mutableCopy];

    NSDictionary<NSString *, NSString *> *identifierProjectionKeys = @{
        @"advertising_id.plist": @"idfa",
        @"vendor_id.plist": @"idfv",
        @"device_name.plist": @"deviceName",
        @"serial_number.plist": @"serialNumber",
        @"imei.plist": @"imei",
        @"meid.plist": @"meid",
        @"dyld_cache_uuid.plist": @"dyldCacheUUID",
        @"pasteboard_uuid.plist": @"pasteboardUUID",
        @"keychain_uuid.plist": @"keychainUUID",
        @"userdefaults_uuid.plist": @"userDefaultsUUID",
        @"coredata_uuid.plist": @"coreDataUUID"
    };
    for (NSString *fileName in identifierProjectionKeys) {
        NSString *identifierKey = identifierProjectionKeys[fileName];
        NSString *value = [identifierKey isEqualToString:@"deviceName"]
            ? (manifest.identifiers[@"deviceName"] ?: manifest.device[@"name"])
            : manifest.identifiers[identifierKey];
        projections[fileName] = @{
            @"generationID": generationID,
            @"value": value ?: @"",
            @"lastUpdated": generatedAt
        };
    }
    return [projections copy];
}

- (BOOL)pathExistsWithoutFollowingSymlinks:(NSString *)path isSymlink:(BOOL *)isSymlink {
    struct stat fileStatus;
    if (lstat(path.fileSystemRepresentation, &fileStatus) != 0) {
        if (isSymlink) *isSymlink = NO;
        return NO;
    }
    if (isSymlink) *isSymlink = S_ISLNK(fileStatus.st_mode);
    return YES;
}

- (BOOL)failWithError:(NSError * _Nullable * _Nullable)error code:(NSInteger)code reason:(NSString *)reason {
    if (error) {
        *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

- (BOOL)promoteManifest:(PXProfileManifest *)manifest error:(NSError * _Nullable * _Nullable)error {
    @synchronized([PXProfileStore class]) {
        return [self performPromotionOfManifest:manifest error:error];
    }
}

- (BOOL)performPromotionOfManifest:(PXProfileManifest *)manifest error:(NSError * _Nullable * _Nullable)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtPath:self.identityDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:error]) {
        return NO;
    }

    NSString *lockPath = [self.identityDirectory stringByAppendingPathComponent:@".profile-generation.lock"];
    int lockDescriptor = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (lockDescriptor < 0) {
        return [self failWithError:error code:11 reason:@"Failed to open Profile generation lock"];
    }
    if (flock(lockDescriptor, LOCK_EX) != 0) {
        close(lockDescriptor);
        return [self failWithError:error code:12 reason:@"Failed to acquire Profile generation lock"];
    }

    BOOL promoted = [self performLockedPromotionOfManifest:manifest error:error];
    flock(lockDescriptor, LOCK_UN);
    close(lockDescriptor);
    return promoted;
}

- (BOOL)performLockedPromotionOfManifest:(PXProfileManifest *)manifest error:(NSError * _Nullable * _Nullable)error {
    NSError *validationError = nil;
    if (![manifest validateWithError:&validationError]) {
        if (error) *error = validationError;
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtPath:self.identityDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:error]) {
        return NO;
    }
    NSString *generationsDirectory = [self.identityDirectory stringByAppendingPathComponent:@"profile_generations"];
    if (![fileManager createDirectoryAtPath:generationsDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:error]) {
        return NO;
    }

    NSString *stagingDirectory = [self.identityDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".profile-staging-%@", NSUUID.UUID.UUIDString]];
    if (![fileManager createDirectoryAtPath:stagingDirectory
                withIntermediateDirectories:NO
                                 attributes:nil
                                      error:error]) {
        return NO;
    }

    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *projections = [self projectionsForManifest:manifest];
    for (NSString *fileName in [self projectionFileNames]) {
        NSString *stagedPath = [stagingDirectory stringByAppendingPathComponent:fileName];
        if (![projections[fileName] writeToFile:stagedPath atomically:YES]) {
            [fileManager removeItemAtPath:stagingDirectory error:nil];
            return [self failWithError:error code:5 reason:[NSString stringWithFormat:@"Failed to stage %@", fileName]];
        }
    }

    if (self.failBeforePromotionForTesting) {
        [fileManager removeItemAtPath:stagingDirectory error:nil];
        return [self failWithError:error code:6 reason:@"Injected failure before Profile promotion"];
    }

    NSString *generationDirectory = [generationsDirectory stringByAppendingPathComponent:manifest.generationID];
    BOOL generationDirectoryIsSymlink = NO;
    BOOL generationDirectoryExists = [self pathExistsWithoutFollowingSymlinks:generationDirectory
                                                                     isSymlink:&generationDirectoryIsSymlink];
    if (generationDirectoryExists) {
        BOOL generationDirectoryIsDirectory = NO;
        [fileManager fileExistsAtPath:generationDirectory
                          isDirectory:&generationDirectoryIsDirectory];
        BOOL existingGenerationMatches = generationDirectoryIsDirectory &&
            !generationDirectoryIsSymlink;
        for (NSString *fileName in [self projectionFileNames]) {
            if (!existingGenerationMatches) {
                break;
            }
            NSDictionary<NSString *, id> *existingProjection = [NSDictionary
                dictionaryWithContentsOfFile:[generationDirectory
                    stringByAppendingPathComponent:fileName]];
            existingGenerationMatches = [existingProjection
                isEqualToDictionary:projections[fileName]];
        }
        [fileManager removeItemAtPath:stagingDirectory error:nil];
        if (!existingGenerationMatches) {
            return [self failWithError:error
                                  code:14
                                reason:@"Generation identifier already exists with different materialized values"];
        }
    } else if (![fileManager moveItemAtPath:stagingDirectory toPath:generationDirectory error:error]) {
        [fileManager removeItemAtPath:stagingDirectory error:nil];
        return NO;
    }

    NSMutableArray<NSString *> *createdProjectionLinks = [NSMutableArray array];
    for (NSString *fileName in [self projectionFileNames]) {
        NSString *projectionPath = [self.identityDirectory stringByAppendingPathComponent:fileName];
        BOOL isSymlink = NO;
        if ([self pathExistsWithoutFollowingSymlinks:projectionPath isSymlink:&isSymlink]) {
            if (!isSymlink) {
                for (NSString *createdPath in createdProjectionLinks) unlink(createdPath.fileSystemRepresentation);
                return [self failWithError:error code:7 reason:@"Legacy projections must be migrated before regeneration"];
            }
            continue;
        }

        NSString *target = [@"profile_active" stringByAppendingPathComponent:fileName];
        if (symlink(target.fileSystemRepresentation, projectionPath.fileSystemRepresentation) != 0) {
            for (NSString *createdPath in createdProjectionLinks) unlink(createdPath.fileSystemRepresentation);
            return [self failWithError:error code:8 reason:[NSString stringWithFormat:@"Failed to link %@", fileName]];
        }
        [createdProjectionLinks addObject:projectionPath];
    }

    NSString *activePath = [self.identityDirectory stringByAppendingPathComponent:@"profile_active"];
    NSString *temporaryActivePath = [self.identityDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".profile-active-%@", NSUUID.UUID.UUIDString]];
    NSString *activeTarget = [@"profile_generations" stringByAppendingPathComponent:manifest.generationID];
    if (symlink(activeTarget.fileSystemRepresentation, temporaryActivePath.fileSystemRepresentation) != 0 ||
        rename(temporaryActivePath.fileSystemRepresentation, activePath.fileSystemRepresentation) != 0) {
        unlink(temporaryActivePath.fileSystemRepresentation);
        for (NSString *createdPath in createdProjectionLinks) unlink(createdPath.fileSystemRepresentation);
        return [self failWithError:error code:9 reason:@"Failed to atomically activate Profile generation"];
    }
    [self removeRetiredAppIdentityProjections];
    return YES;
}

- (nullable NSString *)activeGenerationIDWithError:(NSError * _Nullable * _Nullable)error {
    NSString *activePath = [self.identityDirectory stringByAppendingPathComponent:@"profile_active"];
    BOOL isSymlink = NO;
    if (![self pathExistsWithoutFollowingSymlinks:activePath isSymlink:&isSymlink] || !isSymlink) {
        [self failWithError:error code:15 reason:@"Active Profile generation link is missing or invalid"];
        return nil;
    }

    NSError *linkError = nil;
    NSString *target = [[NSFileManager defaultManager]
        destinationOfSymbolicLinkAtPath:activePath
        error:&linkError];
    NSArray<NSString *> *components = target.pathComponents;
    NSString *generationID = components.count == 2 ? components.lastObject : nil;
    if (linkError || ![components.firstObject isEqualToString:@"profile_generations"] ||
        ![[NSUUID alloc] initWithUUIDString:generationID]) {
        [self failWithError:error code:15 reason:@"Active Profile generation link target is invalid"];
        return nil;
    }

    NSString *generationDirectory = [[self.identityDirectory
        stringByAppendingPathComponent:@"profile_generations"]
        stringByAppendingPathComponent:generationID];
    struct stat generationStatus;
    if (lstat(generationDirectory.fileSystemRepresentation, &generationStatus) != 0 ||
        !S_ISDIR(generationStatus.st_mode) || S_ISLNK(generationStatus.st_mode)) {
        [self failWithError:error code:15 reason:@"Active Profile generation directory is invalid"];
        return nil;
    }
    return generationID;
}

- (nullable PXProfileManifest *)activeManifestWithError:(NSError * _Nullable * _Nullable)error {
    NSString *manifestPath = [self.identityDirectory stringByAppendingPathComponent:@"profile_manifest.plist"];
    NSDictionary *propertyList = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    PXProfileManifest *manifest = [PXProfileManifest manifestWithPropertyList:propertyList error:error];
    if (!manifest) {
        return nil;
    }

    for (NSString *fileName in [self projectionFileNames]) {
        if ([fileName isEqualToString:@"profile_manifest.plist"]) continue;
        NSString *projectionPath = [self.identityDirectory stringByAppendingPathComponent:fileName];
        NSDictionary *projection = [NSDictionary dictionaryWithContentsOfFile:projectionPath];
        if (![projection[@"generationID"] isEqualToString:manifest.generationID]) {
            [self failWithError:error code:10 reason:[NSString stringWithFormat:@"Mixed or corrupt projection: %@", fileName]];
            return nil;
        }
    }
    return manifest;
}

- (nullable NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)activeApplicationIdentityPropertyListsWithError:(NSError * _Nullable * _Nullable)error {
    PXProfileManifest *manifest = [self activeManifestWithError:error];
    return manifest ? PXAppIdentityPropertyLists(manifest.appIdentities) : nil;
}

- (BOOL)replaceActiveApplicationIdentityPropertyLists:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)appIdentities
                                                 error:(NSError * _Nullable * _Nullable)error {
    if (![appIdentities isKindOfClass:[NSDictionary class]]) {
        return [self failWithError:error code:13 reason:@"Application identity map is invalid"];
    }
    NSMutableDictionary<NSString *, PXAppIdentityRecord *> *validatedIdentities =
        [NSMutableDictionary dictionaryWithCapacity:appIdentities.count];
    for (id bundleIdentifier in appIdentities) {
        NSDictionary<NSString *, id> *propertyList = appIdentities[bundleIdentifier];
        PXAppIdentityRecord *identity =
            [propertyList isKindOfClass:[NSDictionary class]]
                ? [PXAppIdentityRecord identityWithPropertyList:propertyList]
                : nil;
        if (![bundleIdentifier isKindOfClass:[NSString class]] ||
            !PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO) || !identity) {
            return [self failWithError:error code:13 reason:@"Application identity map is invalid"];
        }
        validatedIdentities[bundleIdentifier] = identity;
    }
    if (![self migrateLegacyProfileIfNeededWithError:error]) {
        return NO;
    }
    @synchronized([PXProfileStore class]) {
        NSString *lockPath = [self.identityDirectory stringByAppendingPathComponent:@".profile-generation.lock"];
        int lockDescriptor = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
        if (lockDescriptor < 0) {
            return [self failWithError:error code:11 reason:@"Failed to open Profile generation lock"];
        }
        if (flock(lockDescriptor, LOCK_EX) != 0) {
            close(lockDescriptor);
            return [self failWithError:error code:12 reason:@"Failed to acquire Profile generation lock"];
        }

        PXProfileManifest *activeManifest = [self activeManifestWithError:error];
        NSMutableDictionary<NSString *, id> *updatedPropertyList =
            [[activeManifest propertyListRepresentation] mutableCopy];
        updatedPropertyList[@"appIdentities"] = PXAppIdentityPropertyLists(validatedIdentities);
        PXProfileManifest *updatedManifest = activeManifest
            ? [PXProfileManifest manifestWithPropertyList:updatedPropertyList error:error]
            : nil;
        NSString *manifestPath = [[self.identityDirectory stringByAppendingPathComponent:@"profile_manifest.plist"]
            stringByResolvingSymlinksInPath];
        BOOL success = updatedManifest && [updatedPropertyList writeToFile:manifestPath atomically:YES];
        if (!success && updatedManifest) {
            [self failWithError:error code:14 reason:@"Failed to persist application identity mapping"];
        }
        flock(lockDescriptor, LOCK_UN);
        close(lockDescriptor);
        return success;
    }
}

- (BOOL)ensureApplicationIdentityForBundleIdentifier:(NSString *)bundleIdentifier
                                     groupIdentifiers:(NSSet<NSString *> *)groupIdentifiers
                                installIdentifierKeys:(NSSet<NSString *> *)installIdentifierKeys
                                                 error:(NSError * _Nullable * _Nullable)error {
    if (bundleIdentifier.length == 0) {
        return [self failWithError:error code:13 reason:@"Application identity requires a bundle identifier"];
    }
    if (![self migrateLegacyProfileIfNeededWithError:error]) {
        return NO;
    }
    @synchronized([PXProfileStore class]) {
        NSString *lockPath = [self.identityDirectory stringByAppendingPathComponent:@".profile-generation.lock"];
        int lockDescriptor = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
        if (lockDescriptor < 0) {
            return [self failWithError:error code:11 reason:@"Failed to open Profile generation lock"];
        }
        if (flock(lockDescriptor, LOCK_EX) != 0) {
            close(lockDescriptor);
            return [self failWithError:error code:12 reason:@"Failed to acquire Profile generation lock"];
        }

        PXProfileManifest *activeManifest = [self activeManifestWithError:error];
        if (!activeManifest) {
            flock(lockDescriptor, LOCK_UN);
            close(lockDescriptor);
            return NO;
        }
        NSMutableDictionary<NSString *, PXAppIdentityRecord *> *appIdentities =
            [activeManifest.appIdentities mutableCopy];
        PXAppIdentityRecord *appIdentity = appIdentities[bundleIdentifier];
        BOOL changed = NO;
        if (!appIdentity) {
            appIdentity = [PXAppIdentityRecord identityForProfileSeed:activeManifest.seed
                                                      bundleIdentifier:bundleIdentifier
                                                  installIdentifierKeys:installIdentifierKeys];
            appIdentities[bundleIdentifier] = appIdentity;
            changed = YES;
        } else {
            NSMutableSet<NSString *> *mergedInstallKeys = [appIdentity.installIdentifierKeys mutableCopy];
            [mergedInstallKeys unionSet:installIdentifierKeys];
            if (![mergedInstallKeys isEqualToSet:appIdentity.installIdentifierKeys]) {
                NSMutableDictionary<NSString *, id> *identityPropertyList =
                    [[appIdentity propertyListRepresentation] mutableCopy];
                identityPropertyList[@"installIdentifierKeys"] =
                    [mergedInstallKeys.allObjects sortedArrayUsingSelector:@selector(compare:)];
                appIdentities[bundleIdentifier] = [PXAppIdentityRecord identityWithPropertyList:identityPropertyList];
                changed = YES;
            }
        }

        NSMutableDictionary<NSString *, PXAppGroupIdentityRecord *> *appGroupIdentities =
            [activeManifest.appGroupIdentities mutableCopy];
        for (NSString *groupIdentifier in groupIdentifiers) {
            if (groupIdentifier.length == 0 || appGroupIdentities[groupIdentifier]) {
                continue;
            }
            appGroupIdentities[groupIdentifier] = [PXAppGroupIdentityRecord
                identityForProfileSeed:activeManifest.seed
                groupIdentifier:groupIdentifier];
            changed = YES;
        }
        if (!changed) {
            flock(lockDescriptor, LOCK_UN);
            close(lockDescriptor);
            return YES;
        }

        NSMutableDictionary<NSString *, id> *updatedPropertyList =
            [[activeManifest propertyListRepresentation] mutableCopy];
        updatedPropertyList[@"appIdentities"] = PXAppIdentityPropertyLists(appIdentities);
        updatedPropertyList[@"appGroupIdentities"] = PXAppGroupIdentityPropertyLists(appGroupIdentities);
        PXProfileManifest *updatedManifest = [PXProfileManifest manifestWithPropertyList:updatedPropertyList error:error];
        NSString *manifestPath = [[self.identityDirectory stringByAppendingPathComponent:@"profile_manifest.plist"]
            stringByResolvingSymlinksInPath];
        BOOL success = updatedManifest && [updatedPropertyList writeToFile:manifestPath atomically:YES];
        if (!success && updatedManifest) {
            [self failWithError:error code:14 reason:@"Failed to persist application identity mapping"];
        }
        flock(lockDescriptor, LOCK_UN);
        close(lockDescriptor);
        return success;
    }
}

- (BOOL)migrateLegacyProfileIfNeededWithError:(NSError * _Nullable * _Nullable)error {
    @synchronized([PXProfileStore class]) {
        NSString *activePath = [self.identityDirectory stringByAppendingPathComponent:@"profile_active"];
        BOOL isSymlink = NO;
        if ([self pathExistsWithoutFollowingSymlinks:activePath isSymlink:&isSymlink] && isSymlink) {
            NSString *manifestPath = [[self.identityDirectory stringByAppendingPathComponent:@"profile_manifest.plist"]
                stringByResolvingSymlinksInPath];
            NSDictionary<NSString *, id> *storedPropertyList =
                [NSDictionary dictionaryWithContentsOfFile:manifestPath];
            if ([storedPropertyList[@"schemaVersion"] integerValue] == 3 ||
                [storedPropertyList[@"schemaVersion"] integerValue] == 4) {
                PXProfileManifest *migratedManifest = [PXProfileManifest
                    manifestWithPropertyList:storedPropertyList
                    error:error];
                NSString *regionProjectionPath = [[self.identityDirectory
                    stringByAppendingPathComponent:@"region.plist"] stringByResolvingSymlinksInPath];
                NSDictionary<NSString *, id> *regionProjection = migratedManifest ? @{
                    @"generationID": migratedManifest.generationID,
                    @"value": migratedManifest.region,
                    @"lastUpdated": migratedManifest.generatedAt
                } : nil;
                BOOL persistedRegionProjection = migratedManifest &&
                    [regionProjection writeToFile:regionProjectionPath atomically:YES];
                BOOL persistedManifest = persistedRegionProjection &&
                    [[migratedManifest propertyListRepresentation] writeToFile:manifestPath atomically:YES];
                if (!persistedManifest) {
                    if (migratedManifest) {
                        [self failWithError:error code:15 reason:@"Failed to persist Profile schema migration"];
                    }
                    return NO;
                }
            }
            [self removeRetiredAppIdentityProjections];
            return YES;
        }

        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *legacyFiles = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *emptyLegacyProjectionPaths = [NSMutableArray array];
        for (NSString *fileName in [self legacyProjectionFileNames]) {
            if ([fileName isEqualToString:@"profile_manifest.plist"]) {
                continue;
            }
            NSString *path = [self.identityDirectory stringByAppendingPathComponent:fileName];
            NSDictionary *propertyList = [NSDictionary dictionaryWithContentsOfFile:path];
            if ([propertyList isKindOfClass:[NSDictionary class]]) {
                if (propertyList.count > 0) {
                    legacyFiles[fileName] = propertyList;
                } else {
                    [emptyLegacyProjectionPaths addObject:path];
                }
            }
        }
        if (legacyFiles.count == 0) {
            for (NSString *emptyLegacyProjectionPath in emptyLegacyProjectionPaths) {
                if (![fileManager removeItemAtPath:emptyLegacyProjectionPath error:error]) {
                    return NO;
                }
            }
            return YES;
        }

        NSError *serializationError = nil;
        NSData *legacySeed = [NSPropertyListSerialization dataWithPropertyList:legacyFiles
                                                                        format:NSPropertyListBinaryFormat_v1_0
                                                                       options:0
                                                                         error:&serializationError];
        if (!legacySeed) {
            if (error) *error = serializationError;
            return NO;
        }
        PXDeterministicRandomSource *random = [[PXDeterministicRandomSource alloc] initWithSeed:legacySeed];

        NSMutableDictionary *device = [legacyFiles[@"device_model.plist"] mutableCopy] ?: [NSMutableDictionary dictionary];
        device[@"identifier"] = device[@"identifier"] ?: device[@"value"] ?: @"";
        NSMutableDictionary *operatingSystem = [legacyFiles[@"ios_version.plist"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSNumber *majorVersion = operatingSystem[@"majorVersion"];
        if (!majorVersion && [operatingSystem[@"version"] isKindOfClass:[NSString class]]) {
            majorVersion = @([[operatingSystem[@"version"] componentsSeparatedByString:@"."].firstObject integerValue]);
        }
        if (!device[@"supportedIOSMajorVersions"] && majorVersion) {
            device[@"supportedIOSMajorVersions"] = @[majorVersion];
        }
        if (majorVersion) {
            operatingSystem[@"majorVersion"] = majorVersion;
        }

        NSMutableDictionary *network = [legacyFiles[@"network_settings.plist"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSDictionary *legacyCarrier = legacyFiles[@"carrier_details.plist"] ?: @{};
        NSDictionary *legacyWiFi = legacyFiles[@"wifi_info.plist"] ?: @{};
        [legacyCarrier enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            (void)stop;
            if (!network[key] && value) network[key] = value;
        }];
        NSString *radioTechnology = network[@"radioTechnology"] ?: network[@"radioAccessTechnology"] ?: @"CTRadioAccessTechnologyLTE";
        network[@"radioTechnology"] = radioTechnology;
        network[@"supportedRadioTechnologies"] = network[@"supportedRadioTechnologies"] ?: @[radioTechnology];
        network[@"transport"] = network[@"transport"] ?: @"cellular";
        network[@"serviceIdentifier"] = network[@"serviceIdentifier"] ?: [NSString stringWithFormat:@"PX-%@", [random uuidString]];
        network[@"ssid"] = network[@"ssid"] ?: legacyWiFi[@"ssid"] ?: @"";
        network[@"bssid"] = network[@"bssid"] ?: legacyWiFi[@"bssid"] ?: @"";
        if ([network[@"carrierID"] length] == 0) {
            for (NSDictionary<NSString *, id> *catalogCarrier in PXCarrierCatalog()) {
                if ([catalogCarrier[@"name"] isEqualToString:network[@"carrierName"]] &&
                    [catalogCarrier[@"mcc"] isEqualToString:network[@"mcc"]] &&
                    [catalogCarrier[@"mnc"] isEqualToString:network[@"mnc"]]) {
                    network[@"carrierID"] = catalogCarrier[@"carrierID"];
                    break;
                }
            }
        }
        if (!device[@"supports5G"]) {
            device[@"supports5G"] = @(![radioTechnology isEqualToString:@"CTRadioAccessTechnologyLTE"]);
        }

        NSDictionary *legacyIdentifiers = legacyFiles[@"device_ids.plist"] ?: @{};
        NSDictionary<NSString *, NSString *> *legacyIdentifierFiles = @{
            @"IDFA": @"advertising_id.plist",
            @"IDFV": @"vendor_id.plist",
            @"DyldCacheUUID": @"dyld_cache_uuid.plist",
            @"PasteboardUUID": @"pasteboard_uuid.plist",
            @"KeychainUUID": @"keychain_uuid.plist",
            @"UserDefaultsUUID": @"userdefaults_uuid.plist",
            @"CoreDataUUID": @"coredata_uuid.plist"
        };
        NSString *(^identifierOrFallback)(NSString *) = ^NSString *(NSString *legacyKey) {
            NSString *value = legacyIdentifiers[legacyKey];
            if (!value) {
                value = legacyFiles[legacyIdentifierFiles[legacyKey]][@"value"];
            }
            if ([[NSUUID alloc] initWithUUIDString:value]) {
                return value;
            }
            return [random uuidString];
        };
        NSDictionary *identifiers = @{
            @"deviceName": legacyIdentifiers[@"DeviceName"] ?: legacyFiles[@"device_name.plist"][@"value"] ?: device[@"name"] ?: @"",
            @"idfa": identifierOrFallback(@"IDFA"),
            @"idfv": identifierOrFallback(@"IDFV"),
            @"dyldCacheUUID": identifierOrFallback(@"DyldCacheUUID"),
            @"pasteboardUUID": identifierOrFallback(@"PasteboardUUID"),
            @"keychainUUID": identifierOrFallback(@"KeychainUUID"),
            @"userDefaultsUUID": identifierOrFallback(@"UserDefaultsUUID"),
            @"coreDataUUID": identifierOrFallback(@"CoreDataUUID"),
            @"serialNumber": legacyIdentifiers[@"SerialNumber"] ?: legacyFiles[@"serial_number.plist"][@"value"] ?: @"",
            @"imei": legacyIdentifiers[@"IMEI"] ?: legacyFiles[@"imei.plist"][@"value"] ?: @"",
            @"meid": legacyIdentifiers[@"MEID"] ?: legacyFiles[@"meid.plist"][@"value"] ?: @""
        };

        NSString *legacyBootUUID = legacyIdentifiers[@"SystemBootUUID"] ?: legacyFiles[@"system_boot_uuid.plist"][@"value"];
        if (![[NSUUID alloc] initWithUUIDString:legacyBootUUID]) {
            legacyBootUUID = [random uuidString];
        }
        NSDictionary *legacyBootTime = legacyFiles[@"boot_time.plist"] ?: @{};
        NSDate *bootTime = [legacyBootTime[@"value"] isKindOfClass:[NSDate class]]
            ? legacyBootTime[@"value"]
            : nil;
        if (!bootTime && [legacyIdentifiers[@"BootTime"] doubleValue] > 0) {
            bootTime = [NSDate dateWithTimeIntervalSince1970:[legacyIdentifiers[@"BootTime"] doubleValue]];
        }
        NSDate *referenceDate = [legacyBootTime[@"lastUpdated"] isKindOfClass:[NSDate class]]
            ? legacyBootTime[@"lastUpdated"]
            : nil;
        if (!bootTime) {
            referenceDate = [NSDate dateWithTimeIntervalSince1970:0];
            NSTimeInterval bootMetadataAge = (12 * 3600) + (NSTimeInterval)[random indexWithUpperBound:36 * 3600 + 1];
            bootTime = [referenceDate dateByAddingTimeInterval:-bootMetadataAge];
        } else if (!referenceDate || [referenceDate timeIntervalSinceDate:bootTime] < 12 * 3600 ||
                   [referenceDate timeIntervalSinceDate:bootTime] > 48 * 3600) {
            referenceDate = [bootTime dateByAddingTimeInterval:12 * 3600];
        }
        PXVirtualRuntimeSession *virtualSession = [[PXVirtualRuntimeSession alloc]
            initWithBootUUID:legacyBootUUID
            bootTime:bootTime];
        NSDictionary *legacyLocation = legacyFiles[@"location.plist"] ?: @{};
        NSDictionary *location = [legacyLocation[@"value"] isKindOfClass:[NSDictionary class]]
            ? legacyLocation[@"value"]
            : legacyLocation;

        PXProfileManifest *manifest = [[PXProfileManifest alloc] init];
        manifest.schemaVersion = 5;
        manifest.generationID = [random uuidString];
        manifest.seed = [legacySeed base64EncodedStringWithOptions:0];
        manifest.generatedAt = referenceDate;
        manifest.device = [device copy];
        manifest.operatingSystem = [operatingSystem copy];
        manifest.identifiers = identifiers;
        manifest.network = [network copy];
        NSDictionary *legacyRegion = legacyFiles[@"region.plist"] ?: @{};
        NSDictionary *legacyRegionValue = [legacyRegion[@"value"] isKindOfClass:[NSDictionary class]]
            ? legacyRegion[@"value"]
            : legacyRegion;
        PXRegionIdentity *migratedRegion = PXRegionIdentityByCompletingPropertyList(
            legacyRegionValue,
            network[@"isoCountryCode"] ?: @"",
            legacySeed);
        manifest.region = [migratedRegion propertyListRepresentation] ?: @{};
        manifest.location = location ?: @{};
        manifest.appIdentities = @{};
        manifest.appGroupIdentities = @{};
        manifest.fieldSourcePolicy = PXProfileFieldSourcePolicy();
        manifest.virtualSession = virtualSession;

        NSError *validationError = nil;
        if (![manifest validateWithError:&validationError]) {
            if (error) *error = validationError;
            return NO;
        }

        NSString *backupDirectory = [self.identityDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@".profile-legacy-backup-%@", NSUUID.UUID.UUIDString]];
        if (![fileManager createDirectoryAtPath:backupDirectory
                    withIntermediateDirectories:NO
                                     attributes:nil
                                          error:error]) {
            return NO;
        }

        NSMutableArray<NSString *> *movedFileNames = [NSMutableArray array];
        for (NSString *fileName in [self legacyProjectionFileNames]) {
            NSString *sourcePath = [self.identityDirectory stringByAppendingPathComponent:fileName];
            BOOL sourceIsSymlink = NO;
            if (![self pathExistsWithoutFollowingSymlinks:sourcePath isSymlink:&sourceIsSymlink] || sourceIsSymlink) {
                continue;
            }
            NSString *backupPath = [backupDirectory stringByAppendingPathComponent:fileName];
            if (![fileManager moveItemAtPath:sourcePath toPath:backupPath error:error]) {
                for (NSString *movedFileName in movedFileNames) {
                    [fileManager moveItemAtPath:[backupDirectory stringByAppendingPathComponent:movedFileName]
                                        toPath:[self.identityDirectory stringByAppendingPathComponent:movedFileName]
                                         error:nil];
                }
                [fileManager removeItemAtPath:backupDirectory error:nil];
                return NO;
            }
            [movedFileNames addObject:fileName];
        }

        if ([self performPromotionOfManifest:manifest error:error]) {
            [fileManager removeItemAtPath:backupDirectory error:nil];
            return YES;
        }

        for (NSString *fileName in [self legacyProjectionFileNames]) {
            NSString *projectionPath = [self.identityDirectory stringByAppendingPathComponent:fileName];
            BOOL projectionIsSymlink = NO;
            if ([self pathExistsWithoutFollowingSymlinks:projectionPath isSymlink:&projectionIsSymlink] && projectionIsSymlink) {
                unlink(projectionPath.fileSystemRepresentation);
            }
        }
        for (NSString *movedFileName in movedFileNames) {
            [fileManager moveItemAtPath:[backupDirectory stringByAppendingPathComponent:movedFileName]
                                toPath:[self.identityDirectory stringByAppendingPathComponent:movedFileName]
                                 error:nil];
        }
        [fileManager removeItemAtPath:backupDirectory error:nil];
        return NO;
    }
}

@end
