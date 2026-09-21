#import "PXSysctlHookRouter.h"

#import <dlfcn.h>
#import <ellekit/ellekit.h>
#import <os/lock.h>
#import <string.h>

enum { PXMaximumSysctlByNameHandlers = 12 };

static int (*PXOriginalSysctlByName)(const char *, void *, size_t *, void *, size_t);
static PXSysctlByNameHandler PXSysctlByNameHandlers[PXMaximumSysctlByNameHandlers];
static NSUInteger PXSysctlByNameHandlerCount;
static os_unfair_lock PXSysctlByNameLock = OS_UNFAIR_LOCK_INIT;
static BOOL PXSysctlByNameInstalled;

int PXCallOriginalSysctlByName(const char *name,
                               void *oldp,
                               size_t *oldlenp,
                               void *newp,
                               size_t newlen) {
    return PXOriginalSysctlByName
        ? PXOriginalSysctlByName(name, oldp, oldlenp, newp, newlen)
        : -1;
}

static int PXHookedSysctlByName(const char *name,
                                void *oldp,
                                size_t *oldlenp,
                                void *newp,
                                size_t newlen) {
    PXSysctlByNameHandler handlers[PXMaximumSysctlByNameHandlers] = {0};
    os_unfair_lock_lock(&PXSysctlByNameLock);
    NSUInteger count = PXSysctlByNameHandlerCount;
    memcpy(handlers, PXSysctlByNameHandlers, count * sizeof(PXSysctlByNameHandler));
    os_unfair_lock_unlock(&PXSysctlByNameLock);

    for (NSUInteger index = 0; index < count; index++) {
        int result = -1;
        if (handlers[index](name, oldp, oldlenp, newp, newlen, &result)) {
            return result;
        }
    }
    return PXCallOriginalSysctlByName(name, oldp, oldlenp, newp, newlen);
}

BOOL PXRegisterSysctlByNameHandler(PXSysctlByNameHandler handler) {
    if (!handler) return NO;

    os_unfair_lock_lock(&PXSysctlByNameLock);
    if (!PXSysctlByNameInstalled) {
        void *symbol = dlsym(RTLD_DEFAULT, "sysctlbyname");
        PXSysctlByNameInstalled = symbol &&
            EKHook(symbol, (void *)PXHookedSysctlByName,
                   (void **)&PXOriginalSysctlByName) == 0;
    }
    if (!PXSysctlByNameInstalled ||
        PXSysctlByNameHandlerCount >= PXMaximumSysctlByNameHandlers) {
        os_unfair_lock_unlock(&PXSysctlByNameLock);
        return NO;
    }
    for (NSUInteger index = 0; index < PXSysctlByNameHandlerCount; index++) {
        if (PXSysctlByNameHandlers[index] == handler) {
            os_unfair_lock_unlock(&PXSysctlByNameLock);
            return YES;
        }
    }
    PXSysctlByNameHandlers[PXSysctlByNameHandlerCount++] = handler;
    os_unfair_lock_unlock(&PXSysctlByNameLock);
    return YES;
}
