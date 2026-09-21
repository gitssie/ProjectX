#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *PXCarriersForCountry(NSString *countryCode);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *PXCarrierCatalog(void);
FOUNDATION_EXPORT BOOL PXCarrierSupports5G(NSDictionary<NSString *, id> * _Nullable carrier);
FOUNDATION_EXPORT NSSet<NSString *> *PXAllCarrierIDs(void);
FOUNDATION_EXPORT NSSet<NSString *> *PXNormalizedTrustedCarrierIDs(NSSet<NSString *> * _Nullable savedCarrierIDs,
                                                                    BOOL * _Nullable repaired);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *PXCarriersFromCatalog(NSArray<NSDictionary<NSString *, id> *> *catalog,
                                                                                  NSSet<NSString *> *trustedCarrierIDs);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *PXCarriersForTrustedCarrierIDs(NSSet<NSString *> *trustedCarrierIDs);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *PXBuildNetworkIdentity(NSDictionary<NSString *, id> *carrier,
                                                                        BOOL supports5G,
                                                                        NSUInteger transportIndex,
                                                                        NSUInteger radioTechnologyIndex,
                                                                        NSString *serviceIdentifier);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *PXNetworkSettingsByMerging(NSDictionary<NSString *, id> *existingSettings,
                                                                           NSDictionary<NSString *, id> *updates);
FOUNDATION_EXPORT NSArray<NSString *> *PXResolvedServiceIdentifiers(NSArray<NSString *> *originalServiceIdentifiers,
                                                                     NSString *persistedServiceIdentifier);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *PXValuesByServiceIdentifier(NSArray<NSString *> *serviceIdentifiers,
                                                                                      NSString *value);
FOUNDATION_EXPORT BOOL PXNetworkIdentityIsCoherent(NSDictionary<NSString *, id> * _Nullable identity);

NS_ASSUME_NONNULL_END
