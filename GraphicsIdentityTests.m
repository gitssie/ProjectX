#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#include <assert.h>

#import "GraphicsIdentity.h"

static NSDictionary<NSString *, id> *modelRecord(NSString *identifier,
                                                  NSString *gpuFamily,
                                                  NSString *metalFeatureSet,
                                                  NSInteger textureLimit) {
    return @{
        @"identifier": identifier,
        @"gpuFamily": gpuFamily,
        @"metalFeatureSet": metalFeatureSet,
        @"webGLInfo": @{
            @"unmaskedVendor": @"Apple Inc.",
            @"unmaskedRenderer": gpuFamily,
            @"webglVendor": @"Apple",
            @"webglRenderer": @"Apple GPU",
            @"webglVersion": @"WebGL 2.0",
            @"maxTextureSize": @(textureLimit),
            @"maxRenderBufferSize": @(textureLimit)
        }
    };
}

static NSDictionary<NSString *, id> *hostCapabilities(NSInteger metalFamily,
                                                       NSInteger textureLimit) {
    NSMutableArray<NSNumber *> *families = [NSMutableArray array];
    for (NSInteger family = 1001; family <= metalFamily; family++) {
        [families addObject:@(family)];
    }
    return @{
        @"metalFamilies": [families copy],
        @"metalFeatureSets": @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9,
                                @10, @11, @12, @13, @14, @15, @16],
        @"maxTextureSize": @(textureLimit),
        @"maxRenderbufferSize": @(textureLimit),
        @"supportsOpenGLES3": @YES
    };
}

static NSDictionary<NSString *, id> *hardwareModelRecord(
    NSString *identifier,
    NSString *name,
    NSString *cpu,
    NSInteger cpuCores,
    NSString *gpu,
    NSString *metal,
    NSInteger memory,
    NSString *screenResolution,
    NSString *viewportResolution,
    NSNumber *pixelRatio,
    NSInteger density
) {
    NSMutableDictionary<NSString *, id> *record = [modelRecord(
        identifier,
        gpu,
        metal,
        16384) mutableCopy];
    [record addEntriesFromDictionary:@{
        @"name": name,
        @"cpuArchitecture": cpu,
        @"cpuCoreCount": @(cpuCores),
        @"deviceMemory": @(memory),
        @"screenResolution": screenResolution,
        @"viewportResolution": viewportResolution,
        @"devicePixelRatio": pixelRatio,
        @"screenDensity": @(density)
    }];
    return [record copy];
}

static uint64_t compositeGraphicsFingerprint(PXGraphicsIdentity *identity, NSData *canvasInput) {
    NSData *canvasOutput = [identity deterministicallyNoisedBytes:canvasInput
                                                           domain:@"fingerprintjs-canvas"];
    NSMutableData *components = [canvasOutput mutableCopy];
    NSArray<NSString *> *webGLKeys = @[
        @"vendor", @"renderer", @"unmaskedVendor", @"unmaskedRenderer",
        @"version", @"shadingLanguageVersion"
    ];
    for (NSString *key in webGLKeys) {
        NSData *value = [[identity.webGL[key] description] dataUsingEncoding:NSUTF8StringEncoding];
        [components appendData:value ?: [NSData data]];
    }
    uint64_t hash = UINT64_C(1469598103934665603);
    const uint8_t *bytes = components.bytes;
    for (NSUInteger index = 0; index < components.length; index++) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void testImmutableHardwareCompatibilityClassifiesRegionalVariants(void) {
    NSDictionary<NSString *, id> *physical = hardwareModelRecord(
        @"iPhone9,2", @"iPhone 7 Plus", @"Apple A10 Fusion", 4,
        @"Apple A10 GPU", @"Metal 2.2", 3, @"1920x1080", @"2208x1242", @3, 401);
    NSDictionary<NSString *, id> *regionalVariant = hardwareModelRecord(
        @"iPhone9,4", @"iPhone 7 Plus", @"Apple A10 Fusion", 4,
        @"Apple A10 GPU", @"Metal 2.2", 3, @"1920x1080", @"2208x1242", @3, 401);
    NSDictionary<NSString *, id> *smallerIPhone = hardwareModelRecord(
        @"iPhone9,1", @"iPhone 7", @"Apple A10 Fusion", 4,
        @"Apple A10 GPU", @"Metal 2.2", 2, @"1334x750", @"1334x750", @2, 326);
    NSDictionary<NSString *, id> *otherSmallerIPhone = hardwareModelRecord(
        @"iPhone9,3", @"iPhone 7", @"Apple A10 Fusion", 4,
        @"Apple A10 GPU", @"Metal 2.2", 2, @"1334x750", @"1334x750", @2, 326);
    NSDictionary<NSString *, id> *newerIPhone = hardwareModelRecord(
        @"iPhone15,2", @"iPhone 14 Pro", @"Apple A16 Bionic", 6,
        @"Apple A16 Pro GPU", @"Metal 3.1", 6, @"2556x1179", @"2556x1179", @3, 460);
    NSDictionary<NSString *, id> *a10Host = hostCapabilities(1003, 16384);
    NSError *error = nil;

    assert(PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        physical, physical, a10Host, &error));
    assert(error == nil);
    assert(PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        regionalVariant, physical, a10Host, &error));
    assert(error == nil);

    assert(!PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        smallerIPhone, physical, a10Host, &error));
    assert([error.domain isEqualToString:PXModelCompatibilityErrorDomain]);
    assert(error.code == PXModelCompatibilityErrorImmutableHardwareMismatch);
    NSArray<NSString *> *smallerMismatchFields =
        error.userInfo[PXModelCompatibilityMismatchFieldsErrorKey];
    assert([smallerMismatchFields containsObject:PXModelCompatibilityFieldMarketingFamily]);
    assert([smallerMismatchFields containsObject:PXModelCompatibilityFieldMemoryClass]);
    assert([smallerMismatchFields containsObject:PXModelCompatibilityFieldDisplayClass]);
    assert(!PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        otherSmallerIPhone, physical, a10Host, nil));

    error = nil;
    assert(!PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        newerIPhone, physical, a10Host, &error));
    NSArray<NSString *> *newerMismatchFields =
        error.userInfo[PXModelCompatibilityMismatchFieldsErrorKey];
    assert([newerMismatchFields containsObject:PXModelCompatibilityFieldCPUClass]);
    assert([newerMismatchFields containsObject:PXModelCompatibilityFieldGraphicsClass]);

    error = nil;
    NSMutableDictionary<NSString *, id> *malformedPhysical = [physical mutableCopy];
    [malformedPhysical removeObjectForKey:@"gpuFamily"];
    assert(!PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        regionalVariant, malformedPhysical, a10Host, &error));
    assert(error.code == PXModelCompatibilityErrorPhysicalUnavailable);
    assert([error.userInfo[PXModelCompatibilityReasonErrorKey]
        isEqualToString:PXModelCompatibilityReasonPhysicalUnavailable]);

    error = nil;
    NSMutableDictionary<NSString *, id> *malformedHost = [a10Host mutableCopy];
    [malformedHost removeObjectForKey:@"metalFamilies"];
    assert(!PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        regionalVariant, physical, malformedHost, &error));
    assert(error.code == PXModelCompatibilityErrorHostCapabilitiesUnavailable);

    error = nil;
    NSDictionary<NSString *, id> *emptyHostProbe = @{
        @"metalFamilies": @[],
        @"metalFeatureSets": @[],
        @"maxTextureSize": @0,
        @"maxRenderbufferSize": @0,
        @"supportsOpenGLES3": @NO
    };
    assert(!PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
        regionalVariant, physical, emptyHostProbe, &error));
    assert(error.code == PXModelCompatibilityErrorHostCapabilitiesUnavailable);
}

static void testModelDerivedGraphicsIdentityIsCoherentAndHostSafe(void) {
    NSDictionary *model = modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 16384);
    NSError *error = nil;
    PXGraphicsIdentity *identity = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"11111111-1111-4111-8111-111111111111"
        hostCapabilities:hostCapabilities(1008, 16384)
        error:&error];
    assert(identity != nil && error == nil);
    assert([identity.modelIdentifier isEqualToString:@"iPhone13,2"]);
    assert([identity.gpuName isEqualToString:@"Apple A14 GPU"]);
    assert([identity.webGL[@"unmaskedRenderer"] isEqualToString:identity.gpuName]);
    assert([identity.openGL[@"renderer"] isEqualToString:identity.gpuName]);
    assert([identity.webGL[@"maxTextureSize"] integerValue] == 16384);
    assert([identity.openGL[@"maxTextureSize"] integerValue] == 16384);
    assert([identity.metalFamilies containsObject:@1007]);
    assert(![identity.metalFamilies containsObject:@1008]);
    assert([identity validateAgainstModelRecord:model
                               hostCapabilities:hostCapabilities(1008, 16384)
                                          error:&error]);
}

static void testEveryCatalogGraphicsFamilyHasOneCoherentDescription(void) {
    NSArray<NSArray<NSString *> *> *families = @[
        @[@"Apple A10 GPU", @"Metal 2.2"], @[@"Apple A11 GPU", @"Metal 2.3"],
        @[@"Apple A12 GPU", @"Metal 2.4"], @[@"Apple A12X GPU", @"Metal 2.4"],
        @[@"Apple A12Z GPU", @"Metal 2.4"], @[@"Apple A13 GPU", @"Metal 3.0"],
        @[@"Apple A14 GPU", @"Metal 3.0"], @[@"Apple A15 GPU", @"Metal 3.0"],
        @[@"Apple M1 GPU", @"Metal 3.0"], @[@"Apple A16 GPU", @"Metal 3.0"],
        @[@"Apple A16 Pro GPU", @"Metal 3.1"], @[@"Apple M2 GPU", @"Metal 3.1"],
        @[@"Apple A17 Pro GPU", @"Metal 3.1"]
    ];
    for (NSArray<NSString *> *family in families) {
        NSDictionary *description = PXGraphicsModelDescription(
            family[0], family[1], modelRecord(@"model", family[0], family[1], 16384)[@"webGLInfo"]);
        assert(description.count > 0);
        assert([description[@"gpuFamily"] isEqualToString:family[0]]);
        assert([description[@"metalFeatureSetName"] isEqualToString:family[1]]);
    }
    NSDictionary *incoherent = PXGraphicsModelDescription(
        @"Apple A12 GPU", @"Metal 3.1",
        modelRecord(@"model", @"Apple A12 GPU", @"Metal 3.1", 8192)[@"webGLInfo"]);
    assert(incoherent.count == 0);
}

static void testNewerLogicalIdentityRetainsHostExecutionLimits(void) {
    NSDictionary *model = modelRecord(@"iPhone15,2", @"Apple A16 Pro GPU", @"Metal 3.1", 16384);
    NSDictionary *a10Host = hostCapabilities(1003, 16384);
    NSError *error = nil;
    PXGraphicsIdentity *identity = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"22222222-2222-4222-8222-222222222222"
        hostCapabilities:a10Host
        error:&error];
    assert(identity != nil);
    assert(error == nil);
    assert([identity.modelIdentifier isEqualToString:@"iPhone15,2"]);
    assert([identity.gpuName isEqualToString:@"Apple A16 Pro GPU"]);
    assert([identity.metalFeatureSetName isEqualToString:@"Metal 3.1"]);
    assert([identity.metalFamilies containsObject:@1008]);
    assert([identity.hostCapabilities isEqualToDictionary:a10Host]);
    assert([identity validateAgainstModelRecord:model
                               hostCapabilities:a10Host
                                          error:&error]);

    error = nil;
    assert(!PXGraphicsModelRecordIsCompatibleWithHostCapabilities(
        model,
        a10Host,
        &error));
    assert([error.domain isEqualToString:PXGraphicsIdentityErrorDomain]);
    assert(error.code == 3);
    assert(PXGraphicsModelRecordIsCompatibleWithHostCapabilities(
        modelRecord(@"iPhone9,2", @"Apple A10 GPU", @"Metal 2.2", 16384),
        hostCapabilities(1003, 16384),
        nil));
}

static void testDeprecatedFeatureSetEnumerationIsDiagnosticOnly(void) {
    NSDictionary<NSString *, id> *model = modelRecord(
        @"iPhone9,2",
        @"Apple A10 GPU",
        @"Metal 2.2",
        16384);
    NSDictionary<NSString *, id> *host = @{
        @"metalFamilies": @[@1001, @1002, @1003],
        @"metalFeatureSets": @[],
        @"maxTextureSize": @16384,
        @"maxRenderbufferSize": @16384,
        @"supportsOpenGLES3": @YES
    };
    NSError *error = nil;

    assert(PXGraphicsModelRecordIsCompatibleWithHostCapabilities(model, host, &error));
    assert(error == nil);
}

static void testCanvasNoiseIsStableForIdentityAndChangesWithGeneration(void) {
    NSDictionary *model = modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 16384);
    NSDictionary *host = hostCapabilities(1008, 16384);
    PXGraphicsIdentity *first = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"33333333-3333-4333-8333-333333333333"
        hostCapabilities:host
        error:nil];
    PXGraphicsIdentity *second = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"44444444-4444-4444-8444-444444444444"
        hostCapabilities:host
        error:nil];
    NSMutableData *input = [NSMutableData dataWithLength:4096];
    uint8_t *bytes = input.mutableBytes;
    for (NSUInteger index = 0; index < input.length; index++) {
        bytes[index] = (uint8_t)(index % 251);
    }
    NSData *originalInput = [input copy];
    NSData *firstOutput = [first deterministicallyNoisedBytes:input domain:@"canvas-export"];
    NSData *repeatedOutput = [first deterministicallyNoisedBytes:input domain:@"canvas-export"];
    NSData *secondOutput = [second deterministicallyNoisedBytes:input domain:@"canvas-export"];
    assert([firstOutput isEqualToData:repeatedOutput]);
    assert(![firstOutput isEqualToData:input]);
    assert(![firstOutput isEqualToData:secondOutput]);
    assert([input isEqualToData:originalInput]);
}

static void testAutomaticProtectionChangesCompositeFingerprintAcrossGenerations(void) {
    assert(PXGraphicsProtectionIsEnabledForSettings(nil));
    assert(PXGraphicsProtectionIsEnabledForSettings(@{}));
    assert(PXGraphicsProtectionIsEnabledForSettings(@{@"canvasFingerprintingEnabled": @YES}));
    assert(!PXGraphicsProtectionIsEnabledForSettings(@{@"canvasFingerprintingEnabled": @NO}));
    assert(PXGraphicsProtectionIsEnabledForSettings(@{@"CanvasFingerprint": @YES}));
    assert(!PXGraphicsProtectionIsEnabledForSettings(@{@"CanvasFingerprint": @NO}));
    assert(!PXGraphicsProtectionIsEnabledForSettings(@{@"canvasFingerprintingEnabled": @"invalid"}));

    NSDictionary *model = modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 16384);
    NSDictionary *host = hostCapabilities(1008, 16384);
    PXGraphicsIdentity *first = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"first-profile-seed"
        generationID:@"12121212-1212-4212-8212-121212121212"
        hostCapabilities:host
        error:nil];
    PXGraphicsIdentity *second = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"first-profile-seed"
        generationID:@"34343434-3434-4434-8434-343434343434"
        hostCapabilities:host
        error:nil];
    NSMutableData *canvasInput = [NSMutableData dataWithLength:4096];
    uint8_t *bytes = canvasInput.mutableBytes;
    for (NSUInteger index = 0; index < canvasInput.length; index++) {
        bytes[index] = (uint8_t)(index % 251);
    }

    uint64_t firstFingerprint = compositeGraphicsFingerprint(first, canvasInput);
    assert(firstFingerprint == compositeGraphicsFingerprint(first, canvasInput));
    assert(firstFingerprint != compositeGraphicsFingerprint(second, canvasInput));
}

static void testUserScriptSelectionRefreshesStaleGenerationWithoutDuplicates(void) {
    NSDictionary *model = modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 16384);
    NSDictionary *host = hostCapabilities(1008, 16384);
    PXGraphicsIdentity *first = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"56565656-5656-4656-8656-565656565656"
        hostCapabilities:host
        error:nil];
    PXGraphicsIdentity *second = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"78787878-7878-4878-8878-787878787878"
        hostCapabilities:host
        error:nil];
    NSString *firstSource = [first javaScriptSource];
    NSString *secondSource = [second javaScriptSource];

    assert(!PXGraphicsUserScriptsNeedCurrentSource(@[firstSource], firstSource));
    assert(PXGraphicsUserScriptsNeedCurrentSource(@[firstSource], secondSource));
    assert(PXGraphicsUserScriptsNeedCurrentSource(@[@"window.hostScript=true;"], secondSource));
    assert(!PXGraphicsUserScriptsNeedCurrentSource(@[], @""));
}

static void testGeneratedScriptIsDeterministicIdempotentAndGraphicsOnly(void) {
    NSDictionary *model = modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 16384);
    NSDictionary *host = hostCapabilities(1008, 16384);
    PXGraphicsIdentity *first = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"55555555-5555-4555-8555-555555555555"
        hostCapabilities:host
        error:nil];
    PXGraphicsIdentity *otherGeneration = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"66666666-6666-4666-8666-666666666666"
        hostCapabilities:host
        error:nil];
    NSString *source = [first javaScriptSource];
    assert(source.length > 1000);
    assert([source isEqualToString:[first javaScriptSource]]);
    assert(![source isEqualToString:[otherGeneration javaScriptSource]]);
    assert([source containsString:@"__pxGraphicsIdentity_v1"]);
    assert([source containsString:@"enumerable:false"]);
    assert([source containsString:@"new Uint8ClampedArray"]);
    assert([source containsString:@"WebGL2RenderingContext"]);
    assert([source containsString:@"OffscreenCanvas"]);
    assert([source rangeOfString:@"Math.random"].location == NSNotFound);
    assert([source rangeOfString:@"console."].location == NSNotFound);
    assert([source rangeOfString:@"AudioBuffer"].location == NSNotFound);
    assert([source rangeOfString:@"AnalyserNode"].location == NSNotFound);
    assert([source rangeOfString:@"measureText"].location == NSNotFound);
    assert([source rangeOfString:@"fillText"].location == NSNotFound);
}

static void testGeneratedScriptPreservesCanvasStateAndWebGLTypes(void) {
    NSDictionary *model = modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 16384);
    PXGraphicsIdentity *identity = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"77777777-7777-4777-8777-777777777777"
        hostCapabilities:hostCapabilities(1008, 16384)
        error:nil];
    JSContext *context = [[JSContext alloc] init];
    [context evaluateScript:
        @"function ImageData(data,width,height){this.data=data;this.width=width;this.height=height;}"
         "function CanvasRenderingContext2D(canvas){this.canvas=canvas;}"
         "CanvasRenderingContext2D.prototype.drawImage=function(source){this.canvas.pixels=new Uint8ClampedArray(source.pixels);};"
         "CanvasRenderingContext2D.prototype.getImageData=function(){return new ImageData(new Uint8ClampedArray(this.canvas.pixels),this.canvas.width,this.canvas.height);};"
         "CanvasRenderingContext2D.prototype.putImageData=function(image){this.canvas.pixels=new Uint8ClampedArray(image.data);};"
         "function HTMLCanvasElement(){this.width=8;this.height=8;this.pixels=new Uint8ClampedArray(256);for(let i=0;i<256;i++){this.pixels[i]=i&255;}this.context=new CanvasRenderingContext2D(this);}"
         "HTMLCanvasElement.prototype.getContext=function(kind){return kind==='2d'?this.context:null;};"
         "HTMLCanvasElement.prototype.toDataURL=function(){return Array.from(this.pixels).join(',');};"
         "HTMLCanvasElement.prototype.toBlob=function(callback){callback(Array.from(this.pixels).join(','));};"
         "function OffscreenCanvas(width,height){HTMLCanvasElement.call(this);this.width=width;this.height=height;}"
         "OffscreenCanvas.prototype=Object.create(HTMLCanvasElement.prototype);"
         "OffscreenCanvas.prototype.constructor=OffscreenCanvas;"
         "OffscreenCanvas.prototype.convertToBlob=function(){return Promise.resolve(Array.from(this.pixels).join(','));};"
         "var document={createElement:function(){return new HTMLCanvasElement();}};"
         "function WebGLRenderingContext(){}"
         "WebGLRenderingContext.prototype.getParameter=function(parameter){if(parameter===3379||parameter===34024){return 32768;}return 'host';};"
         "WebGLRenderingContext.prototype.getSupportedExtensions=function(){return ['WEBGL_debug_renderer_info','OES_element_index_uint','HOST_only'];};"
         "WebGLRenderingContext.prototype.getExtension=function(name){return {name:name};};"
         "WebGLRenderingContext.prototype.getShaderPrecisionFormat=function(){return {rangeMin:127,rangeMax:127,precision:24};};"
         "WebGLRenderingContext.prototype.readPixels=function(x,y,w,h,format,type,pixels){for(let i=0;i<pixels.length;i++){pixels[i]=i&255;}};"
         "function WebGL2RenderingContext(){}"
         "WebGL2RenderingContext.prototype=Object.create(WebGLRenderingContext.prototype);"
         "WebGL2RenderingContext.prototype.constructor=WebGL2RenderingContext;"];
    [context evaluateScript:[identity javaScriptSource]];
    assert(!context.exception);
    [context evaluateScript:@"var firstWrapper=HTMLCanvasElement.prototype.toDataURL;"];
    [context evaluateScript:[identity javaScriptSource]];
    assert(!context.exception);
    NSDictionary *result = [[context evaluateScript:
        @"(function(){"
         "const canvas=new HTMLCanvasElement();"
         "const sourceBefore=Array.from(canvas.pixels).join(',');"
         "const firstExport=canvas.toDataURL();"
         "const secondExport=canvas.toDataURL();"
         "const sourceAfter=Array.from(canvas.pixels).join(',');"
         "const firstRead=Array.from(canvas.getContext('2d').getImageData(0,0,8,8).data).join(',');"
         "const secondRead=Array.from(canvas.getContext('2d').getImageData(0,0,8,8).data).join(',');"
         "const gl=new WebGLRenderingContext();"
         "const pixels1=new Uint8Array(128);const pixels2=new Uint8Array(128);"
         "gl.readPixels(0,0,1,1,0,0,pixels1);gl.readPixels(0,0,1,1,0,0,pixels2);"
         "const precision=gl.getShaderPrecisionFormat(0,0);"
         "return {sourceStable:sourceBefore===sourceAfter,exportStable:firstExport===secondExport,exportProtected:firstExport!==sourceBefore,readStable:firstRead===secondRead,readProtected:firstRead!==sourceBefore,wrapperStable:firstWrapper===HTMLCanvasElement.prototype.toDataURL,markerHidden:Object.keys(globalThis).indexOf('__pxGraphicsIdentity_v1')===-1,vendorType:typeof gl.getParameter(7936),limitType:typeof gl.getParameter(3379),extensionsArray:Array.isArray(gl.getSupportedExtensions()),extensionsStable:gl.getSupportedExtensions().join(',')===gl.getSupportedExtensions().join(','),precisionType:typeof precision.precision,pixelsStable:Array.from(pixels1).join(',')===Array.from(pixels2).join(',')};"
         "})()"] toDictionary];
    for (NSString *booleanKey in @[@"sourceStable", @"exportStable", @"exportProtected",
                                     @"readStable", @"readProtected", @"wrapperStable",
                                     @"markerHidden", @"extensionsArray", @"extensionsStable",
                                     @"pixelsStable"]) {
        assert([result[booleanKey] boolValue]);
    }
    assert([result[@"vendorType"] isEqualToString:@"string"]);
    assert([result[@"limitType"] isEqualToString:@"number"]);
    assert([result[@"precisionType"] isEqualToString:@"number"]);

    [context evaluateScript:
        @"var beforeGenerationWrapper=HTMLCanvasElement.prototype.toDataURL;"
         "var beforeGenerationExport=(new HTMLCanvasElement()).toDataURL();"];
    PXGraphicsIdentity *nextIdentity = [PXGraphicsIdentity
        identityWithModelRecord:model
        profileSeed:@"profile-seed"
        generationID:@"99999999-9999-4999-8999-999999999999"
        hostCapabilities:hostCapabilities(1008, 16384)
        error:nil];
    [context evaluateScript:[nextIdentity javaScriptSource]];
    assert(!context.exception);
    NSDictionary *generationResult = [[context evaluateScript:
        @"({wrapperStable:beforeGenerationWrapper===HTMLCanvasElement.prototype.toDataURL,"
         "generationUpdated:globalThis.__pxGraphicsIdentity_v1.generationID==='99999999-9999-4999-8999-999999999999',"
         "outputChanged:beforeGenerationExport!==(new HTMLCanvasElement()).toDataURL()})"] toDictionary];
    assert([generationResult[@"wrapperStable"] boolValue]);
    assert([generationResult[@"generationUpdated"] boolValue]);
    assert([generationResult[@"outputChanged"] boolValue]);

    [context evaluateScript:
        @"globalThis.__pxGraphicsIdentity_v1.disable();"];
    NSDictionary *disabledResult = [[context evaluateScript:
        @"(function(){const canvas=new HTMLCanvasElement();"
         "return {canvasOriginal:canvas.toDataURL()===Array.from(canvas.pixels).join(','),"
         "webGLOriginal:(new WebGLRenderingContext()).getParameter(7936)==='host'};})()"]
        toDictionary];
    assert([disabledResult[@"canvasOriginal"] boolValue]);
    assert([disabledResult[@"webGLOriginal"] boolValue]);
}

static void testNativeCapabilityAdaptersOnlyReduceHostCapabilities(void) {
    PXGraphicsIdentity *identity = [PXGraphicsIdentity
        identityWithModelRecord:modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 8192)
        profileSeed:@"profile-seed"
        generationID:@"88888888-8888-4888-8888-888888888888"
        hostCapabilities:hostCapabilities(1008, 16384)
        error:nil];
    assert(PXGraphicsClampedLimit(identity, @"maxTextureSize", 16384) == 8192);
    assert(PXGraphicsClampedLimit(identity, @"maxTextureSize", 4096) == 4096);
    NSArray *extensions = PXGraphicsFilteredExtensions(
        identity.webGL[@"extensions"],
        @[@"HOST_only", @"OES_element_index_uint", @"WEBGL_debug_renderer_info"]);
    assert(([extensions isEqualToArray:@[@"OES_element_index_uint", @"WEBGL_debug_renderer_info"]]));
    assert(PXGraphicsAllowsMetalFamily(identity, 1007, YES));
    assert(!PXGraphicsAllowsMetalFamily(identity, 1008, YES));
    assert(!PXGraphicsAllowsMetalFamily(identity, 1007, NO));
}

static void testMalformedPersistedGraphicsIdentityFailsClosed(void) {
    PXGraphicsIdentity *valid = [PXGraphicsIdentity
        identityWithModelRecord:modelRecord(@"iPhone13,2", @"Apple A14 GPU", @"Metal 3.0", 8192)
        profileSeed:@"profile-seed"
        generationID:@"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        hostCapabilities:hostCapabilities(1008, 16384)
        error:nil];
    NSMutableDictionary *malformed = [[valid propertyListRepresentation] mutableCopy];
    malformed[@"metalFamilies"] = @"not-an-array";
    NSError *error = nil;
    assert([PXGraphicsIdentity identityWithPropertyList:malformed error:&error] == nil);
    assert(error != nil);
}

int main(void) {
    @autoreleasepool {
        testImmutableHardwareCompatibilityClassifiesRegionalVariants();
        testModelDerivedGraphicsIdentityIsCoherentAndHostSafe();
        testEveryCatalogGraphicsFamilyHasOneCoherentDescription();
        testNewerLogicalIdentityRetainsHostExecutionLimits();
        testDeprecatedFeatureSetEnumerationIsDiagnosticOnly();
        testCanvasNoiseIsStableForIdentityAndChangesWithGeneration();
        testAutomaticProtectionChangesCompositeFingerprintAcrossGenerations();
        testUserScriptSelectionRefreshesStaleGenerationWithoutDuplicates();
        testGeneratedScriptIsDeterministicIdempotentAndGraphicsOnly();
        testGeneratedScriptPreservesCanvasStateAndWebGLTypes();
        testNativeCapabilityAdaptersOnlyReduceHostCapabilities();
        testMalformedPersistedGraphicsIdentityFailsClosed();
    }
    return 0;
}
