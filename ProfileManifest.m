#import "ProfileManifest.h"

#import "NetworkIdentity.h"
#import "RegionIdentity.h"
#import "PXRootHidePath.h"


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
    if (![[NSUUID alloc] initWithUUIDString:self.generationID] ||
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
    NSDictionary<NSString *, id> *storedRegion = [propertyList[@"region"] isKindOfClass:[NSDictionary class]]
        ? propertyList[@"region"]
        : @{};
    PXRegionIdentity *regionIdentity = [PXRegionIdentity identityWithPropertyList:storedRegion];
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
    manifest.fieldSourcePolicy = propertyList[@"fieldSourcePolicy"] ?: @{};
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
    NSSet<NSNumber *> *networkTypes = input.networkTypes.count > 0
        ? input.networkTypes
        : (input.networkType == PXEnvironmentNetworkTypeUnspecified
            ? [NSSet set] : [NSSet setWithObject:@(input.networkType)]);
    PXEnvironmentNetworkType activeNetworkType = PXPreferredEnvironmentNetworkType(networkTypes);
    BOOL includes5G = [networkTypes containsObject:@(PXEnvironmentNetworkType5GNR)];
    if (includes5G && ![device[@"supports5G"] boolValue]) {
        if (error) {
            *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                         code:18
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Selected model does not support the configured 5G network"}];
        }
        return nil;
    }
    NSString *configuredRadioTechnology = nil;
    if (includes5G) {
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
    } else if ([networkTypes containsObject:@(PXEnvironmentNetworkType4GLTE)]) {
        configuredRadioTechnology = @"CTRadioAccessTechnologyLTE";
    } else if ([networkTypes containsObject:@(PXEnvironmentNetworkType3G)]) {
        configuredRadioTechnology = @"CTRadioAccessTechnologyWCDMA";
    } else if ([networkTypes containsObject:@(PXEnvironmentNetworkType2G)]) {
        configuredRadioTechnology = @"CTRadioAccessTechnologyEdge";
    }
    switch (activeNetworkType) {
        case PXEnvironmentNetworkTypeWiFi:
            network[@"transport"] = @"wifi";
            break;
        case PXEnvironmentNetworkType5GNR:
            network[@"transport"] = @"cellular";
            break;
        case PXEnvironmentNetworkType4GLTE:
            network[@"transport"] = @"cellular";
            break;
        case PXEnvironmentNetworkType3G:
            network[@"transport"] = @"cellular";
            break;
        case PXEnvironmentNetworkType2G:
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
        NSMutableArray<NSString *> *enabledRadioTechnologies = [NSMutableArray array];
        for (NSString *technology in network[@"supportedRadioTechnologies"]) {
            BOOL enabled5G = includes5G &&
                ([technology isEqualToString:@"CTRadioAccessTechnologyNR"] ||
                 [technology isEqualToString:@"CTRadioAccessTechnologyNRNSA"]);
            if ((enabled5G || ([networkTypes containsObject:@(PXEnvironmentNetworkType4GLTE)] &&
                               [technology isEqualToString:@"CTRadioAccessTechnologyLTE"])) &&
                ![enabledRadioTechnologies containsObject:technology]) {
                [enabledRadioTechnologies addObject:technology];
            }
        }
        for (NSString *technology in @[@"CTRadioAccessTechnologyLTE",
                                       @"CTRadioAccessTechnologyWCDMA",
                                       @"CTRadioAccessTechnologyEdge"]) {
            BOOL enabled = ([technology isEqualToString:@"CTRadioAccessTechnologyLTE"] &&
                            [networkTypes containsObject:@(PXEnvironmentNetworkType4GLTE)]) ||
                           ([technology isEqualToString:@"CTRadioAccessTechnologyWCDMA"] &&
                            [networkTypes containsObject:@(PXEnvironmentNetworkType3G)]) ||
                           ([technology isEqualToString:@"CTRadioAccessTechnologyEdge"] &&
                            [networkTypes containsObject:@(PXEnvironmentNetworkType2G)]);
            if (enabled && ![enabledRadioTechnologies containsObject:technology]) {
                [enabledRadioTechnologies addObject:technology];
            }
        }
        network[@"supportedRadioTechnologies"] = [enabledRadioTechnologies copy];
    }
    network[@"configuredNetworkType"] = PXEnvironmentNetworkTypeIdentifier(activeNetworkType);
    if (networkTypes.count > 0) {
        network[@"configuredNetworkTypes"] = PXEnvironmentNetworkTypeIdentifiers(networkTypes);
    }
    if (activeNetworkType == PXEnvironmentNetworkTypeNone) {
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

- (BOOL)failWithError:(NSError * _Nullable * _Nullable)error code:(NSInteger)code reason:(NSString *)reason {
    if (error) {
        *error = [NSError errorWithDomain:PXProfileManifestErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

- (NSString *)profileFilePath {
    // Production projections are keys in current_profile.plist.
    if ([self.identityDirectory isEqualToString:PXCurrentProfileIdentityValuesPath()]) {
        return PXCurrentProfileInfoPath();
    }
    return [[[self.identityDirectory.stringByDeletingLastPathComponent
        stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"current_profile.plist"];
}

- (BOOL)writeManifestPropertyList:(NSDictionary *)propertyList
                      projections:(NSDictionary<NSString *, NSDictionary *> *)projections
                            error:(NSError * _Nullable * _Nullable)error {
    if (!PXProfileUpdateContentsAtPath([self profileFilePath], ^(NSMutableDictionary *profile) {
        NSMutableDictionary *values = [profile[@"values"] isKindOfClass:[NSDictionary class]]
            ? [profile[@"values"] mutableCopy] : [NSMutableDictionary dictionary];
        if (projections) {
            for (NSString *key in [values.allKeys copy]) {
                if ([key hasPrefix:@"identity/"]) [values removeObjectForKey:key];
            }
            for (NSString *fileName in projections) {
                values[[@"identity" stringByAppendingPathComponent:fileName]] = projections[fileName];
            }
        }
        profile[@"manifest"] = propertyList;
        profile[@"values"] = values;
    })) {
        return [self failWithError:error code:5 reason:@"Failed to save current_profile.plist"];
    }
    return YES;
}

- (BOOL)promoteManifest:(PXProfileManifest *)manifest error:(NSError * _Nullable * _Nullable)error {
    if (![manifest validateWithError:error]) return NO;
    if (self.failBeforePromotionForTesting) {
        return [self failWithError:error code:6 reason:@"Injected failure before Profile save"];
    }
    @synchronized([PXProfileStore class]) {
        return [self writeManifestPropertyList:[manifest propertyListRepresentation]
                                   projections:[self projectionsForManifest:manifest]
                                         error:error];
    }
}

- (BOOL)replaceActiveIdentifierValue:(NSString *)value
                              forKey:(NSString *)key
                               error:(NSError * _Nullable * _Nullable)error {
    NSSet<NSString *> *allowedKeys = [NSSet setWithArray:@[
        @"idfa", @"idfv", @"deviceName", @"serialNumber", @"imei", @"meid",
        @"dyldCacheUUID", @"pasteboardUUID", @"keychainUUID",
        @"userDefaultsUUID", @"coreDataUUID"
    ]];
    if (![allowedKeys containsObject:key] || ![value isKindOfClass:[NSString class]] || value.length == 0) {
        return [self failWithError:error code:14 reason:@"Invalid Profile identifier update"];
    }
    @synchronized([PXProfileStore class]) {
        PXProfileManifest *current = [self activeManifestWithError:error];
        if (!current) return NO;
        NSMutableDictionary *updated = [[current propertyListRepresentation] mutableCopy];
        NSMutableDictionary *identifiers = [current.identifiers mutableCopy];
        identifiers[key] = value;
        updated[@"identifiers"] = identifiers;
        PXProfileManifest *manifest = [PXProfileManifest manifestWithPropertyList:updated error:error];
        if (!manifest) return NO;
        return [self writeManifestPropertyList:updated
                                   projections:[self projectionsForManifest:manifest]
                                         error:error];
    }
}

- (BOOL)replaceActiveLocalIPAddress:(NSString *)ipv4
                       IPv6Address:(NSString *)ipv6
                             error:(NSError * _Nullable * _Nullable)error {
    if (![ipv4 isKindOfClass:[NSString class]] || ipv4.length == 0 ||
        ![ipv6 isKindOfClass:[NSString class]] || ipv6.length == 0) {
        return [self failWithError:error code:14 reason:@"Invalid Profile local IP address"];
    }
    @synchronized([PXProfileStore class]) {
        PXProfileManifest *current = [self activeManifestWithError:error];
        if (!current) return NO;
        NSMutableDictionary *updated = [[current propertyListRepresentation] mutableCopy];
        NSMutableDictionary *network = [current.network mutableCopy];
        network[@"localIPAddress"] = ipv4;
        network[@"localIPv6Address"] = ipv6;
        updated[@"network"] = network;
        PXProfileManifest *manifest = [PXProfileManifest manifestWithPropertyList:updated error:error];
        if (!manifest) return NO;
        return [self writeManifestPropertyList:updated
                                   projections:[self projectionsForManifest:manifest]
                                         error:error];
    }
}

- (nullable NSString *)activeGenerationIDWithError:(NSError * _Nullable * _Nullable)error {
    return [self activeManifestWithError:error].generationID;
}

- (nullable PXProfileManifest *)activeManifestWithError:(NSError * _Nullable * _Nullable)error {
    NSDictionary *profile = PXProfileReadContentsAtPath([self profileFilePath]);
    NSDictionary *propertyList = [profile[@"manifest"] isKindOfClass:[NSDictionary class]]
        ? profile[@"manifest"] : nil;
    return [PXProfileManifest manifestWithPropertyList:propertyList error:error];
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
    NSMutableDictionary<NSString *, PXAppIdentityRecord *> *validated = [NSMutableDictionary dictionary];
    for (id bundleIdentifier in appIdentities) {
        NSDictionary *propertyList = appIdentities[bundleIdentifier];
        PXAppIdentityRecord *identity = [propertyList isKindOfClass:[NSDictionary class]]
            ? [PXAppIdentityRecord identityWithPropertyList:propertyList] : nil;
        if (![bundleIdentifier isKindOfClass:[NSString class]] ||
            !PXAppIdentityBundleIsEligible(bundleIdentifier, YES, NO) || !identity) {
            return [self failWithError:error code:13 reason:@"Application identity map is invalid"];
        }
        validated[bundleIdentifier] = identity;
    }
    @synchronized([PXProfileStore class]) {
        PXProfileManifest *manifest = [self activeManifestWithError:error];
        if (!manifest) return NO;
        NSMutableDictionary *updated = [[manifest propertyListRepresentation] mutableCopy];
        updated[@"appIdentities"] = PXAppIdentityPropertyLists(validated);
        if (![PXProfileManifest manifestWithPropertyList:updated error:error]) return NO;
        return [self writeManifestPropertyList:updated projections:nil error:error];
    }
}

- (BOOL)ensureApplicationIdentityForBundleIdentifier:(NSString *)bundleIdentifier
                                     groupIdentifiers:(NSSet<NSString *> *)groupIdentifiers
                                installIdentifierKeys:(NSSet<NSString *> *)installIdentifierKeys
                                                 error:(NSError * _Nullable * _Nullable)error {
    if (bundleIdentifier.length == 0) {
        return [self failWithError:error code:13 reason:@"Application identity requires a bundle identifier"];
    }
    @synchronized([PXProfileStore class]) {
        PXProfileManifest *manifest = [self activeManifestWithError:error];
        if (!manifest) return NO;
        NSMutableDictionary<NSString *, PXAppIdentityRecord *> *apps = [manifest.appIdentities mutableCopy];
        NSMutableDictionary<NSString *, PXAppGroupIdentityRecord *> *groups = [manifest.appGroupIdentities mutableCopy];
        PXAppIdentityRecord *identity = apps[bundleIdentifier];
        BOOL changed = NO;
        if (!identity) {
            apps[bundleIdentifier] = [PXAppIdentityRecord identityForProfileSeed:manifest.seed
                bundleIdentifier:bundleIdentifier installIdentifierKeys:installIdentifierKeys];
            changed = YES;
        } else {
            NSMutableSet *keys = [identity.installIdentifierKeys mutableCopy];
            [keys unionSet:installIdentifierKeys];
            if (![keys isEqualToSet:identity.installIdentifierKeys]) {
                NSMutableDictionary *entry = [[identity propertyListRepresentation] mutableCopy];
                entry[@"installIdentifierKeys"] = [keys.allObjects sortedArrayUsingSelector:@selector(compare:)];
                apps[bundleIdentifier] = [PXAppIdentityRecord identityWithPropertyList:entry];
                changed = YES;
            }
        }
        for (NSString *groupIdentifier in groupIdentifiers) {
            if (groupIdentifier.length && !groups[groupIdentifier]) {
                groups[groupIdentifier] = [PXAppGroupIdentityRecord identityForProfileSeed:manifest.seed
                    groupIdentifier:groupIdentifier];
                changed = YES;
            }
        }
        if (!changed) return YES;
        NSMutableDictionary *updated = [[manifest propertyListRepresentation] mutableCopy];
        updated[@"appIdentities"] = PXAppIdentityPropertyLists(apps);
        updated[@"appGroupIdentities"] = PXAppGroupIdentityPropertyLists(groups);
        if (![PXProfileManifest manifestWithPropertyList:updated error:error]) return NO;
        return [self writeManifestPropertyList:updated projections:nil error:error];
    }
}

@end
