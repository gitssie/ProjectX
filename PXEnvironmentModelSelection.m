#import "PXEnvironmentModelSelection.h"

#import "GraphicsIdentity.h"
#import "PXEnvironmentPolicy.h"

NSString * const PXEnvironmentModelSelectionErrorDomain = @"com.hydra.projectx.environment-model-selection";

static NSError *PXEnvironmentModelSelectionError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:PXEnvironmentModelSelectionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

NSDictionary<NSString *, id> *PXResolveEnvironmentModelSelection(
    PXEnvironmentPolicyStore *policyStore,
    NSArray<NSDictionary<NSString *, id> *> *availableModelRecords,
    NSDictionary<NSString *, id> *physicalModelRecord,
    NSDictionary<NSString *, id> *hostGraphicsCapabilities,
    BOOL *didMigrate,
    NSError **error
) {
    if (didMigrate) {
        *didMigrate = NO;
    }
    if (![physicalModelRecord isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = PXEnvironmentModelSelectionError(
                1,
                @"The physical device model is unavailable");
        }
        return nil;
    }
    NSString *physicalIdentifier = [physicalModelRecord[@"identifier"]
        isKindOfClass:[NSString class]] ? physicalModelRecord[@"identifier"] : nil;
    NSString *physicalName = [physicalModelRecord[@"name"]
        isKindOfClass:[NSString class]] ? physicalModelRecord[@"name"] : nil;
    if (![physicalIdentifier hasPrefix:@"iPhone"] || physicalName.length == 0) {
        if (error) {
            *error = PXEnvironmentModelSelectionError(
                1,
                @"The physical device model is unavailable");
        }
        return nil;
    }

    NSError *policyError = nil;
    NSString *selectedIdentifier = [policyStore
        selectedModelIdentifierWithError:&policyError];
    PXEnvironmentModelSelectionMode selectionMode = [policyStore
        selectedModelSelectionModeWithError:&policyError];
    if (policyError) {
        if (error) {
            *error = policyError;
        }
        return nil;
    }

    NSDictionary<NSString *, id> *selectedModel = nil;
    for (NSDictionary<NSString *, id> *modelRecord in availableModelRecords) {
        if ([modelRecord[@"identifier"] isEqualToString:selectedIdentifier]) {
            selectedModel = modelRecord;
            break;
        }
    }
    BOOL selectedModelIsCompatible = selectedModel != nil &&
        PXModelRecordIsHardwareCompatibleWithPhysicalRecord(
            selectedModel,
            physicalModelRecord,
            hostGraphicsCapabilities,
            nil);
    if (selectedModelIsCompatible && selectionMode == PXEnvironmentModelSelectionModeCustom) {
        return selectedModel;
    }

    if (selectedModelIsCompatible && selectionMode == PXEnvironmentModelSelectionModeMissing) {
        if (![policyStore saveSelectedModelRecord:selectedModel
                               physicalModelRecord:physicalModelRecord
                           hostGraphicsCapabilities:hostGraphicsCapabilities
                                               error:&policyError]) {
            if (error) {
                *error = policyError;
            }
            return nil;
        }
        if (didMigrate) {
            *didMigrate = YES;
        }
        return selectedModel;
    }

    PXEnvironmentNetworkType selectedNetworkType = [policyStore
        selectedNetworkTypeWithError:&policyError];
    if (policyError) {
        if (error) {
            *error = policyError;
        }
        return nil;
    }
    BOOL physicalNetworkIsIncompatible =
        selectedNetworkType != PXEnvironmentNetworkTypeUnspecified &&
        !PXEnvironmentNetworkTypeIsCompatibleWithModelRecord(
            selectedNetworkType,
            physicalModelRecord);
    BOOL needsPersistence = selectionMode != PXEnvironmentModelSelectionModePhysicalDevice ||
        selectedIdentifier.length > 0 || physicalNetworkIsIncompatible;
    if (needsPersistence && ![policyStore savePhysicalDeviceModelRecord:physicalModelRecord
                                                               error:&policyError]) {
        if (error) {
            *error = policyError;
        }
        return nil;
    }
    if (didMigrate) {
        *didMigrate = needsPersistence;
    }
    return physicalModelRecord;
}

BOOL PXEnvironmentModelSelectionCanRecoverFromError(NSError *error) {
    if ([error.domain isEqualToString:PXGraphicsIdentityErrorDomain]) {
        return error.code == 3;
    }
    return [error.domain isEqualToString:PXModelCompatibilityErrorDomain] &&
        (error.code == PXModelCompatibilityErrorImmutableHardwareMismatch ||
         error.code == PXModelCompatibilityErrorCandidateInvalid);
}
