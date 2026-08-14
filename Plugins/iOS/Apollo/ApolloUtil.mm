// ApolloUtil.h
#import "UnityAppController.h"

@interface UnityAppController (ApolloUtil)

- (char *)getIfa;
- (char *)getDeviceCarrierName;
- (char *)getIdfv;
- (char *)getApplicationBuildVersion;
- (BOOL)isPushNotificationEnabled;
- (int)getAttTrackingStatus;
- (char *)getRegionCode;

@end

// ApolloUtil.mm
#import "AdSupport/ASIdentifierManager.h"
#import "UnityInterface.h" // UnitySendMessage, for the async ATT completion callback
#import <AppTrackingTransparency/ATTrackingManager.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <Foundation/Foundation.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>

@implementation UnityAppController (ApolloUtil)

- (char *) getIfa {
    NSString* ifa = [[[ASIdentifierManager sharedManager] advertisingIdentifier] UUIDString];
    
    return convertNSStringToCString(ifa);
}

-(char *) getDeviceCarrierName
{
    NSString *carrierName = @"";
    CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
    
    if (@available(iOS 12.0, *)) {
        NSDictionary<NSString *, NSString *> *currentRATs = networkInfo.serviceCurrentRadioAccessTechnology;
        
        for (NSString *serviceIdentifier in currentRATs) {
            CTCarrier *carrier = [networkInfo.serviceSubscriberCellularProviders objectForKey:serviceIdentifier];
            carrierName = carrier.carrierName;
            if (carrierName != nil || ![carrierName  isEqualToString:@"--"]) {
                return convertNSStringToCString(carrierName);
            }
        }
    }
    else{
        CTCarrier *carrier = [networkInfo subscriberCellularProvider];
        carrierName = [carrier carrierName];
    }

    return convertNSStringToCString(carrierName);
}

-(char * ) getIdfv
{
    NSString *idfvString = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    return convertNSStringToCString(idfvString);
}

// CFBundleVersion is "one to three period-separated integers" per Apple's docs (e.g. "1.2.3"),
// not necessarily a single integer — returning the raw string (rather than [NSString intValue],
// which truncates at the first '.') preserves it exactly. The GTS payload field this feeds is a
// string already (see GtsInfoProvider.AppBuildVersion), so this loses no information end to end.
- (char *)getApplicationBuildVersion {
    NSString *buildVersionString = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString *)kCFBundleVersionKey];
    return convertNSStringToCString(buildVersionString);
}

// Values follow ATTrackingManagerAuthorizationStatus (and the Unity (Apollo) SDK's ATTStatus enum):
// 0 = not determined, 1 = restricted, 2 = denied, 3 = authorized.
- (int)getAttTrackingStatus {
    if (@available(iOS 14, *)) {
        return (int)[ATTrackingManager trackingAuthorizationStatus];
    }

    // Pre-ATT OS versions: map the legacy AdSupport flag onto the same scale.
    return [[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled] ? 3 : 2;
}

// The device's Region setting (Settings > General > Language & Region > Region) — deliberately
// NOT the same as the user's preferred Language, and NOT something Mono's CultureInfo/RegionInfo
// ever reflects (those only track preferred Language, and don't re-read Region when it changes
// independently). NSLocale.countryCode is keyed to this Region setting specifically.
- (char *)getRegionCode {
    NSString *regionCode = [[NSLocale currentLocale] countryCode];
    return convertNSStringToCString(regionCode);
}

- (BOOL)isPushNotificationEnabled {
    __block BOOL enabled = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusAuthorized) {
            enabled = YES;
        } else {
            enabled = NO;
        }
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return enabled;
}

char* convertNSStringToCString(const NSString* nsString)
{
    if (nsString == NULL)
        return NULL;

    const char* nsStringUtf8 = [nsString UTF8String];
    char* cString = (char*)malloc(strlen(nsStringUtf8) + 1);
    strcpy(cString, nsStringUtf8);

    return cString;
}
@end

extern "C" char* _GetIfa() {
    return [GetAppController() getIfa];
}

extern "C" char* _GetIDFV() {
    return [GetAppController() getIdfv];
}

extern "C" char* _GetCarrierName() {
    return [GetAppController() getDeviceCarrierName];
}

extern "C" bool _IsPushNotificationEnabled() {
    return [GetAppController() isPushNotificationEnabled];
}

extern "C" char* _GetApplicationBuildVersion() {
    return [GetAppController() getApplicationBuildVersion];
}

extern "C" int _GetAttTrackingStatus() {
    return [GetAppController() getAttTrackingStatus];
}

extern "C" char* _GetRegionCode() {
    return [GetAppController() getRegionCode];
}

// Shows the ATT prompt and reports the user's selection back to managed code — Apollo owns this
// end to end (games no longer ship their own ATT shim). The completion handler can arrive on any
// thread and also fires immediately, without showing the prompt, when the status is already
// determined; either way the result is marshalled to the main queue and delivered via
// UnitySendMessage to the hidden runner GameObject AttAuthorization creates (see
// Core/Policy/AttAuthorization.cs). Status values follow ATTrackingManagerAuthorizationStatus /
// Apollo's ATTStatus enum: 0 = not determined, 1 = restricted, 2 = denied, 3 = authorized.
extern "C" void _Apollo_RequestTrackingAuthorization(const char* gameObjectName, const char* callbackMethod) {
    NSString* goName = [NSString stringWithUTF8String:gameObjectName];
    NSString* method = [NSString stringWithUTF8String:callbackMethod];

    if (@available(iOS 14, *)) {
        [ATTrackingManager requestTrackingAuthorizationWithCompletionHandler:^(ATTrackingManagerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString* statusStr = [NSString stringWithFormat:@"%d", (int)status];
                UnitySendMessage([goName UTF8String], [method UTF8String], [statusStr UTF8String]);
            });
        }];
        return;
    }

    // Pre-ATT OS versions: no prompt exists — resolve immediately with the legacy AdSupport flag
    // mapped onto the same scale (the same mapping getAttTrackingStatus uses).
    int legacyStatus = [GetAppController() getAttTrackingStatus];
    NSString* statusStr = [NSString stringWithFormat:@"%d", legacyStatus];
    UnitySendMessage([goName UTF8String], [method UTF8String], [statusStr UTF8String]);
}
