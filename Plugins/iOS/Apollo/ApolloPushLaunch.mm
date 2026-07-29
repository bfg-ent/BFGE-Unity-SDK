// ApolloPushLaunch.mm
//
// Captures the FCM notification that launched the app from a killed state so the SDK can
// replay it as OnMessageOpened after Unity/Firebase finish initializing.
//
// Under Unity's UIScene lifecycle (Unity 6000.2+) a cold-start notification tap is delivered
// in UISceneConnectionOptions.notificationResponse via scene:willConnectToSession:options: —
// NOT in launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey]. Unity's UnityScene
// delegate does not implement that callback and the Firebase iOS SDK's cold-start cache only
// reads launchOptions, so the tap payload is dropped before any C# handler can attach. This
// file hooks the scene-connect callback (plus two legacy-path fallbacks), stores the payload
// as JSON, and hands it to C# exactly once via _ApolloConsumeLaunchNotificationJson().
//
// Deliberately does NOT set a UNUserNotificationCenterDelegate and does not touch the
// Firebase AppDelegate proxy swizzling.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#include "AppDelegateListener.h"

static NSString* g_apolloLaunchNotificationJson = nil;
static BOOL g_apolloCaptureWindowClosed = NO;
static BOOL g_apolloSceneHookInstalled = NO;
static IMP g_apolloOriginalSceneConnectImp = NULL;

static id g_apolloFinishLaunchingObserver = nil;
static id g_apolloRemoteNotificationObserver = nil;
static id g_apolloBecomeActiveObserver = nil;

// Only FCM-stamped payloads count (mirrors the Android google.message_id gate).
static NSString* ApolloFcmMessageId(NSDictionary* userInfo)
{
    id messageId = userInfo[@"gcm.message_id"];
    return [messageId isKindOfClass: [NSString class]] ? (NSString*)messageId : nil;
}

static void ApolloStoreLaunchPayload(NSDictionary* userInfo, NSString* source)
{
    if (g_apolloCaptureWindowClosed || g_apolloLaunchNotificationJson != nil) return;
    if (![userInfo isKindOfClass: [NSDictionary class]]) return;

    NSString* messageId = ApolloFcmMessageId(userInfo);
    if (messageId == nil) return;

    if (![NSJSONSerialization isValidJSONObject: userInfo])
    {
        NSLog(@"[Apollo] Launch notification payload is not JSON-serializable; dropping (id=%@).", messageId);
        return;
    }

    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject: userInfo options: 0 error: &error];
    if (data == nil)
    {
        NSLog(@"[Apollo] Failed to serialize launch notification: %@", error);
        return;
    }

    g_apolloLaunchNotificationJson = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
    NSLog(@"[Apollo] Captured launch notification (source=%@, id=%@)", source, messageId);
}

// A displayable notification (aps.alert) is required on the legacy capture paths so that
// data-only content-available wakes are never mistaken for user taps.
static BOOL ApolloPayloadHasAlert(NSDictionary* userInfo)
{
    id aps = userInfo[@"aps"];
    if (![aps isKindOfClass: [NSDictionary class]]) return NO;

    id alert = ((NSDictionary*)aps)[@"alert"];
    if ([alert isKindOfClass: [NSDictionary class]]) return YES;
    return [alert isKindOfClass: [NSString class]] && ((NSString*)alert).length > 0;
}

// Legacy (non-scene) capture paths can't rely on a UNNotificationResponse, so use the classic
// tap heuristic: a user tap activates the app through UIApplicationStateInactive, while a
// content-available background wake launches straight into UIApplicationStateBackground.
static void ApolloMaybeStoreLegacyPayload(NSDictionary* userInfo, NSString* source)
{
    if (g_apolloCaptureWindowClosed || g_apolloLaunchNotificationJson != nil) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateInactive) return;
    if (![userInfo isKindOfClass: [NSDictionary class]] || !ApolloPayloadHasAlert(userInfo)) return;

    ApolloStoreLaunchPayload(userInfo, source);
}

// Installed on UnityScene as scene:willConnectToSession:options: (added when absent, swizzled
// with call-through if a future Unity version implements it).
static void Apollo_SceneWillConnect(id self, SEL _cmd, UIScene* scene, UISceneSession* session,
                                    UISceneConnectionOptions* options) API_AVAILABLE(ios(13.0))
{
    if (g_apolloOriginalSceneConnectImp != NULL)
    {
        ((void (*)(id, SEL, UIScene*, UISceneSession*, UISceneConnectionOptions*))
            g_apolloOriginalSceneConnectImp)(self, _cmd, scene, session, options);
    }

    UNNotificationResponse* response = options.notificationResponse;
    if (response == nil) return;

    // A real tap on a remote (push) notification only — not a dismiss/custom action, not a
    // local notification (e.g. com.unity.mobile.notifications).
    if (![response.actionIdentifier isEqualToString: UNNotificationDefaultActionIdentifier]) return;
    if (![response.notification.request.trigger isKindOfClass: [UNPushNotificationTrigger class]]) return;

    ApolloStoreLaunchPayload(response.notification.request.content.userInfo, @"sceneConnectionOptions");
}

static void ApolloInstallSceneHook(void)
{
    if (g_apolloSceneHookInstalled) return;
    if (@available(iOS 13.0, *))
    {
        Class sceneCls = objc_getClass("UnityScene");
        if (sceneCls == nil) return;

        SEL sel = @selector(scene:willConnectToSession:options:);
        Method existing = class_getInstanceMethod(sceneCls, sel);
        if (class_addMethod(sceneCls, sel, (IMP)Apollo_SceneWillConnect, "v@:@@@"))
        {
            // sceneCls had no implementation of its own; if one was inherited from a
            // superclass, preserve it as the call-through target.
            if (existing != NULL)
            {
                g_apolloOriginalSceneConnectImp = method_getImplementation(existing);
            }
        }
        else
        {
            // sceneCls already implements this selector directly — safe to swizzle in place.
            existing = class_getInstanceMethod(sceneCls, sel);
            g_apolloOriginalSceneConnectImp = method_getImplementation(existing);
            method_setImplementation(existing, (IMP)Apollo_SceneWillConnect);
        }
        g_apolloSceneHookInstalled = YES;
    }
}

@interface ApolloPushLaunch : NSObject
@end

@implementation ApolloPushLaunch

+ (void)load
{
    ApolloInstallSceneHook();

    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];

    // Fallback for non-scene trampolines (older Unity versions consuming this package), where
    // the tapped notification still arrives in launchOptions. Also retries the scene hook —
    // scene connect happens after didFinishLaunching, so a retry here still lands in time.
    g_apolloFinishLaunchingObserver = [center
        addObserverForName: UIApplicationDidFinishLaunchingNotification
                    object: nil
                     queue: nil
                usingBlock: ^(NSNotification* note) {
                    ApolloInstallSceneHook();
                    ApolloMaybeStoreLegacyPayload(
                        note.userInfo[UIApplicationLaunchOptionsRemoteNotificationKey],
                        @"launchOptions");
                }];

    // Defensive: some iOS paths replay a killed-state tap through the legacy
    // didReceiveRemoteNotification callback during activation (Unity re-posts it with the APNs
    // payload as the notification's userInfo). Redundant captures are de-duplicated in C#.
    g_apolloRemoteNotificationObserver = [center
        addObserverForName: kUnityDidReceiveRemoteNotification
                    object: nil
                     queue: nil
                usingBlock: ^(NSNotification* note) {
                    ApolloMaybeStoreLegacyPayload(note.userInfo, @"didReceiveRemoteNotification");
                }];

    // The launch window ends at the first activation; anything after that is a warm tap, which
    // the Firebase event path already handles.
    g_apolloBecomeActiveObserver = [center
        addObserverForName: UIApplicationDidBecomeActiveNotification
                    object: nil
                     queue: nil
                usingBlock: ^(NSNotification* note) {
                    g_apolloCaptureWindowClosed = YES;

                    NSNotificationCenter* c = [NSNotificationCenter defaultCenter];
                    if (g_apolloFinishLaunchingObserver != nil)
                    {
                        [c removeObserver: g_apolloFinishLaunchingObserver];
                        g_apolloFinishLaunchingObserver = nil;
                    }
                    if (g_apolloRemoteNotificationObserver != nil)
                    {
                        [c removeObserver: g_apolloRemoteNotificationObserver];
                        g_apolloRemoteNotificationObserver = nil;
                    }
                    if (g_apolloBecomeActiveObserver != nil)
                    {
                        [c removeObserver: g_apolloBecomeActiveObserver];
                        g_apolloBecomeActiveObserver = nil;
                    }
                }];
}

@end

// Returns the captured launch-notification payload as malloc'd UTF-8 JSON (Unity's marshaler
// frees it), or NULL. Consume-on-read: the payload is handed out at most once per process.
extern "C" char* _ApolloConsumeLaunchNotificationJson()
{
    if (g_apolloLaunchNotificationJson == nil) return NULL;

    const char* utf8 = [g_apolloLaunchNotificationJson UTF8String];
    char* copy = (char*)malloc(strlen(utf8) + 1);
    strcpy(copy, utf8);

    g_apolloLaunchNotificationJson = nil;
    return copy;
}
