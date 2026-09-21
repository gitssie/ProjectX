#import "GraphicsIdentity.h"
#if __has_include(<Metal/Metal.h>)
#import <Metal/Metal.h>
#import <objc/message.h>
#endif
#if __has_include(<OpenGLES/ES3/gl.h>)
// OpenGL ES is intentionally queried for compatibility with legacy target apps.
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/EAGL.h>
#endif

NSString * const PXGraphicsIdentityErrorDomain = @"com.hydra.projectx.graphics-identity";
NSString * const PXModelCompatibilityErrorDomain = @"com.hydra.projectx.model-compatibility";
NSString * const PXModelCompatibilityMismatchFieldsErrorKey = @"mismatchFields";
NSString * const PXModelCompatibilityReasonErrorKey = @"compatibilityReason";

NSString * const PXModelCompatibilityReasonPhysicalUnavailable = @"physical-unavailable";
NSString * const PXModelCompatibilityReasonImmutableHardwareMismatch = @"immutable-hardware-mismatch";
NSString * const PXModelCompatibilityReasonHostCapabilitiesUnavailable = @"host-capabilities-unavailable";
NSString * const PXModelCompatibilityReasonCandidateInvalid = @"candidate-invalid";

NSString * const PXModelCompatibilityFieldMarketingFamily = @"marketing-family";
NSString * const PXModelCompatibilityFieldCPUClass = @"cpu-class";
NSString * const PXModelCompatibilityFieldGraphicsClass = @"graphics-class";
NSString * const PXModelCompatibilityFieldMemoryClass = @"memory-class";
NSString * const PXModelCompatibilityFieldDisplayClass = @"display-class";
NSString * const PXModelCompatibilityFieldHostGraphics = @"host-graphics";

BOOL PXGraphicsProtectionIsEnabledForSettings(NSDictionary<NSString *, id> *settings) {
    id configuredValue = settings[@"canvasFingerprintingEnabled"];
    if (configuredValue == nil) {
        configuredValue = settings[@"CanvasFingerprint"];
    }
    if (configuredValue == nil) {
        return YES;
    }
    return [configuredValue isKindOfClass:[NSNumber class]] && [configuredValue boolValue];
}

BOOL PXGraphicsUserScriptsNeedCurrentSource(NSArray<NSString *> *existingSources,
                                            NSString *currentSource) {
    if (currentSource.length == 0) {
        return NO;
    }
    for (NSString *source in existingSources) {
        if ([source isEqualToString:currentSource]) {
            return NO;
        }
    }
    return YES;
}

NSUInteger PXGraphicsClampedLimit(PXGraphicsIdentity *identity,
                                  NSString *key,
                                  NSUInteger hostLimit) {
    NSUInteger targetLimit = [identity.webGL[key] unsignedIntegerValue];
    return targetLimit > 0 ? MIN(hostLimit, targetLimit) : hostLimit;
}

NSArray<NSString *> *PXGraphicsFilteredExtensions(NSArray<NSString *> *targetExtensions,
                                                  NSArray<NSString *> *hostExtensions) {
    NSSet<NSString *> *targetSet = [NSSet setWithArray:targetExtensions ?: @[]];
    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *extension in hostExtensions ?: @[]) {
        if ([targetSet containsObject:extension]) {
            [filtered addObject:extension];
        }
    }
    return [filtered copy];
}

BOOL PXGraphicsAllowsMetalFamily(PXGraphicsIdentity *identity,
                                 NSUInteger family,
                                 BOOL hostSupportsFamily) {
    return hostSupportsFamily && [identity.metalFamilies containsObject:@(family)];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
NSDictionary<NSString *, id> *PXCurrentGraphicsHostCapabilities(void) {
    NSMutableArray<NSNumber *> *metalFamilies = [NSMutableArray array];
    NSMutableArray<NSNumber *> *metalFeatureSets = [NSMutableArray array];
    NSUInteger maxTextureSize = 0;
    NSUInteger maxRenderbufferSize = 0;
    BOOL supportsOpenGLES3 = NO;
#if __has_include(<Metal/Metal.h>)
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
        if ([device respondsToSelector:@selector(supportsFamily:)]) {
            for (NSInteger family = 1001; family <= 1009; family++) {
                if ([device supportsFamily:(MTLGPUFamily)family]) {
                    [metalFamilies addObject:@(family)];
                }
            }
        }
        if ([device respondsToSelector:@selector(supportsFeatureSet:)]) {
            BOOL (*supportsFeatureSet)(id, SEL, NSUInteger) =
                (BOOL (*)(id, SEL, NSUInteger))objc_msgSend;
            for (NSInteger featureSet = 0; featureSet <= 16; featureSet++) {
                if (supportsFeatureSet(device, @selector(supportsFeatureSet:), (NSUInteger)featureSet)) {
                    [metalFeatureSets addObject:@(featureSet)];
                }
            }
        }
        maxTextureSize = [metalFamilies containsObject:@1003] ? 16384 : 8192;
        maxRenderbufferSize = maxTextureSize;
    }
#endif
#if __has_include(<OpenGLES/ES3/gl.h>)
    EAGLContext *previousContext = [EAGLContext currentContext];
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (context && [EAGLContext setCurrentContext:context]) {
        GLint textureLimit = 0;
        GLint renderbufferLimit = 0;
        glGetIntegerv(GL_MAX_TEXTURE_SIZE, &textureLimit);
        glGetIntegerv(GL_MAX_RENDERBUFFER_SIZE, &renderbufferLimit);
        maxTextureSize = (NSUInteger)MAX(textureLimit, 0);
        maxRenderbufferSize = (NSUInteger)MAX(renderbufferLimit, 0);
        supportsOpenGLES3 = YES;
        [EAGLContext setCurrentContext:previousContext];
    }
#endif
    return @{
        @"metalFamilies": [metalFamilies copy],
        @"metalFeatureSets": [metalFeatureSets copy],
        @"maxTextureSize": @(maxTextureSize),
        @"maxRenderbufferSize": @(maxRenderbufferSize),
        @"supportsOpenGLES3": @(supportsOpenGLES3)
    };
}
#pragma clang diagnostic pop

static BOOL PXGraphicsFail(NSError * _Nullable * _Nullable error,
                           NSInteger code,
                           NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:PXGraphicsIdentityErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return NO;
}

static BOOL PXGraphicsArrayContainsOnlyNumbers(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return NO;
    }
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[NSNumber class]]) {
            return NO;
        }
    }
    return YES;
}

static BOOL PXGraphicsHostCapabilitiesAreValid(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSDictionary<NSString *, id> *hostCapabilities = value;
    return PXGraphicsArrayContainsOnlyNumbers(hostCapabilities[@"metalFamilies"]) &&
        PXGraphicsArrayContainsOnlyNumbers(hostCapabilities[@"metalFeatureSets"]) &&
        [hostCapabilities[@"maxTextureSize"] isKindOfClass:[NSNumber class]] &&
        [hostCapabilities[@"maxRenderbufferSize"] isKindOfClass:[NSNumber class]] &&
        [hostCapabilities[@"supportsOpenGLES3"] isKindOfClass:[NSNumber class]];
}

static NSInteger PXMetalFamilyForGPUName(NSString *gpuName) {
    if ([gpuName containsString:@"A17"]) return 1009;
    if ([gpuName containsString:@"A16"] || [gpuName containsString:@"M2"]) return 1008;
    if ([gpuName containsString:@"A14"] || [gpuName containsString:@"A15"] ||
        [gpuName containsString:@"M1"]) return 1007;
    if ([gpuName containsString:@"A13"]) return 1006;
    if ([gpuName containsString:@"A12"]) return 1005;
    if ([gpuName containsString:@"A11"]) return 1004;
    if ([gpuName containsString:@"A10"]) return 1003;
    return 0;
}

static NSString *PXExpectedMetalFeatureSetForGPUName(NSString *gpuName) {
    if ([gpuName containsString:@"A17"] || [gpuName containsString:@"A16 Pro"] ||
        [gpuName containsString:@"M2"]) return @"Metal 3.1";
    if ([gpuName containsString:@"A16"] || [gpuName containsString:@"A15"] ||
        [gpuName containsString:@"A14"] || [gpuName containsString:@"A13"] ||
        [gpuName containsString:@"M1"]) return @"Metal 3.0";
    if ([gpuName containsString:@"A12"]) return @"Metal 2.4";
    if ([gpuName containsString:@"A11"]) return @"Metal 2.3";
    if ([gpuName containsString:@"A10"]) return @"Metal 2.2";
    return nil;
}

static NSArray<NSNumber *> *PXMetalFamiliesThrough(NSInteger requiredFamily) {
    if (requiredFamily < 1001) return @[];
    NSMutableArray<NSNumber *> *families = [NSMutableArray array];
    for (NSInteger family = 1001; family <= requiredFamily; family++) {
        [families addObject:@(family)];
    }
    return [families copy];
}

static NSArray<NSNumber *> *PXMetalFeatureSetsThrough(NSInteger requiredFamily) {
    NSDictionary<NSNumber *, NSNumber *> *familiesByFeatureSet = @{
        @0: @1001, @1: @1002, @2: @1001, @3: @1002, @4: @1003,
        @5: @1001, @6: @1002, @7: @1003, @8: @1001, @9: @1002,
        @10: @1003, @11: @1004, @12: @1001, @13: @1002, @14: @1003,
        @15: @1004, @16: @1005
    };
    NSMutableArray<NSNumber *> *featureSets = [NSMutableArray array];
    for (NSNumber *featureSet in [[familiesByFeatureSet allKeys]
        sortedArrayUsingSelector:@selector(compare:)]) {
        if ([familiesByFeatureSet[featureSet] integerValue] <= requiredFamily) {
            [featureSets addObject:featureSet];
        }
    }
    return [featureSets copy];
}

NSDictionary<NSString *, id> *PXGraphicsModelDescription(NSString *gpuFamily,
                                                          NSString *metalFeatureSet,
                                                          NSDictionary<NSString *, id> *webGLInfo) {
    if (gpuFamily.length == 0 || [gpuFamily isEqualToString:@"Unknown"] ||
        metalFeatureSet.length == 0 || [metalFeatureSet isEqualToString:@"Unknown"] ||
        ![webGLInfo isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSInteger metalFamily = PXMetalFamilyForGPUName(gpuFamily);
    NSString *expectedFeatureSet = PXExpectedMetalFeatureSetForGPUName(gpuFamily);
    NSInteger maxTextureSize = [webGLInfo[@"maxTextureSize"] integerValue];
    NSInteger maxRenderbufferSize = [webGLInfo[@"maxRenderBufferSize"] integerValue];
    if (metalFamily == 0 || ![metalFeatureSet isEqualToString:expectedFeatureSet] ||
        maxTextureSize <= 0 || maxRenderbufferSize <= 0) {
        return @{};
    }
    NSArray<NSString *> *webGLExtensions = @[
        @"ANGLE_instanced_arrays", @"EXT_blend_minmax", @"EXT_color_buffer_half_float",
        @"EXT_frag_depth", @"EXT_shader_texture_lod", @"EXT_texture_filter_anisotropic",
        @"OES_element_index_uint", @"OES_standard_derivatives", @"OES_texture_float",
        @"OES_texture_half_float", @"OES_vertex_array_object", @"WEBGL_color_buffer_float",
        @"WEBGL_compressed_texture_astc", @"WEBGL_debug_renderer_info", @"WEBGL_lose_context"
    ];
    NSArray<NSString *> *openGLExtensions = @[
        @"GL_EXT_color_buffer_half_float", @"GL_EXT_discard_framebuffer",
        @"GL_EXT_read_format_bgra", @"GL_EXT_texture_filter_anisotropic",
        @"GL_IMG_read_format", @"GL_IMG_texture_compression_pvrtc",
        @"GL_KHR_texture_compression_astc_ldr", @"GL_OES_depth24",
        @"GL_OES_element_index_uint", @"GL_OES_packed_depth_stencil",
        @"GL_OES_standard_derivatives", @"GL_OES_vertex_array_object"
    ];
    NSDictionary<NSString *, NSNumber *> *limits = @{
        @"maxTextureSize": @(maxTextureSize),
        @"maxRenderbufferSize": @(maxRenderbufferSize),
        @"maxCubeMapTextureSize": @(maxTextureSize),
        @"maxTextureImageUnits": @16,
        @"maxVertexTextureImageUnits": @16,
        @"maxCombinedTextureImageUnits": @32,
        @"maxVertexAttribs": @16,
        @"maxVertexUniformVectors": @256,
        @"maxFragmentUniformVectors": @224,
        @"maxVaryingVectors": @16
    };
    NSMutableDictionary<NSString *, id> *webGL = [limits mutableCopy];
    webGL[@"vendor"] = webGLInfo[@"webglVendor"] ?: @"Apple";
    webGL[@"renderer"] = webGLInfo[@"webglRenderer"] ?: @"Apple GPU";
    webGL[@"unmaskedVendor"] = webGLInfo[@"unmaskedVendor"] ?: @"Apple Inc.";
    webGL[@"unmaskedRenderer"] = gpuFamily;
    webGL[@"version"] = webGLInfo[@"webglVersion"] ?: @"WebGL 2.0";
    webGL[@"shadingLanguageVersion"] = @"WebGL GLSL ES 3.00";
    webGL[@"extensions"] = webGLExtensions;
    webGL[@"precision"] = @{@"rangeMin": @127, @"rangeMax": @127, @"precision": @23};

    NSMutableDictionary<NSString *, id> *openGL = [limits mutableCopy];
    openGL[@"vendor"] = @"Apple Inc.";
    openGL[@"renderer"] = gpuFamily;
    openGL[@"version"] = @"OpenGL ES 3.0 Apple";
    openGL[@"shadingLanguageVersion"] = @"OpenGL ES GLSL ES 3.00";
    openGL[@"extensions"] = openGLExtensions;

    return @{
        @"gpuName": gpuFamily,
        @"gpuFamily": gpuFamily,
        @"requiredMetalFamily": @(metalFamily),
        @"metalFamilies": PXMetalFamiliesThrough(metalFamily),
        @"metalFeatureSets": PXMetalFeatureSetsThrough(metalFamily),
        @"metalFeatureSetName": metalFeatureSet,
        @"webGL": [webGL copy],
        @"openGL": [openGL copy]
    };
}

static uint64_t PXGraphicsHashBytes(NSData *data, uint64_t seed) {
    uint64_t hash = seed;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t PXGraphicsSeed(NSString *profileSeed,
                               NSString *generationID,
                               NSString *modelIdentifier) {
    NSString *material = [NSString stringWithFormat:@"%@\0%@\0%@",
        profileSeed, generationID.lowercaseString, modelIdentifier];
    NSData *data = [material dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t hash = PXGraphicsHashBytes(data, UINT64_C(1469598103934665603));
    return hash ?: UINT64_C(0x9e3779b97f4a7c15);
}

@interface PXGraphicsIdentity ()

@property (nonatomic, copy, readwrite) NSString *generationID;
@property (nonatomic, copy, readwrite) NSString *modelIdentifier;
@property (nonatomic, copy, readwrite) NSString *gpuName;
@property (nonatomic, copy, readwrite) NSString *gpuFamily;
@property (nonatomic, copy, readwrite) NSArray<NSNumber *> *metalFamilies;
@property (nonatomic, copy, readwrite) NSArray<NSNumber *> *metalFeatureSets;
@property (nonatomic, copy, readwrite) NSString *metalFeatureSetName;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *webGL;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *openGL;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *hostCapabilities;
@property (nonatomic, assign, readwrite) uint64_t canvasNoiseSeed;

@end

@implementation PXGraphicsIdentity

+ (instancetype)identityWithModelRecord:(NSDictionary<NSString *, id> *)modelRecord
                             profileSeed:(NSString *)profileSeed
                            generationID:(NSString *)generationID
                        hostCapabilities:(NSDictionary<NSString *, id> *)hostCapabilities
                                   error:(NSError **)error {
    NSString *modelIdentifier = [modelRecord[@"identifier"] isKindOfClass:[NSString class]]
        ? modelRecord[@"identifier"]
        : @"";
    NSDictionary *description = [modelRecord[@"graphics"] isKindOfClass:[NSDictionary class]]
        ? modelRecord[@"graphics"]
        : PXGraphicsModelDescription(modelRecord[@"gpuFamily"] ?: @"",
                                     modelRecord[@"metalFeatureSet"] ?: @"",
                                     modelRecord[@"webGLInfo"] ?: @{});
    if (modelIdentifier.length == 0 || ![[NSUUID alloc] initWithUUIDString:generationID] ||
        profileSeed.length == 0 || description.count == 0) {
        PXGraphicsFail(error, 1, @"Graphics identity input is incomplete");
        return nil;
    }
    PXGraphicsIdentity *identity = [[self alloc] init];
    identity.generationID = generationID.lowercaseString;
    identity.modelIdentifier = modelIdentifier;
    identity.gpuName = description[@"gpuName"];
    identity.gpuFamily = description[@"gpuFamily"];
    identity.metalFamilies = description[@"metalFamilies"];
    identity.metalFeatureSets = description[@"metalFeatureSets"];
    identity.metalFeatureSetName = description[@"metalFeatureSetName"];
    identity.webGL = description[@"webGL"];
    identity.openGL = description[@"openGL"];
    identity.hostCapabilities = [hostCapabilities copy];
    identity.canvasNoiseSeed = PXGraphicsSeed(profileSeed, generationID, modelIdentifier);
    return [identity validateAgainstModelRecord:modelRecord
                                hostCapabilities:hostCapabilities
                                           error:error] ? identity : nil;
}

- (BOOL)validateAgainstModelRecord:(NSDictionary<NSString *, id> *)modelRecord
                  hostCapabilities:(NSDictionary<NSString *, id> *)hostCapabilities
                             error:(NSError **)error {
    NSDictionary *description = [modelRecord[@"graphics"] isKindOfClass:[NSDictionary class]]
        ? modelRecord[@"graphics"]
        : PXGraphicsModelDescription(modelRecord[@"gpuFamily"] ?: @"",
                                     modelRecord[@"metalFeatureSet"] ?: @"",
                                     modelRecord[@"webGLInfo"] ?: @{});
    if (![[NSUUID alloc] initWithUUIDString:self.generationID] || self.modelIdentifier.length == 0 ||
        ![self.modelIdentifier isEqualToString:modelRecord[@"identifier"]] ||
        ![self.gpuName isEqualToString:description[@"gpuName"]] ||
        ![self.gpuFamily isEqualToString:description[@"gpuFamily"]] ||
        ![self.metalFamilies isEqualToArray:description[@"metalFamilies"]] ||
        ![self.metalFeatureSets isEqualToArray:description[@"metalFeatureSets"]] ||
        ![self.metalFeatureSetName isEqualToString:description[@"metalFeatureSetName"]] ||
        ![self.webGL isEqualToDictionary:description[@"webGL"]] ||
        ![self.openGL isEqualToDictionary:description[@"openGL"]] || self.canvasNoiseSeed == 0) {
        return PXGraphicsFail(error, 2, @"Graphics identity does not match the selected model");
    }
    if (!PXGraphicsHostCapabilitiesAreValid(hostCapabilities) ||
        ![self.hostCapabilities isEqualToDictionary:hostCapabilities]) {
        return PXGraphicsFail(error, 4, @"Graphics host capabilities are invalid");
    }
    return YES;
}

+ (instancetype)identityWithPropertyList:(NSDictionary<NSString *, id> *)propertyList
                                    error:(NSError **)error {
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        PXGraphicsFail(error, 4, @"Graphics property list is invalid");
        return nil;
    }
    if (![propertyList[@"generationID"] isKindOfClass:[NSString class]] ||
        ![propertyList[@"modelIdentifier"] isKindOfClass:[NSString class]] ||
        ![propertyList[@"gpuName"] isKindOfClass:[NSString class]] ||
        ![propertyList[@"gpuFamily"] isKindOfClass:[NSString class]] ||
        !PXGraphicsArrayContainsOnlyNumbers(propertyList[@"metalFamilies"]) ||
        !PXGraphicsArrayContainsOnlyNumbers(propertyList[@"metalFeatureSets"]) ||
        ![propertyList[@"metalFeatureSetName"] isKindOfClass:[NSString class]] ||
        ![propertyList[@"webGL"] isKindOfClass:[NSDictionary class]] ||
        ![propertyList[@"openGL"] isKindOfClass:[NSDictionary class]] ||
        ![propertyList[@"hostCapabilities"] isKindOfClass:[NSDictionary class]] ||
        ![propertyList[@"canvasNoiseSeed"] isKindOfClass:[NSNumber class]]) {
        PXGraphicsFail(error, 4, @"Graphics property list contains invalid field types");
        return nil;
    }
    NSDictionary<NSString *, id> *hostCapabilities = propertyList[@"hostCapabilities"];
    if (!PXGraphicsHostCapabilitiesAreValid(hostCapabilities)) {
        PXGraphicsFail(error, 4, @"Graphics host capabilities contain invalid field types");
        return nil;
    }
    PXGraphicsIdentity *identity = [[self alloc] init];
    identity.generationID = propertyList[@"generationID"] ?: @"";
    identity.modelIdentifier = propertyList[@"modelIdentifier"] ?: @"";
    identity.gpuName = propertyList[@"gpuName"] ?: @"";
    identity.gpuFamily = propertyList[@"gpuFamily"] ?: @"";
    identity.metalFamilies = propertyList[@"metalFamilies"] ?: @[];
    identity.metalFeatureSets = propertyList[@"metalFeatureSets"] ?: @[];
    identity.metalFeatureSetName = propertyList[@"metalFeatureSetName"] ?: @"";
    identity.webGL = propertyList[@"webGL"] ?: @{};
    identity.openGL = propertyList[@"openGL"] ?: @{};
    identity.hostCapabilities = hostCapabilities;
    identity.canvasNoiseSeed = [propertyList[@"canvasNoiseSeed"] unsignedLongLongValue];
    if (![[NSUUID alloc] initWithUUIDString:identity.generationID] ||
        identity.modelIdentifier.length == 0 || identity.gpuName.length == 0 ||
        identity.gpuFamily.length == 0 || identity.metalFamilies.count == 0 ||
        identity.webGL.count == 0 || identity.openGL.count == 0 ||
        identity.hostCapabilities.count == 0 || identity.canvasNoiseSeed == 0) {
        PXGraphicsFail(error, 5, @"Graphics property list is incomplete");
        return nil;
    }
    return identity;
}

- (NSDictionary<NSString *, id> *)propertyListRepresentation {
    return @{
        @"generationID": self.generationID,
        @"modelIdentifier": self.modelIdentifier,
        @"gpuName": self.gpuName,
        @"gpuFamily": self.gpuFamily,
        @"metalFamilies": self.metalFamilies,
        @"metalFeatureSets": self.metalFeatureSets,
        @"metalFeatureSetName": self.metalFeatureSetName,
        @"webGL": self.webGL,
        @"openGL": self.openGL,
        @"hostCapabilities": self.hostCapabilities,
        @"canvasNoiseSeed": @(self.canvasNoiseSeed)
    };
}

- (NSData *)deterministicallyNoisedBytes:(NSData *)input domain:(NSString *)domain {
    if (input.length == 0 || domain.length == 0) {
        return [input copy];
    }
    NSMutableData *output = [input mutableCopy];
    uint8_t *bytes = output.mutableBytes;
    NSData *domainData = [domain dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t domainSeed = PXGraphicsHashBytes(domainData, self.canvasNoiseSeed);
    for (NSUInteger index = 0; index < output.length; index++) {
        uint64_t mixed = domainSeed ^ ((uint64_t)index * UINT64_C(0x9e3779b97f4a7c15));
        mixed ^= (uint64_t)bytes[index] * UINT64_C(0xbf58476d1ce4e5b9);
        mixed ^= mixed >> 30;
        mixed *= UINT64_C(0xbf58476d1ce4e5b9);
        mixed ^= mixed >> 27;
        mixed *= UINT64_C(0x94d049bb133111eb);
        mixed ^= mixed >> 31;
        if ((mixed & 31) != 0) {
            continue;
        }
        NSInteger delta = (mixed & 32) ? 1 : -1;
        NSInteger value = (NSInteger)bytes[index] + delta;
        bytes[index] = (uint8_t)MAX(0, MIN(255, value));
    }
    return [output copy];
}

- (NSString *)javaScriptSource {
    NSDictionary *configuration = @{
        @"generationID": self.generationID,
        @"seed": @((uint32_t)(self.canvasNoiseSeed & UINT32_MAX)),
        @"webGL": self.webGL
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:configuration options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (json.length == 0) {
        return @"";
    }
    NSString *template =
        @"(function(){'use strict';"
         "const marker='__pxGraphicsIdentity_v1';"
         "const incoming=%@;"
         "if(Object.prototype.hasOwnProperty.call(globalThis,marker)){const existing=globalThis[marker];if(existing&&typeof existing.update==='function'){existing.update(incoming);}return;}"
         "let cfg=incoming;"
         "const state={generationID:cfg.generationID,enabled:true,update:function(next){cfg=next;state.generationID=next.generationID;state.enabled=true;},disable:function(){state.enabled=false;}};"
         "Object.defineProperty(globalThis,marker,{value:state,enumerable:false,writable:false,configurable:false});"
         "function hashText(text,seed){let h=seed>>>0;for(let i=0;i<text.length;i++){h=Math.imul(h^text.charCodeAt(i),16777619)>>>0;}return h>>>0;}"
         "function mix(value){value^=value>>>16;value=Math.imul(value,2246822507)>>>0;value^=value>>>13;value=Math.imul(value,3266489909)>>>0;return(value^(value>>>16))>>>0;}"
         "function noiseBytes(bytes,domain){const base=hashText(domain,cfg.seed);for(let i=0;i<bytes.length;i++){const h=mix(base^Math.imul(i+1,2654435761)^bytes[i]);if((h&31)!==0){continue;}const delta=(h&32)!==0?1:-1;bytes[i]=Math.max(0,Math.min(255,bytes[i]+delta));}return bytes;}"
         "function copied2DCanvas(source){try{let copy;if(typeof OffscreenCanvas!=='undefined'&&source instanceof OffscreenCanvas){copy=new OffscreenCanvas(source.width,source.height);}else if(typeof document!=='undefined'&&document.createElement){copy=document.createElement('canvas');copy.width=source.width;copy.height=source.height;}else{return null;}const context=copy.getContext('2d');if(!context){return null;}context.drawImage(source,0,0);const image=context.getImageData(0,0,copy.width,copy.height);const bytes=new Uint8ClampedArray(image.data);noiseBytes(bytes,'canvas-export:'+copy.width+'x'+copy.height);const protectedImage=typeof ImageData!=='undefined'?new ImageData(bytes,image.width,image.height):image;if(protectedImage===image){image.data.set(bytes);}context.putImageData(protectedImage,0,0);return copy;}catch(error){return null;}}"
         "if(typeof HTMLCanvasElement!=='undefined'){const proto=HTMLCanvasElement.prototype;const originalToDataURL=proto.toDataURL;const originalToBlob=proto.toBlob;if(typeof originalToDataURL==='function'){proto.toDataURL=function(){if(!state.enabled){return originalToDataURL.apply(this,arguments);}const copy=copied2DCanvas(this);return copy?originalToDataURL.apply(copy,arguments):originalToDataURL.apply(this,arguments);};}if(typeof originalToBlob==='function'){proto.toBlob=function(){if(!state.enabled){return originalToBlob.apply(this,arguments);}const copy=copied2DCanvas(this);return copy?originalToBlob.apply(copy,arguments):originalToBlob.apply(this,arguments);};}}"
         "if(typeof CanvasRenderingContext2D!=='undefined'){const proto=CanvasRenderingContext2D.prototype;const originalGetImageData=proto.getImageData;if(typeof originalGetImageData==='function'){proto.getImageData=function(){const image=originalGetImageData.apply(this,arguments);if(!state.enabled||!image||!image.data){return image;}const bytes=new Uint8ClampedArray(image.data);noiseBytes(bytes,'canvas-read:'+image.width+'x'+image.height);if(typeof ImageData!=='undefined'){return new ImageData(bytes,image.width,image.height);}image.data.set(bytes);return image;};}}"
         "if(typeof OffscreenCanvas!=='undefined'){const proto=OffscreenCanvas.prototype;const originalConvertToBlob=proto.convertToBlob;if(typeof originalConvertToBlob==='function'){proto.convertToBlob=function(){if(!state.enabled){return originalConvertToBlob.apply(this,arguments);}const copy=copied2DCanvas(this);return copy?originalConvertToBlob.apply(copy,arguments):originalConvertToBlob.apply(this,arguments);};}}"
         "function installWebGL(Constructor,webgl2){if(typeof Constructor==='undefined'||!Constructor.prototype){return;}const proto=Constructor.prototype;const originalGetParameter=proto.getParameter;const originalGetSupportedExtensions=proto.getSupportedExtensions;const originalGetExtension=proto.getExtension;const originalGetShaderPrecisionFormat=proto.getShaderPrecisionFormat;const originalReadPixels=proto.readPixels;const limits={3379:'maxTextureSize',34076:'maxCubeMapTextureSize',34024:'maxRenderbufferSize',34930:'maxTextureImageUnits',35660:'maxVertexTextureImageUnits',35661:'maxCombinedTextureImageUnits',34921:'maxVertexAttribs',36347:'maxVertexUniformVectors',36349:'maxFragmentUniformVectors',36348:'maxVaryingVectors'};"
         "if(typeof originalGetParameter==='function'){proto.getParameter=function(parameter){const host=originalGetParameter.call(this,parameter);if(!state.enabled){return host;}if(parameter===7936){return cfg.webGL.vendor;}if(parameter===7937){return cfg.webGL.renderer;}if(parameter===7938){return webgl2?cfg.webGL.version:'WebGL 1.0';}if(parameter===35724){return webgl2?cfg.webGL.shadingLanguageVersion:'WebGL GLSL ES 1.0';}if(parameter===37445){return cfg.webGL.unmaskedVendor;}if(parameter===37446){return cfg.webGL.unmaskedRenderer;}const key=limits[parameter];if(key&&typeof host==='number'){return Math.min(host,Number(cfg.webGL[key]));}return host;};}"
         "if(typeof originalGetSupportedExtensions==='function'){proto.getSupportedExtensions=function(){const host=originalGetSupportedExtensions.call(this);if(!state.enabled||!host){return host;}return cfg.webGL.extensions.filter(function(extension){return host.indexOf(extension)!==-1;});};}"
         "if(typeof originalGetExtension==='function'){proto.getExtension=function(name){if(!state.enabled){return originalGetExtension.call(this,name);}if(cfg.webGL.extensions.indexOf(name)===-1){return null;}return originalGetExtension.call(this,name);};}"
         "if(typeof originalGetShaderPrecisionFormat==='function'){proto.getShaderPrecisionFormat=function(){const host=originalGetShaderPrecisionFormat.apply(this,arguments);if(!state.enabled||!host){return host;}const target=cfg.webGL.precision;const result=Object.create(Object.getPrototypeOf(host));Object.defineProperties(result,{rangeMin:{value:Math.max(Number(host.rangeMin),Number(target.rangeMin)),enumerable:true},rangeMax:{value:Math.min(Number(host.rangeMax),Number(target.rangeMax)),enumerable:true},precision:{value:Math.min(Number(host.precision),Number(target.precision)),enumerable:true}});return result;};}"
         "if(typeof originalReadPixels==='function'){proto.readPixels=function(){const result=originalReadPixels.apply(this,arguments);if(!state.enabled){return result;}const pixels=arguments[6];if(pixels&&ArrayBuffer.isView(pixels)){const bytes=new Uint8Array(pixels.buffer,pixels.byteOffset,pixels.byteLength);noiseBytes(bytes,webgl2?'webgl2-read':'webgl1-read');}return result;};}}"
         "installWebGL(typeof WebGLRenderingContext==='undefined'?undefined:WebGLRenderingContext,false);"
         "installWebGL(typeof WebGL2RenderingContext==='undefined'?undefined:WebGL2RenderingContext,true);"
         "})();";
    return [NSString stringWithFormat:template, json];
}

@end

static BOOL PXGraphicsIdentityFitsHostCapabilities(
    PXGraphicsIdentity *identity,
    NSDictionary<NSString *, id> *hostCapabilities,
    NSError **error
) {
    NSNumber *requiredFamily = identity.metalFamilies.lastObject;
    NSSet<NSNumber *> *hostFamilies = [NSSet setWithArray:hostCapabilities[@"metalFamilies"]];
    NSInteger targetTexture = [identity.webGL[@"maxTextureSize"] integerValue];
    NSInteger targetRenderbuffer = [identity.webGL[@"maxRenderbufferSize"] integerValue];
    if (!requiredFamily || ![hostFamilies containsObject:requiredFamily] ||
        [hostCapabilities[@"maxTextureSize"] integerValue] < targetTexture ||
        [hostCapabilities[@"maxRenderbufferSize"] integerValue] < targetRenderbuffer ||
        ![hostCapabilities[@"supportsOpenGLES3"] boolValue]) {
        return PXGraphicsFail(error, 3, @"Selected graphics model exceeds host capabilities");
    }
    return YES;
}

BOOL PXGraphicsModelRecordIsCompatibleWithHostCapabilities(
    NSDictionary<NSString *, id> *modelRecord,
    NSDictionary<NSString *, id> *hostCapabilities,
    NSError **error
) {
    PXGraphicsIdentity *identity = [PXGraphicsIdentity
        identityWithModelRecord:modelRecord
        profileSeed:@"compatibility-probe"
        generationID:@"00000000-0000-4000-8000-000000000001"
        hostCapabilities:hostCapabilities
        error:error];
    return identity && PXGraphicsIdentityFitsHostCapabilities(identity, hostCapabilities, error);
}

static NSArray<NSString *> *PXModelRecordInvalidImmutableFields(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) {
        return @[
            PXModelCompatibilityFieldMarketingFamily,
            PXModelCompatibilityFieldCPUClass,
            PXModelCompatibilityFieldGraphicsClass,
            PXModelCompatibilityFieldMemoryClass,
            PXModelCompatibilityFieldDisplayClass
        ];
    }
    NSDictionary<NSString *, id> *record = value;
    NSMutableArray<NSString *> *invalidFields = [NSMutableArray array];
    NSString *identifier = [record[@"identifier"] isKindOfClass:[NSString class]]
        ? record[@"identifier"]
        : nil;
    NSString *name = [record[@"name"] isKindOfClass:[NSString class]]
        ? record[@"name"]
        : nil;
    if (![identifier hasPrefix:@"iPhone"] || name.length == 0) {
        [invalidFields addObject:PXModelCompatibilityFieldMarketingFamily];
    }
    if (![record[@"cpuArchitecture"] isKindOfClass:[NSString class]] ||
        [record[@"cpuArchitecture"] length] == 0 ||
        ![record[@"cpuCoreCount"] isKindOfClass:[NSNumber class]]) {
        [invalidFields addObject:PXModelCompatibilityFieldCPUClass];
    }
    if (![record[@"gpuFamily"] isKindOfClass:[NSString class]] ||
        [record[@"gpuFamily"] length] == 0 ||
        ![record[@"metalFeatureSet"] isKindOfClass:[NSString class]] ||
        [record[@"metalFeatureSet"] length] == 0 ||
        ![record[@"webGLInfo"] isKindOfClass:[NSDictionary class]]) {
        [invalidFields addObject:PXModelCompatibilityFieldGraphicsClass];
    }
    if (![record[@"deviceMemory"] isKindOfClass:[NSNumber class]]) {
        [invalidFields addObject:PXModelCompatibilityFieldMemoryClass];
    }
    BOOL displayIsValid = [record[@"screenResolution"] isKindOfClass:[NSString class]] &&
        [record[@"screenResolution"] length] > 0 &&
        [record[@"viewportResolution"] isKindOfClass:[NSString class]] &&
        [record[@"viewportResolution"] length] > 0 &&
        [record[@"devicePixelRatio"] isKindOfClass:[NSNumber class]] &&
        [record[@"screenDensity"] isKindOfClass:[NSNumber class]];
    if (!displayIsValid) {
        [invalidFields addObject:PXModelCompatibilityFieldDisplayClass];
    }
    return [invalidFields copy];
}

static BOOL PXModelCompatibilityFail(
    NSError **error,
    PXModelCompatibilityErrorCode code,
    NSString *reason,
    NSArray<NSString *> *mismatchFields,
    NSString *description,
    NSError *underlyingError
) {
    if (error) {
        NSMutableDictionary<NSString *, id> *userInfo = [@{
            NSLocalizedDescriptionKey: description,
            PXModelCompatibilityReasonErrorKey: reason,
            PXModelCompatibilityMismatchFieldsErrorKey: mismatchFields ?: @[]
        } mutableCopy];
        if (underlyingError) {
            userInfo[NSUnderlyingErrorKey] = underlyingError;
        }
        *error = [NSError errorWithDomain:PXModelCompatibilityErrorDomain
                                     code:code
                                 userInfo:[userInfo copy]];
    }
    return NO;
}

BOOL PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
    NSDictionary<NSString *, id> *candidateModelRecord,
    NSDictionary<NSString *, id> *physicalModelRecord,
    NSDictionary<NSString *, id> *hostCapabilities,
    NSError **error
) {
    NSArray<NSString *> *invalidPhysicalFields =
        PXModelRecordInvalidImmutableFields(physicalModelRecord);
    if (invalidPhysicalFields.count > 0) {
        return PXModelCompatibilityFail(
            error,
            PXModelCompatibilityErrorPhysicalUnavailable,
            PXModelCompatibilityReasonPhysicalUnavailable,
            invalidPhysicalFields,
            @"The physical iPhone hardware signature could not be verified",
            nil);
    }
    if (!PXGraphicsHostCapabilitiesAreValid(hostCapabilities)) {
        return PXModelCompatibilityFail(
            error,
            PXModelCompatibilityErrorHostCapabilitiesUnavailable,
            PXModelCompatibilityReasonHostCapabilitiesUnavailable,
            @[PXModelCompatibilityFieldHostGraphics],
            @"The physical iPhone graphics capabilities could not be verified",
            nil);
    }
    NSArray<NSString *> *invalidCandidateFields =
        PXModelRecordInvalidImmutableFields(candidateModelRecord);
    if (invalidCandidateFields.count > 0) {
        return PXModelCompatibilityFail(
            error,
            PXModelCompatibilityErrorCandidateInvalid,
            PXModelCompatibilityReasonCandidateInvalid,
            invalidCandidateFields,
            @"The selected iPhone catalog record has incomplete hardware data",
            nil);
    }

    NSError *graphicsError = nil;
    PXGraphicsIdentity *physicalGraphics = [PXGraphicsIdentity
        identityWithModelRecord:physicalModelRecord
        profileSeed:@"physical-compatibility-validation"
        generationID:@"00000000-0000-4000-8000-000000000003"
        hostCapabilities:hostCapabilities
        error:&graphicsError];
    if (!physicalGraphics || !PXGraphicsModelRecordIsCompatibleWithHostCapabilities(
        physicalModelRecord,
        hostCapabilities,
        &graphicsError)) {
        return PXModelCompatibilityFail(
            error,
            PXModelCompatibilityErrorHostCapabilitiesUnavailable,
            PXModelCompatibilityReasonHostCapabilitiesUnavailable,
            @[PXModelCompatibilityFieldHostGraphics],
            @"The detected physical iPhone record does not match its graphics capabilities",
            graphicsError);
    }

    PXGraphicsIdentity *candidateGraphics = [PXGraphicsIdentity
        identityWithModelRecord:candidateModelRecord
        profileSeed:@"candidate-compatibility-validation"
        generationID:@"00000000-0000-4000-8000-000000000004"
        hostCapabilities:hostCapabilities
        error:&graphicsError];
    if (!candidateGraphics) {
        return PXModelCompatibilityFail(
            error,
            PXModelCompatibilityErrorCandidateInvalid,
            PXModelCompatibilityReasonCandidateInvalid,
            @[PXModelCompatibilityFieldGraphicsClass],
            @"The selected iPhone catalog record has invalid graphics data",
            graphicsError);
    }

    NSMutableArray<NSString *> *mismatchFields = [NSMutableArray array];
    if (![candidateModelRecord[@"name"] isEqual:physicalModelRecord[@"name"]]) {
        [mismatchFields addObject:PXModelCompatibilityFieldMarketingFamily];
    }
    if (![candidateModelRecord[@"cpuArchitecture"] isEqual:physicalModelRecord[@"cpuArchitecture"]] ||
        ![candidateModelRecord[@"cpuCoreCount"] isEqual:physicalModelRecord[@"cpuCoreCount"]]) {
        [mismatchFields addObject:PXModelCompatibilityFieldCPUClass];
    }
    if (![candidateModelRecord[@"gpuFamily"] isEqual:physicalModelRecord[@"gpuFamily"]] ||
        ![candidateModelRecord[@"metalFeatureSet"] isEqual:physicalModelRecord[@"metalFeatureSet"]]) {
        [mismatchFields addObject:PXModelCompatibilityFieldGraphicsClass];
    }
    if (![candidateModelRecord[@"deviceMemory"] isEqual:physicalModelRecord[@"deviceMemory"]]) {
        [mismatchFields addObject:PXModelCompatibilityFieldMemoryClass];
    }
    NSArray<NSString *> *displayKeys = @[
        @"screenResolution",
        @"viewportResolution",
        @"devicePixelRatio",
        @"screenDensity"
    ];
    for (NSString *key in displayKeys) {
        if (![candidateModelRecord[key] isEqual:physicalModelRecord[key]]) {
            [mismatchFields addObject:PXModelCompatibilityFieldDisplayClass];
            break;
        }
    }
    if (mismatchFields.count > 0) {
        return PXModelCompatibilityFail(
            error,
            PXModelCompatibilityErrorImmutableHardwareMismatch,
            PXModelCompatibilityReasonImmutableHardwareMismatch,
            [mismatchFields copy],
            [NSString stringWithFormat:
                @"The selected iPhone does not match the physical hardware signature (%@)",
                [mismatchFields componentsJoinedByString:@", "]],
            nil);
    }
    if (!PXGraphicsModelRecordIsCompatibleWithHostCapabilities(
        candidateModelRecord,
        hostCapabilities,
        &graphicsError)) {
        return PXModelCompatibilityFail(
            error,
            PXModelCompatibilityErrorHostCapabilitiesUnavailable,
            PXModelCompatibilityReasonHostCapabilitiesUnavailable,
            @[PXModelCompatibilityFieldHostGraphics],
            @"The selected iPhone graphics profile cannot execute on this device",
            graphicsError);
    }
    if (error) {
        *error = nil;
    }
    return YES;
}
