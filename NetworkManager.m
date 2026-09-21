#import "NetworkManager.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import "ProjectXLogging.h"
#import "NetworkIdentity.h"
#import "PXRootHidePath.h"

@implementation NetworkManager

+ (instancetype)sharedManager {
    static NetworkManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

#pragma mark - Carrier Methods

+ (NSArray *)getCarriersForCountry:(NSString *)countryCode {
    return PXCarriersForCountry(countryCode ?: @"");
}

+ (NSArray *)getUSCarriers {
    return PXCarriersForCountry(@"us");
}

+ (NSArray *)getIndiaCarriers {
    return PXCarriersForCountry(@"in");
}

+ (NSArray *)getCanadaCarriers {
    return PXCarriersForCountry(@"ca");
}

#pragma mark - IP Address Methods

+ (NSString *)getCurrentLocalIPAddress {
    NSString *address = @"192.168.1.1"; // Default fallback
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    
    // Retrieve the current interfaces - returns 0 on success
    if (getifaddrs(&interfaces) == 0) {
        // Loop through linked list of interfaces
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                // Check if interface is en0 which is the wifi connection on iOS
                if ([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                    // Get NSString from C String
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    
    // Free memory
    freeifaddrs(interfaces);
    
    return address;
}

+ (NSString *)generateSpoofedLocalIPAddressFromCurrent {
    NSString *currentIP = [self getCurrentLocalIPAddress];
    NSArray<NSString *> *parts = [currentIP componentsSeparatedByString:@"."];
    if (parts.count == 4) {
        // Change the last octet to a random value (2-253), not the original
        int lastOctet = [parts[3] intValue];
        int newLastOctet = lastOctet;
        int attempts = 0;
        while (newLastOctet == lastOctet && attempts < 10) {
            newLastOctet = 2 + arc4random_uniform(252); // 2-253
            attempts++;
        }
        NSString *spoofedIP = [NSString stringWithFormat:@"%@.%@.%@.%d", parts[0], parts[1], parts[2], newLastOctet];
        return spoofedIP;
    }
    // Fallback to random if parsing fails
    return [self getCurrentLocalIPAddress];
}

+ (NSString *)generateSpoofedLocalIPv6AddressFromCurrent {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET6) {
                if ([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                    char ip6[INET6_ADDRSTRLEN];
                    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)temp_addr->ifa_addr;
                    inet_ntop(AF_INET6, &sin6->sin6_addr, ip6, sizeof(ip6));
                    address = [NSString stringWithUTF8String:ip6];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    if (!address) {
        address = @"fe80::1234:abcd:5678:9abc";
    }
    // Spoof last segment
    NSArray *parts = [address componentsSeparatedByString:@":"];
    if (parts.count >= 2) {
        NSMutableArray *mutableParts = [parts mutableCopy];
        NSString *last = parts.lastObject;
        NSString *spoofedLast = [NSString stringWithFormat:@"%x", arc4random_uniform(0xFFFF)];
        if ([last length] > 0) {
            mutableParts[mutableParts.count-1] = spoofedLast;
        } else if (mutableParts.count > 1) {
            mutableParts[mutableParts.count-2] = spoofedLast;
        }
        return [mutableParts componentsJoinedByString:@":"];
    }
    return address;
}

#pragma mark - Profile-based IP Storage

// Helper method to get the path to the current profile's identity directory
+ (NSString *)profileIdentityPath {
    // Get current profile ID
    NSString *profileId = nil;
    NSString *centralInfoPath = PXCurrentProfileInfoPath();
    NSDictionary *centralInfo = [NSDictionary dictionaryWithContentsOfFile:centralInfoPath];
    
    profileId = centralInfo[@"ProfileId"];
    if (!profileId) {
        // If not found, check the legacy active_profile_info.plist
        NSString *activeInfoPath = PXActiveProfileInfoPath();
        NSDictionary *activeInfo = [NSDictionary dictionaryWithContentsOfFile:activeInfoPath];
        profileId = activeInfo[@"ProfileId"];
        
        PXLog(@"[WeaponX] 🔍 NetworkManager - Primary profile info not found, checked backup: %@", profileId ? @"✅ found" : @"❌ not found");
    }
    
    if (!profileId) {
        PXLog(@"[WeaponX] Warning: No active profile ID found for NetworkManager");
        // Fallback approach: try to find any profile directory
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *profilesDir = PXProfilesDirectoryPath();
        NSError *error = nil;
        NSArray *contents = [fileManager contentsOfDirectoryAtPath:profilesDir error:&error];
        
        if (!error && contents.count > 0) {
            // Use the first directory found as a fallback
            for (NSString *item in contents) {
                BOOL isDir = NO;
                NSString *fullPath = [profilesDir stringByAppendingPathComponent:item];
                [fileManager fileExistsAtPath:fullPath isDirectory:&isDir];
                
                if (isDir) {
                    profileId = item;
                    PXLog(@"[WeaponX] NetworkManager using fallback profile ID: %@", profileId);
                    break;
                }
            }
        }
        
        // If we still don't have a profile ID, give up
        if (!profileId) {
            PXLog(@"[WeaponX] Error: NetworkManager could not find any profile");
            return nil;
        }
    }
    
    // Build the path to this profile's identity directory
    NSString *identityDir = PXProfileIdentityDirectoryPath(profileId);
    
    // Create the directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:identityDir]) {
        NSDictionary *attributes = @{
            NSFilePosixPermissions: @0755,
            NSFileOwnerAccountName: @"mobile"
        };
        
        NSError *dirError = nil;
        if (![fileManager createDirectoryAtPath:identityDir 
                    withIntermediateDirectories:YES 
                                     attributes:attributes
                                          error:&dirError]) {
            PXLog(@"[WeaponX] Error creating identity directory for NetworkManager: %@", dirError);
            return nil;
        }
    }
    
    return identityDir;
}

+ (BOOL)saveLocalIPAddress:(NSString *)ipAddress {
    NSString *identityDir = [self profileIdentityPath];
    if (!identityDir) {
        PXLog(@"[WeaponX] Error: Could not get profile identity path for NetworkManager");
        return NO;
    }
    NSString *ipv6 = [self generateSpoofedLocalIPv6AddressFromCurrent];
    NSString *networkPath = [identityDir stringByAppendingPathComponent:@"network_settings.plist"];
    NSDictionary *existingSettings = [NSDictionary dictionaryWithContentsOfFile:networkPath] ?: @{};
    NSDictionary *networkDict = PXNetworkSettingsByMerging(existingSettings, @{
        @"localIPAddress": ipAddress ?: @"",
        @"localIPv6Address": ipv6 ?: @"",
        @"lastUpdated": [NSDate date]
    });
    BOOL success = [networkDict writeToFile:networkPath atomically:YES];
    if (success) {
        NSString *deviceIdsPath = [identityDir stringByAppendingPathComponent:@"device_ids.plist"];
        NSMutableDictionary *deviceIds = [NSMutableDictionary dictionaryWithContentsOfFile:deviceIdsPath] ?: [NSMutableDictionary dictionary];
        deviceIds[@"LocalIPAddress"] = ipAddress;
        deviceIds[@"LocalIPv6Address"] = ipv6;
        success = [deviceIds writeToFile:deviceIdsPath atomically:YES];
    }
    PXLog(@"[WeaponX] %@ Local IP Address (IPv4/IPv6) saved to profile: %@ / %@", success ? @"✅" : @"❌", ipAddress, ipv6);
    return success;
}

+ (NSString *)getSavedLocalIPAddress {
    return [self getSavedLocalIPAddressWithForcedRefresh:NO];
}

+ (NSString *)getSavedLocalIPAddressWithForcedRefresh:(BOOL)forceRefresh {
    // Get path to current profile's identity directory
    NSString *identityDir = [self profileIdentityPath];
    if (!identityDir) {
        PXLog(@"[WeaponX] Error: Could not get profile identity path for NetworkManager");
        return nil;
    }
    
    // If forced refresh is requested, always generate a new local IP
    if (forceRefresh) {
        NSString *localIP = [self generateSpoofedLocalIPAddressFromCurrent];
        
        // Save it for future use
        [self saveLocalIPAddress:localIP];
        
        PXLog(@"[WeaponX] Forced refresh of local IP address: %@", localIP);
        return localIP;
    }
    
    // Try to read from network_settings.plist
    NSString *networkPath = [identityDir stringByAppendingPathComponent:@"network_settings.plist"];
    NSDictionary *networkDict = [NSDictionary dictionaryWithContentsOfFile:networkPath];
    
    NSString *localIP = networkDict[@"localIPAddress"];
    
    // If not found in dedicated file, try the combined device_ids.plist
    if (!localIP) {
        NSString *deviceIdsPath = [identityDir stringByAppendingPathComponent:@"device_ids.plist"];
        NSDictionary *deviceIds = [NSDictionary dictionaryWithContentsOfFile:deviceIdsPath];
        localIP = deviceIds[@"LocalIPAddress"];
    }
    
    // Missing generated data is a read-time fallback only; never create a mixed generation here.
    if (!localIP) {
        localIP = [self getCurrentLocalIPAddress];
        PXLog(@"[WeaponX] No saved Local IP found; returning current address without persisting: %@", localIP);
    }
    
    return localIP;
}

+ (NSString *)getSavedLocalIPv6Address {
    NSString *identityDir = [self profileIdentityPath];
    if (!identityDir) return nil;
    NSString *networkPath = [identityDir stringByAppendingPathComponent:@"network_settings.plist"];
    NSDictionary *networkDict = [NSDictionary dictionaryWithContentsOfFile:networkPath];
    NSString *ipv6 = networkDict[@"localIPv6Address"];
    if (!ipv6) {
        NSString *deviceIdsPath = [identityDir stringByAppendingPathComponent:@"device_ids.plist"];
        NSDictionary *deviceIds = [NSDictionary dictionaryWithContentsOfFile:deviceIdsPath];
        ipv6 = deviceIds[@"LocalIPv6Address"];
    }
    if (!ipv6) {
        PXLog(@"[WeaponX] No saved IPv6 address found; leaving the generated Profile unchanged");
    }
    return ipv6;
}

#pragma mark - Profile-based Carrier Storage

+ (NSDictionary *)getSavedNetworkIdentity {
    NSString *identityDirectory = [self profileIdentityPath];
    if (!identityDirectory) {
        return nil;
    }
    NSString *networkPath = [identityDirectory stringByAppendingPathComponent:@"network_settings.plist"];
    NSDictionary *identity = [NSDictionary dictionaryWithContentsOfFile:networkPath];
    return [identity isKindOfClass:[NSDictionary class]] ? identity : nil;
}

+ (NSDictionary *)carrierDetailsFromIdentity:(NSDictionary *)identity {
    NSString *carrierName = [identity[@"carrierName"] isKindOfClass:[NSString class]] ? identity[@"carrierName"] : nil;
    NSString *mcc = [identity[@"mcc"] isKindOfClass:[NSString class]] ? identity[@"mcc"] : nil;
    NSString *mnc = [identity[@"mnc"] isKindOfClass:[NSString class]] ? identity[@"mnc"] : nil;
    if (carrierName.length == 0 || mcc.length == 0 || mnc.length == 0) {
        return nil;
    }
    NSMutableDictionary *details = [identity mutableCopy];
    details[@"name"] = carrierName;
    return [details copy];
}

+ (NSDictionary *)getSavedCarrierDetails {
    return [self getSavedCarrierDetailsWithForcedRefresh:NO];
}

+ (NSDictionary *)getSavedCarrierDetailsWithForcedRefresh:(BOOL)forceRefresh {
    if (forceRefresh) {
        PXLog(@"[WeaponX] Carrier reads no longer regenerate independently; use Generate All for a new Profile generation");
    }

    NSDictionary *networkIdentity = [self getSavedNetworkIdentity];
    NSDictionary *details = [self carrierDetailsFromIdentity:networkIdentity];
    if (details) {
        return details;
    }

    NSString *identityDirectory = [self profileIdentityPath];
    if (!identityDirectory) {
        return nil;
    }
    NSString *carrierPath = [identityDirectory stringByAppendingPathComponent:@"carrier_details.plist"];
    NSDictionary *carrierDictionary = [NSDictionary dictionaryWithContentsOfFile:carrierPath];
    details = [self carrierDetailsFromIdentity:carrierDictionary];
    if (details) {
        return details;
    }

    NSString *deviceIdsPath = [identityDirectory stringByAppendingPathComponent:@"device_ids.plist"];
    NSDictionary *deviceIds = [NSDictionary dictionaryWithContentsOfFile:deviceIdsPath];
    return [self carrierDetailsFromIdentity:@{
        @"carrierName": deviceIds[@"CarrierName"] ?: @"",
        @"mcc": deviceIds[@"CarrierMCC"] ?: @"",
        @"mnc": deviceIds[@"CarrierMNC"] ?: @"",
        @"isoCountryCode": deviceIds[@"CarrierISOCountryCode"] ?: @""
    }];
}

+ (NSString *)getCurrentCountryCode {
    return [self getSavedNetworkIdentity][@"isoCountryCode"];
}

@end
