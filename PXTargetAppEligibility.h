#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL PXTargetBundleIdentifierIsValid(NSString * _Nullable bundleIdentifier);
FOUNDATION_EXPORT BOOL PXTargetAppCandidateIsMobileSafari(NSDictionary<NSString *, id> *candidate);
FOUNDATION_EXPORT BOOL PXTargetAppCandidateIsEligible(NSDictionary<NSString *, id> *candidate);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *PXEligibleTargetAppCandidates(
    NSArray<NSDictionary<NSString *, id> *> *candidates
);

NS_ASSUME_NONNULL_END
