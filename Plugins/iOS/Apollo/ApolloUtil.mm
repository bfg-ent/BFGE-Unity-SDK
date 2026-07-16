// ApolloUtil.h
#import "UnityAppController.h"

@interface UnityAppController (ApolloUtil)

- (char *)getIfa;
- (char *)getDeviceCarrierName;
- (char *)getIdfv;
- (int)getApplicationBuildVersion;
- (BOOL)isPushNotificationEnabled;

@end

// ApolloUtil.mm
#import "AdSupport/ASIdentifierManager.h"
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

- (int)getApplicationBuildVersion {
    NSString *buildVersionString = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString *)kCFBundleVersionKey];
    int buildVersionInt = [buildVersionString intValue];
    return buildVersionInt;
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

extern "C" int _GetApplicationBuildVersion() {
    return [GetAppController() getApplicationBuildVersion];
}
