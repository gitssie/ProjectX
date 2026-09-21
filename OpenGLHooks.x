#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
// OpenGL ES hooks are intentional because scoped legacy apps still expose these APIs.
#import <OpenGLES/ES3/gl.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "AppIdentityHookSupport.h"
#import "PXProcessHookPolicy.h"

static NSMutableDictionary<NSString *, NSValue *> *PXOriginalMetalNames = nil;
static NSMutableDictionary<NSString *, NSValue *> *PXOriginalMetalFamilyNames = nil;
static NSMutableDictionary<NSString *, NSValue *> *PXOriginalMetalFamilySupport = nil;
static NSMutableDictionary<NSString *, NSValue *> *PXOriginalMetalFeatureSetSupport = nil;

static const GLubyte *(*PXOriginalGLGetString)(GLenum) = NULL;
static const GLubyte *(*PXOriginalGLGetStringi)(GLenum, GLuint) = NULL;
static void (*PXOriginalGLGetIntegerv)(GLenum, GLint *) = NULL;

static IMP PXMetalOriginalImplementation(NSDictionary<NSString *, NSValue *> *implementations,
                                         id device) {
    return [implementations[NSStringFromClass([device class])] pointerValue];
}

static NSArray<NSString *> *PXFilteredOpenGLExtensions(void) {
    static NSArray<NSString *> *cachedExtensions = nil;
    static NSString *cachedGenerationID = nil;
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    if (!identity || !PXOriginalGLGetIntegerv || !PXOriginalGLGetStringi) {
        return @[];
    }
    @synchronized([PXGraphicsIdentity class]) {
        if (cachedExtensions && [cachedGenerationID isEqualToString:identity.generationID]) {
            return cachedExtensions;
        }
        GLint count = 0;
        PXOriginalGLGetIntegerv(GL_NUM_EXTENSIONS, &count);
        NSMutableArray<NSString *> *hostExtensions = [NSMutableArray array];
        for (GLint index = 0; index < MAX(count, 0); index++) {
            const GLubyte *value = PXOriginalGLGetStringi(GL_EXTENSIONS, (GLuint)index);
            if (value) {
                NSString *extension = [NSString stringWithUTF8String:(const char *)value];
                if (extension.length > 0) {
                    [hostExtensions addObject:extension];
                }
            }
        }
        cachedExtensions = PXGraphicsFilteredExtensions(identity.openGL[@"extensions"], hostExtensions);
        cachedGenerationID = identity.generationID;
        return cachedExtensions;
    }
}

static NSString *PXFilteredOpenGLExtensionString(const GLubyte *hostValue) {
    static NSString *cachedExtensionString = nil;
    static NSString *cachedGenerationID = nil;
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    if (!identity || !hostValue) {
        return nil;
    }
    @synchronized([PXGraphicsIdentity class]) {
        if (cachedExtensionString && [cachedGenerationID isEqualToString:identity.generationID]) {
            return cachedExtensionString;
        }
        NSString *hostString = [NSString stringWithUTF8String:(const char *)hostValue];
        NSArray<NSString *> *hostExtensions = [hostString componentsSeparatedByString:@" "];
        cachedExtensionString = [PXGraphicsFilteredExtensions(
            identity.openGL[@"extensions"], hostExtensions) componentsJoinedByString:@" "];
        cachedGenerationID = identity.generationID;
        return cachedExtensionString;
    }
}

static NSString *PXHookedMetalName(id device, SEL selector) {
    NSString *(*original)(id, SEL) = (NSString *(*)(id, SEL))
        PXMetalOriginalImplementation(PXOriginalMetalNames, device);
    NSString *hostName = original ? original(device, selector) : nil;
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    return identity.gpuName.length > 0 ? identity.gpuName : hostName;
}

static NSString *PXHookedMetalFamilyName(id device, SEL selector) {
    NSString *(*original)(id, SEL) = (NSString *(*)(id, SEL))
        PXMetalOriginalImplementation(PXOriginalMetalFamilyNames, device);
    NSString *hostName = original ? original(device, selector) : nil;
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    return identity.gpuFamily.length > 0 ? identity.gpuFamily : hostName;
}

static BOOL PXHookedMetalSupportsFamily(id device, SEL selector, NSUInteger family) {
    BOOL (*original)(id, SEL, NSUInteger) = (BOOL (*)(id, SEL, NSUInteger))
        PXMetalOriginalImplementation(PXOriginalMetalFamilySupport, device);
    BOOL hostSupports = original ? original(device, selector, family) : NO;
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    return identity ? PXGraphicsAllowsMetalFamily(identity, family, hostSupports) : hostSupports;
}

static BOOL PXHookedMetalSupportsFeatureSet(id device, SEL selector, NSUInteger featureSet) {
    BOOL (*original)(id, SEL, NSUInteger) = (BOOL (*)(id, SEL, NSUInteger))
        PXMetalOriginalImplementation(PXOriginalMetalFeatureSetSupport, device);
    BOOL hostSupports = original ? original(device, selector, featureSet) : NO;
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    return identity
        ? hostSupports && [identity.metalFeatureSets containsObject:@(featureSet)]
        : hostSupports;
}

static const GLubyte *PXHookedGLGetString(GLenum name) {
    const GLubyte *hostValue = PXOriginalGLGetString ? PXOriginalGLGetString(name) : NULL;
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    if (!identity || !hostValue) {
        return hostValue;
    }
    NSString *value = nil;
    switch (name) {
        case GL_VENDOR: value = identity.openGL[@"vendor"]; break;
        case GL_RENDERER: value = identity.openGL[@"renderer"]; break;
        case GL_VERSION: value = identity.openGL[@"version"]; break;
        case GL_SHADING_LANGUAGE_VERSION: value = identity.openGL[@"shadingLanguageVersion"]; break;
        case GL_EXTENSIONS: value = PXFilteredOpenGLExtensionString(hostValue); break;
        default: return hostValue;
    }
    return value.length > 0 ? (const GLubyte *)value.UTF8String : hostValue;
}

static const GLubyte *PXHookedGLGetStringi(GLenum name, GLuint index) {
    const GLubyte *hostValue = PXOriginalGLGetStringi
        ? PXOriginalGLGetStringi(name, index)
        : NULL;
    if (name != GL_EXTENSIONS || !hostValue || !PXPrepareCurrentProcessGraphicsIdentity()) {
        return hostValue;
    }
    NSArray<NSString *> *extensions = PXFilteredOpenGLExtensions();
    return index < extensions.count
        ? (const GLubyte *)extensions[index].UTF8String
        : NULL;
}

static void PXHookedGLGetIntegerv(GLenum name, GLint *value) {
    if (PXOriginalGLGetIntegerv) {
        PXOriginalGLGetIntegerv(name, value);
    }
    PXGraphicsIdentity *identity = PXPrepareCurrentProcessGraphicsIdentity();
    const GLubyte *version = PXOriginalGLGetString ? PXOriginalGLGetString(GL_VERSION) : NULL;
    if (!identity || !value || !version) {
        return;
    }
    if (name == GL_MAX_TEXTURE_SIZE) {
        *value = (GLint)PXGraphicsClampedLimit(identity, @"maxTextureSize", (NSUInteger)MAX(*value, 0));
    } else if (name == GL_MAX_RENDERBUFFER_SIZE) {
        *value = (GLint)PXGraphicsClampedLimit(identity, @"maxRenderbufferSize", (NSUInteger)MAX(*value, 0));
    } else if (name == GL_NUM_EXTENSIONS) {
        *value = (GLint)PXFilteredOpenGLExtensions().count;
    }
}

static void PXInstallMetalHooksForDevice(id<MTLDevice> device) {
    Class deviceClass = object_getClass(device) ? [device class] : Nil;
    if (!deviceClass) {
        return;
    }
    NSString *className = NSStringFromClass(deviceClass);
    if (PXOriginalMetalNames[className]) {
        return;
    }
    Method nameMethod = class_getInstanceMethod(deviceClass, @selector(name));
    if (nameMethod) {
        IMP original = NULL;
        MSHookMessageEx(deviceClass, @selector(name), (IMP)PXHookedMetalName, &original);
        PXOriginalMetalNames[className] = [NSValue valueWithPointer:original];
    }
    SEL familyNameSelector = NSSelectorFromString(@"familyName");
    if (class_getInstanceMethod(deviceClass, familyNameSelector)) {
        IMP original = NULL;
        MSHookMessageEx(deviceClass, familyNameSelector, (IMP)PXHookedMetalFamilyName, &original);
        PXOriginalMetalFamilyNames[className] = [NSValue valueWithPointer:original];
    }
    if (class_getInstanceMethod(deviceClass, @selector(supportsFamily:))) {
        IMP original = NULL;
        MSHookMessageEx(deviceClass, @selector(supportsFamily:), (IMP)PXHookedMetalSupportsFamily, &original);
        PXOriginalMetalFamilySupport[className] = [NSValue valueWithPointer:original];
    }
    SEL featureSetSelector = @selector(supportsFeatureSet:);
    if (class_getInstanceMethod(deviceClass, featureSetSelector)) {
        IMP original = NULL;
        MSHookMessageEx(deviceClass, featureSetSelector, (IMP)PXHookedMetalSupportsFeatureSet, &original);
        PXOriginalMetalFeatureSetSupport[className] = [NSValue valueWithPointer:original];
    }
}

static void PXInstallMetalHooks(void) {
    PXOriginalMetalNames = [NSMutableDictionary dictionary];
    PXOriginalMetalFamilyNames = [NSMutableDictionary dictionary];
    PXOriginalMetalFamilySupport = [NSMutableDictionary dictionary];
    PXOriginalMetalFeatureSetSupport = [NSMutableDictionary dictionary];
    NSMutableArray<id<MTLDevice>> *devices = [NSMutableArray array];
    id<MTLDevice> defaultDevice = MTLCreateSystemDefaultDevice();
    if (defaultDevice) {
        [devices addObject:defaultDevice];
    }
    typedef NSArray<id<MTLDevice>> *(*PXCopyAllMetalDevicesFunction)(void);
    PXCopyAllMetalDevicesFunction copyAllDevices =
        (PXCopyAllMetalDevicesFunction)dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
    if (copyAllDevices) {
        NSArray<id<MTLDevice>> *allDevices = copyAllDevices();
        if ([allDevices isKindOfClass:[NSArray class]]) {
            [devices addObjectsFromArray:allDevices];
        }
    }
    for (id<MTLDevice> device in devices) {
        PXInstallMetalHooksForDevice(device);
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
%ctor {
    @autoreleasepool {
        if (!PXCurrentProcessMayInstallApplicationHooks()) {
            return;
        }
        PXInstallMetalHooks();
        MSHookFunction((void *)glGetString, (void *)PXHookedGLGetString,
                       (void **)&PXOriginalGLGetString);
        MSHookFunction((void *)glGetStringi, (void *)PXHookedGLGetStringi,
                       (void **)&PXOriginalGLGetStringi);
        MSHookFunction((void *)glGetIntegerv, (void *)PXHookedGLGetIntegerv,
                       (void **)&PXOriginalGLGetIntegerv);
    }
}
#pragma clang diagnostic pop
