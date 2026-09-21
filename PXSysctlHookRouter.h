#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (*PXSysctlByNameHandler)(const char *name,
                                      void * _Nullable oldp,
                                      size_t * _Nullable oldlenp,
                                      void * _Nullable newp,
                                      size_t newlen,
                                      int *result);

FOUNDATION_EXPORT BOOL PXRegisterSysctlByNameHandler(PXSysctlByNameHandler handler);
FOUNDATION_EXPORT int PXCallOriginalSysctlByName(const char *name,
                                                 void * _Nullable oldp,
                                                 size_t * _Nullable oldlenp,
                                                 void * _Nullable newp,
                                                 size_t newlen);

NS_ASSUME_NONNULL_END
