#import "KeyChainPlugin.h"
#import "UICKeyChainStore.h"
#import <Security/Security.h>

// Keychain bridge for the Apollo SDK's KeyChainRegistry (getKey/setKey/deleteKey P/Invokes).
//
// Items are stored under a FIXED service shared by every Apollo app (the previous implementation
// used UICKeyChainStore's default service — the app's bundle id — which made items per-app by
// definition). When the app carries the Keychain Sharing entitlement with the access group
// $(AppIdentifierPrefix)com.bfg.apollo.shared, items live in that shared group so ALL Apollo apps
// from the same Apple team read/write the same values (e.g. the BFGUDID) — surviving even a full
// uninstall of every app. Without the entitlement we fall back to a per-app store with the fixed
// service: persistence across reinstalls of that app still works, cross-app sharing does not.

static NSString *const kApolloKeychainService = @"com.bfg.apollo";
static NSString *const kApolloAccessGroupSuffix = @"com.bfg.apollo.shared";

@implementation KeyChainPlugin

// Discovers this app's App Identifier Prefix ("TEAMID.") by reading the default access group of a
// probe keychain item (the standard bundle-seed-id technique). Returns nil on failure.
static NSString* ApolloAppIdentifierPrefix()
{
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount : @"com.bfg.apollo.seedprobe",
            (__bridge id)kSecAttrService : @"com.bfg.apollo.seedprobe",
            (__bridge id)kSecReturnAttributes : @YES,
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecItemNotFound) {
            status = SecItemAdd((__bridge CFDictionaryRef)query, &result);
        }
        if (status == errSecSuccess && result != NULL) {
            NSString *group = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
            NSArray<NSString *> *components = [group componentsSeparatedByString:@"."];
            if (components.count > 1) {
                prefix = [[components firstObject] stringByAppendingString:@"."];
            }
        }
        if (result != NULL) {
            CFRelease(result);
        }
        if (prefix == nil) {
            NSLog(@"[Apollo] KeyChainPlugin: could not determine App Identifier Prefix (OSStatus %d) — using per-app keychain (no cross-app sharing).", (int)status);
        }
    });
    return prefix;
}

// The single store all bridge functions operate on. Prefers the shared access group; verified
// with a probe write so a missing keychain-sharing entitlement degrades to the per-app store
// instead of failing every operation.
static UICKeyChainStore* ApolloKeyChainStore()
{
    static UICKeyChainStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *prefix = ApolloAppIdentifierPrefix();
        if (prefix != nil) {
            NSString *group = [prefix stringByAppendingString:kApolloAccessGroupSuffix];
            UICKeyChainStore *shared = [UICKeyChainStore keyChainStoreWithService:kApolloKeychainService
                                                                      accessGroup:group];
            if ([shared setString:@"1" forKey:@"com.bfg.apollo.groupprobe"]) {
                [shared removeItemForKey:@"com.bfg.apollo.groupprobe"];
                store = shared;
                return;
            }
            NSLog(@"[Apollo] KeyChainPlugin: shared access group '%@' unavailable (missing Keychain Sharing entitlement?) — using per-app keychain.", group);
        }
        store = [UICKeyChainStore keyChainStoreWithService:kApolloKeychainService];
    });
    return store;
}

static char* makeStringCopy(const char* str)
{
    if (str == NULL) {
        return NULL;
    }

    char* res = (char*)malloc(strlen(str) + 1);
    strcpy(res, str);
    return res;
}

extern "C" {
    char* getKey(const char* key);
    void setKey(const char* key, const char* value);
    void deleteKey(const char* key);
}

char* getKey(const char* key)
{
    NSString *nsKey = [NSString stringWithCString:key encoding:NSUTF8StringEncoding];

    NSString *value = [ApolloKeyChainStore() stringForKey:nsKey];

    return makeStringCopy([value UTF8String]);
}

void setKey(const char* key, const char* value)
{
    NSString *nsKey = [NSString stringWithCString:key encoding:NSUTF8StringEncoding];
    NSString *nsValue = [NSString stringWithCString:value encoding:NSUTF8StringEncoding];

    if (![ApolloKeyChainStore() setString:nsValue forKey:nsKey]) {
        NSLog(@"[Apollo] KeyChainPlugin: setKey('%@') failed — value NOT persisted.", nsKey);
    }
}

void deleteKey(const char* key)
{
    NSString *nsKey = [NSString stringWithCString:key encoding:NSUTF8StringEncoding];

    [ApolloKeyChainStore() removeItemForKey:nsKey];
}
@end
