# Unity (Apollo) SDK

**Platform:** Unity (iOS & Android)
**Minimum iOS version:** 15.0
**Minimum Android version:** API level 25 (Android 7.1)

The Unity (Apollo) SDK is BFG Entertainment's Unity SDK for mobile games. It provides game telemetry (GTS),
compliance (GDPR consent + iOS App Tracking Transparency), and Firebase (Analytics, Crashlytics,
Cloud Messaging), plus the authentication and purchase-reporting plumbing that feeds telemetry.
Games consume it as the prebuilt `bfg.apollo` UPM package
([`bfg-ent/BFGE-Unity-SDK`](https://github.com/bfg-ent/BFGE-Unity-SDK) — versions and install
instructions live there) and integrate by implementing Apollo's **adapter** interfaces (connecting
their third-party services) and **listener** interfaces (receiving callbacks).

For the end-to-end integration walkthrough (configuration files, registration, per-feature setup),
see [`Documentation/APOLLO_SDK_INTEGRATION_GUIDE.md`](Documentation/APOLLO_SDK_INTEGRATION_GUIDE.md).
Each major feature also has a two-document pair in [`Documentation/`](Documentation/): a concise
**integration guide** (the steps to get it working and testable) and a **design document** (how the
feature is expected to behave — details, edge cases, and good-to-knows for developers and testers).

## Contents

- [Features](#features)
- [API Reference](#api-reference)

---

## Features

### Game Telemetry Service (GTS)

Apollo's core event pipeline — always on. It automatically fires `install`, `sessionStart`, and
`sessionEnd` events on app lifecycle transitions (no game code needed), and carries the events the
game sends explicitly: custom events (`SendCustomEvent`) and purchase success/failure reports.
Every event is assembled with full device, session, identity, and consent context (attribution id,
app-user id, ATT status, tracking-consent flag, stable `bfgudid` device id) and POSTed
immediately, backed by a disk-persisted retry queue (60-second retry pass) that survives app
kills.

- **Integration guide:** [`Documentation/GTS_INTEGRATION_GUIDE.md`](Documentation/GTS_INTEGRATION_GUIDE.md)
- **Design document:** [`Documentation/GTS_DESIGN.md`](Documentation/GTS_DESIGN.md)

### Compliance (GDPR Consent + ATT)

Apollo owns both compliance flows end to end. The **built-in GDPR/consent dialog** checks the
Big Fish policy service at init and on every foreground, presents any outstanding policies
(GDPR-style opt-in/opt-out and mandatory Terms-of-Use/Privacy-Policy acceptance) in a
server-driven dialog, records every shown/accepted/declined decision to the compliance backend
with guaranteed delivery, and applies the outcome to Apollo's own telemetry and Firebase Analytics
automatically. The **iOS ATT prompt** is likewise Apollo-owned: the game decides *when*
(`RequestTrackingAuthorization()`), Apollo displays the native prompt, consumes the selection for
GTS/IDFA gating itself, and reports the result back through `IAttListener`. The game's remaining
responsibilities: register listeners, trigger ATT at the right moment, and feed the GDPR decision
to any third-party ad/attribution SDKs it integrates directly.

- **Integration guide:** [`Documentation/CONSENT_INTEGRATION_GUIDE.md`](Documentation/CONSENT_INTEGRATION_GUIDE.md)
- **Design document:** [`Documentation/CONSENT_DESIGN.md`](Documentation/CONSENT_DESIGN.md)

### Firebase (Analytics, Crashlytics, Cloud Messaging)

Wraps three Firebase products behind Apollo's adapter/listener pattern — Apollo ships the adapter,
so games import the Firebase Unity SDK and call small `BFGUnitySDK` APIs instead of writing
Firebase glue. **Analytics** is GDPR-gated
and off by default (Apollo's consent dialog drives it automatically). **Crashlytics** starts at
init — deliberately not consent-gated — with crash reports correlated to the Apollo App User ID.
**Cloud Messaging** covers the FCM token lifecycle (including automatic token upload to the game's
push server), OS notification-permission timing under game control, and reliable notification-open
delivery on both platforms, including cold starts. The whole subsystem is optional: a game that
doesn't enable it skips Firebase entirely.

- **Integration guide:** [`Documentation/FIREBASE_INTEGRATION_GUIDE.md`](Documentation/FIREBASE_INTEGRATION_GUIDE.md)
- **Design document:** [`Documentation/FIREBASE_DESIGN.md`](Documentation/FIREBASE_DESIGN.md)

### Platform notes (all features)

> **iOS native code is bundled.** The package ships the native iOS sources the SDK's
> `DllImport("__Internal")` calls require (`Plugins/iOS/Apollo/` — device info, Keychain, the ATT
> prompt bridge). Games need no manual native-file setup; if your project previously hand-copied
> these files (or its own ATT shim) into `Assets/Plugins/iOS/`, delete the local copies to avoid
> duplicate-symbol linker errors.
>
> **Android dependency is bundled too.** `Editor/ApolloDependencies.xml` (EDM4U) resolves
> `play-services-ads-identifier`, which the SDK needs for the advertising id — without it telemetry
> silently ships an empty ad id. Games must declare `com.google.android.gms.permission.AD_ID` in
> their manifest (Android 13+).
>
> **Cross-app device id (iOS):** for the `bfgudid` to be shared across a team's apps and survive
> full uninstalls, each game adds the Keychain Sharing entitlement with access group
> `$(AppIdentifierPrefix)com.bfg.apollo.shared` — see the Integration Guide's "Device id (bfgudid)
> persistence on iOS" section.

---

# API Reference

Everything below is the SDK's public surface: the [`BFGUnitySDK`](#bfgunitysdk--sdk-entry-point)
static facade, the [adapter interfaces](#adapter-interfaces) games implement, the
[listener interfaces](#listener-interfaces) games receive callbacks through, and the
[data types](#data-types) and [enums](#enums) used by both.

## BFGUnitySDK — SDK Entry Point

```csharp
public static class BFGUnitySDK
```

No namespace; available globally. All SDK functionality is reached through this static facade.

Registration order matters: every `RegisterAdapter<T>()` / `RegisterListener<T>()` call must occur **before** `Initialize()`.

---

### Initialization & Registration

#### `Initialize`

```csharp
public static void Initialize()
```

Starts the SDK. Wires all registered adapters and listeners, constructs the internal controllers, and begins automatic session lifecycle tracking. Call once per launch, after all registrations.

#### `OnInitializationComplete`

```csharp
public static void OnInitializationComplete(System.Action callback)
```

Subscribes a callback that fires when SDK initialization completes. Alternative to (or in addition to) registering an [`IInitializationListener`](#iinitializationlistener).

#### `RegisterAdapter<T>`

```csharp
public static void RegisterAdapter<T>() where T : IAdapter, new()
```

Registers a concrete adapter type. `T` must implement one of the recognized adapter interfaces ([`IAuthenticationAdapter`](#iauthenticationadapter), [`IPurchasingAdapter`](#ipurchasingadapter), [`IFirebaseAdapter`](#ifirebaseadapter)) — an unrecognized type throws `InvalidOperationException` immediately. The instance is created via reflection, so `T` needs a public parameterless constructor. Call before `Initialize()`.

#### `RegisterListener<T>`

```csharp
public static void RegisterListener<T>() where T : IListener, new()
```

Registers a concrete listener type. Same rules as `RegisterAdapter<T>`: `T` must implement a recognized `IListener`-derived interface, is created via reflection (public parameterless constructor required), and an unrecognized type throws `InvalidOperationException`. Call before `Initialize()`.

> `IPolicyListener` and `IAttListener` are **not** registered this way — they are instance-registered via [`AddPolicyListener`](#addpolicylistener--removepolicylistener) / [`AddAttListener`](#app-tracking-transparency-requesttrackingauthorization--iattlistener) and support multiple listeners and runtime add/remove.

---

### Telemetry

#### `SendCustomEvent<T>`

```csharp
public static void SendCustomEvent<T>(string eventName, T customEventData)
    where T : BFG.Apollo.Telemetry.DataObjects.CustomEvent.CustomEventData, new()
```

Sends a custom-typed telemetry event to GTS. Define your payload by subclassing [`CustomEventData`](#customeventdata).

| Parameter | Type | Description |
|---|---|---|
| `eventName` | `string` | Name identifying the event type. |
| `customEventData` | `T` | An instance of your `CustomEventData` subclass carrying the event payload. |

#### `SetAppUserId`

```csharp
public static void SetAppUserId(string appUserId)
```

Sets the application user ID attached to subsequent telemetry events. Persisted across sessions. On first launch the SDK initializes it to a random GUID, which this call replaces.

#### `GetAppUserId`

```csharp
public static string GetAppUserId()
```

Returns the currently stored application user ID.

#### `SetAttributionID`

```csharp
public static void SetAttributionID(string attributionID)
```

Stores the attribution provider's device ID (e.g., the AppsFlyer ID). Once set, the value is included in all outbound GTS telemetry events as the `afid` field, and is persisted across sessions via `PlayerPrefs`.

> Call this as soon as the attribution ID is available — typically immediately after `Initialize()`. Events dispatched before `SetAttributionID` carry an empty `afid`, with one exception: on the very first launch the SDK holds the automatic `install` and `sessionStart` events for up to 5 seconds waiting for this call, so those events carry the `afid` whenever it arrives within that window.

---

### Purchase Reporting

Apollo's purchasing role is reporting: the game (or its purchasing adapter) completes the store transaction, then reports the outcome through these two methods so the corresponding GTS purchase events are sent.

#### `SendPurchasingSuccessEvent`

```csharp
public static void SendPurchasingSuccessEvent(PurchaseSuccessData customEventData)
```

Reports a completed purchase (including restores) to the telemetry system. See [`PurchaseSuccessData`](#purchasesuccessdata).

#### `SendPurchasingFailureEvent`

```csharp
public static void SendPurchasingFailureEvent(PurchaseFailureData customEventData)
```

Reports a failed purchase to the telemetry system. See [`PurchaseFailureData`](#purchasefailuredata).

---

### Consent & Policy

Apollo owns an end-to-end GDPR/consent flow: on init and on every foreground it checks a backend policy service for outstanding policies and presents them via its own built-in dialog. Requires [`Resources/ApolloConsentConfig.json`](Documentation/APOLLO_SDK_INTEGRATION_GUIDE.md#apolloconsentconfigjson--policy-service-url); if that config is missing/invalid the whole consent system self-disables. Full behavior is documented in [`Documentation/CONSENT_DESIGN.md`](Documentation/CONSENT_DESIGN.md) and [`Documentation/CONSENT_INTEGRATION_GUIDE.md`](Documentation/CONSENT_INTEGRATION_GUIDE.md).

#### `AddPolicyListener` / `RemovePolicyListener`

```csharp
public static void AddPolicyListener(IPolicyListener listener)
public static void RemovePolicyListener(IPolicyListener listener)
```

Registers/unregisters an [`IPolicyListener`](#ipolicylistener) for the SDK's GDPR/compliance consent dialog. Instance-based (not `RegisterListener<T>`); supports multiple listeners and runtime add/remove. Register in your scene's startup (e.g. `OnEnable`) and unregister on teardown. A listener registered after the consent flow has already resolved (or already decided it will show) is immediately re-delivered that state — there is no "registered too late" race.

#### `DidAcceptPolicyControl`

```csharp
public const string ThirdPartyTargetedAdvertisingControl = "THIRDPARTYTARGETEDADVERTISING";

public static bool DidAcceptPolicyControl(string controlName)
```

Returns whether the user has accepted the named policy control — via the consent dialog, the game-managed override, or the fail-open auto-opt-in path. Returns `false` for declined, not-yet-answered, and not-applicable alike: the safe default to feed into a third-party SDK's own consent flag.

`ThirdPartyTargetedAdvertisingControl` is the named control governing third-party targeted-advertising consent (GDPR-style opt-in/opt-out):

```csharp
bool adsAllowed = BFGUnitySDK.DidAcceptPolicyControl(BFGUnitySDK.ThirdPartyTargetedAdvertisingControl);
MyThirdPartyAdSdk.SetConsent(adsAllowed);
```

#### `EnableTargetedAdvertising`

```csharp
public static void EnableTargetedAdvertising(bool enabled)
```

**Game-managed consent override.** Call this if your game implements its own GDPR/consent UI instead of using the SDK's built-in dialog. It bypasses the dialog entirely but records the decision through the same persistence/reporting pipeline as a dialog-driven decision. It does not replace [`ApplyThirdPartyTrackingConsentStatus`](#applythirdpartytrackingconsentstatus) or [`SetFirebaseDataCollectionConsent`](#setfirebasedatacollectionconsent) — call those with the user's decision as well.

#### `ApplyThirdPartyTrackingConsentStatus`

```csharp
public static void ApplyThirdPartyTrackingConsentStatus(bool authorized = true)
```

Stores the user's consent for third-party tracking. The value is written into all outbound GTS telemetry events as the `tpte` (third-party tracking enabled) field. Call whenever the user's consent status changes.

---

### App Tracking Transparency (`RequestTrackingAuthorization` / `IAttListener`)

```csharp
public static void RequestTrackingAuthorization()
public static void AddAttListener(IAttListener listener)
public static void RemoveAttListener(IAttListener listener)
```

Apollo owns the iOS ATT prompt end to end: call `RequestTrackingAuthorization()` when your game reaches the right moment (typically from `IPolicyListener.OnPoliciesCompleted`, after the GDPR/consent flow resolves — Apple requires users to understand why tracking is requested first). Apollo displays the system prompt, consumes the user's selection itself (the GTS `aptts` field and IDFA gating update automatically — no separate reporting call exists or is needed), then notifies every registered [`IAttListener`](#iattlistener):

```csharp
public class MyAttListener : IAttListener
{
    public void OnAttAuthorizationCompleted(ATTStatus status)
    {
        // continue your permission chain, feed your own ad SDKs, etc.
    }
}

BFGUnitySDK.AddAttListener(new MyAttListener()); // register BEFORE requesting
BFGUnitySDK.RequestTrackingAuthorization();
```

If iOS has already determined the status (previous answer, or Settings-level restriction), no prompt is shown and listeners fire immediately with the current status — which is why the listener must be registered before the request. Like `IPolicyListener`, ATT listeners are instance-registered and support multiple listeners and runtime add/remove.

Your Xcode project must contain an `NSUserTrackingUsageDescription` Info.plist entry — providing that string remains the game's responsibility.

> iOS-only. On Android and in the Editor, `RequestTrackingAuthorization` is a logged no-op and listeners are never invoked.

---

### Firebase

Wraps Firebase Analytics, Crashlytics, and Cloud Messaging (push). Configured via [`BfgFirebaseSettings.asset`](Documentation/APOLLO_SDK_INTEGRATION_GUIDE.md#bfgfirebasesettingsasset--firebase-configuration); if the asset is missing or `enableFirebase` is off, Firebase is skipped entirely and all of these methods are safe no-ops. Full behavior — including platform build requirements, the iOS messaging gate, and automatic token upload — is documented in [`Documentation/FIREBASE_DESIGN.md`](Documentation/FIREBASE_DESIGN.md) and [`Documentation/FIREBASE_INTEGRATION_GUIDE.md`](Documentation/FIREBASE_INTEGRATION_GUIDE.md).

> **GDPR:** Firebase **Analytics** data collection is **disabled by default** and gated on consent. **Crashlytics is not consent-gated** — it starts at Firebase init (when `enableCrashlytics` is set), regardless of or before any GDPR selection. Apollo's built-in consent dialog drives the Analytics consent automatically; a game running its own consent system UI (**not recommended**) calls `SetFirebaseDataCollectionConsent` with the result itself.

#### `SetFirebaseDataCollectionConsent`

```csharp
public static void SetFirebaseDataCollectionConsent(bool granted)
```

Grants or revokes consent for Firebase Analytics data collection. The choice is persisted across sessions, so call it once per decision rather than every launch (calling on launch with the stored value is harmless). Crashlytics is not affected by this call.

> ⚠️ <ins>**Only call this if your game uses its own custom consent system.**</ins> When Apollo's built-in consent system is used, Apollo sets Firebase data collection automatically from the user's GDPR decision — calling this yourself is unnecessary and risks overwriting the recorded decision.

#### Analytics

```csharp
public static void LogFirebaseEvent(string eventName, Dictionary<string, object> parameters = null)
public static void SetFirebaseUserProperty(string name, string value)
public static void SetFirebaseAnalyticsUserId(string userId)
```

Logs Firebase Analytics events and user attributes. Events are dropped (and logged) until data-collection consent has been granted. Parameter values should be `string`, `long`/`int`, or `double`/`float`; other types are converted to strings. `SetFirebaseAnalyticsUserId(null)` clears the user ID.

#### Crashlytics

```csharp
public static void LogCrashlyticsMessage(string message)
public static void SetCrashlyticsCustomKey(string key, string value)
public static void RecordCrashlyticsException(Exception exception)
```

Adds breadcrumb logs / custom keys to crash reports and records handled (non-fatal) exceptions. The SDK automatically sets the Crashlytics user id to the Apollo App User ID for correlation.

#### Cloud Messaging (Push) — standard visual notifications

The APIs required for standard push notifications — messages with a title/body that the OS
displays as a visible notification (sent from the Firebase console or any FCM-capable server,
targeting topics or device tokens). The user taps the notification and the game receives it via
`IFirebaseMessagingListener.OnMessageOpened`.

```csharp
public static void RequestNotificationPermission()
public static void SubscribeToFcmTopic(string topic)
public static void UnsubscribeFromFcmTopic(string topic)
```

| Method | Description |
|---|---|
| `RequestNotificationPermission` | **Required.** Requests OS notification permission (Android 13+ `POST_NOTIFICATIONS`, iOS APNs) — call it at the moment the prompt should appear (after your consent flow). On iOS, every messaging API is inert on a fresh install until this is called. Safe to call on platforms/versions that do not require an explicit prompt. |
| `SubscribeToFcmTopic` / `UnsubscribeFromFcmTopic` | Manages FCM topic subscriptions for this device — needed only when sending topic-targeted campaigns (e.g. from the Firebase console). Token-targeted sends need no subscription. |

Implement [`IFirebaseMessagingListener`](#ifirebasemessaginglistener) to receive token-refresh
and message callbacks (`OnMessageReceived` for foreground deliveries, `OnMessageOpened` for taps).

**Foreground display — showing (or hiding) the banner while the game is running.** By default,
**neither platform displays the notification banner while the app is foregrounded** — the OS only
auto-displays notifications for a backgrounded/killed app. A notification arriving in the
foreground is instead delivered silently to `OnMessageReceived`, and whether anything appears
on screen is the game's choice. So "hidden in foreground" is what you get with no extra work;
showing the banner takes per-platform setup:

- **Android:** post a **local notification yourself** from `OnMessageReceived` (e.g. with Unity's
  Mobile Notifications package), copying the message's title/body/data into it. Displaying it
  requires a notification channel (Android 8+) and the granted `POST_NOTIFICATIONS` permission
  (Android 13+ — see `RequestNotificationPermission` above). Note the `AndroidManifest.xml`
  `com.google.firebase.messaging.default_notification_icon` / `default_notification_color` /
  `default_notification_channel_id` meta-data entries only customize the notifications FCM
  displays for a **backgrounded** app — no manifest flag exists that turns on foreground display.
  A tap on a game-posted local notification fires that notification's own intent/callback (wired
  by whatever posted it), not Apollo's `OnMessageOpened`.
- **iOS:** foreground presentation is decided natively by the `UNUserNotificationCenter`
  delegate's `willPresentNotification` callback — with no delegate opting in (Unity and the
  Firebase SDK provide none), iOS suppresses the banner. To show it, add a small native plugin or
  post-process addition implementing
  `userNotificationCenter:willPresentNotification:withCompletionHandler:` that passes
  presentation options (`UNNotificationPresentationOptionBanner | List | Sound` on iOS 14+;
  `.alert` on earlier versions). Tapping a foreground-presented banner goes through the normal
  notification-tap path, so it reaches `OnMessageOpened` like a background tap. To hide banners
  again, remove the delegate code or have it pass no presentation options.

Either way, the message itself always reaches `OnMessageReceived` in the foreground — foreground
display only controls what the *user* sees, not what the game receives.

#### Cloud Messaging (Push) — data-only pushes (optional)

**All APIs in this group are optional** — they matter only if your game uses **data-only pushes**.

**How data-only differs from standard push:** a data-only message carries no notification block
(no title/body), so the OS displays nothing and the user is never involved. Instead the payload
is delivered silently to game code via `IFirebaseMessagingListener.OnMessageReceived` — useful
for server-driven content and state (live-event triggers, inventory grants, config nudges).
Standard pushes are for the *user* (a visible banner, a tap); data-only pushes are for the
*game*.

> ⚠️ **Data-only pushes are not guaranteed to arrive on iOS.** Background delivery of silent
> pushes is best-effort — iOS throttles or drops them outright based on battery, Background App
> Refresh, and usage heuristics. Treat data-only as reliable **foreground** messaging only; for
> anything that must reach the device, send a hybrid message (notification block + `data`
> payload) — the visible notification guarantees delivery and the `data` payload survives the
> tap on both platforms. iOS background delivery additionally requires the export-time setup in
> [`Documentation/FIREBASE_INTEGRATION_GUIDE.md`](Documentation/FIREBASE_INTEGRATION_GUIDE.md) (`remote-notification` background mode +
> `UNITY_USES_REMOTE_NOTIFICATIONS=1`).

**Your own send server is required.** The Firebase console can only send visible notification
campaigns — data-only messages must be sent through the **FCM HTTP v1 API** by a server your team
runs (your push portal). Supporting data-only push means:

1. **Stand up the send server/portal** with your Firebase project's service-account key (its
   credential for the FCM v1 API — see the portal prerequisites in
   [`Documentation/FIREBASE_INTEGRATION_GUIDE.md`](Documentation/FIREBASE_INTEGRATION_GUIDE.md)).
2. **Let Apollo register devices with it**: set `tokenUploadUrl` (and optionally
   `tokenUploadApiKey`) in [`BfgFirebaseSettings.asset`](Documentation/APOLLO_SDK_INTEGRATION_GUIDE.md#bfgfirebasesettingsasset--firebase-configuration). Apollo then POSTs
   `{ token, platform, deviceId }` to your server automatically on every FCM token issue and
   rotation — `deviceId` is the SDK's stable BFGUDID, so your server keeps a device registry
   upserted by `deviceId + platform` (repeat uploads are idempotent; the latest token wins).
3. **Send from your server** targeting the stored tokens: data-only FCM v1 messages, sent
   high-priority on Android (normal priority can be deferred by Doze), hybrid on iOS per the
   warning above.

```csharp
public static void GetFcmToken(Action<string> onToken)
public static void DeleteFcmToken(Action<bool> onComplete = null)
public static void SetFcmTokenRegistrationEnabled(bool enabled)
public static bool IsFcmTokenRegistrationEnabled()
```

| Method | Description / role with your push portal |
|---|---|
| `GetFcmToken` | *(optional)* Asynchronously retrieves the current FCM registration token (also logged for debugging). Callback receives `null` if it could not be retrieved. The automatic `tokenUploadUrl` upload normally makes manual token handling unnecessary — use this for debugging or a custom registration flow of your own. |
| `DeleteFcmToken` | *(optional)* Invalidates the current FCM registration token (e.g. on logout or account switch) — the device stops receiving sends targeted at its old token, and when a new token is generated Apollo re-uploads it, replacing the device's row in your portal's registry. Optional callback receives `true` on success. |
| `SetFcmTokenRegistrationEnabled` | *(optional)* Enables/disables automatic FCM token generation — set `false` to defer token creation (and therefore the device's first appearance in your portal's registry) until the user opts in, then `true` afterward. To keep it off from the very first launch, also set the platform startup flag (Android manifest `firebase_messaging_auto_init_enabled=false` / iOS `FirebaseMessagingAutoInitEnabled=NO`). |
| `IsFcmTokenRegistrationEnabled` | *(optional)* Returns whether automatic FCM token generation is currently enabled. |

Full behavior details (token lifecycle, delivery rules, platform quirks) are in
[`Documentation/FIREBASE_DESIGN.md` §5](Documentation/FIREBASE_DESIGN.md#5-cloud-messaging-fcm).

---

## Adapter Interfaces

Adapters connect your game's third-party services into the Unity (Apollo) SDK. Register implementations with `BFGUnitySDK.RegisterAdapter<T>()` before `Initialize()`; implementations need a public parameterless constructor (they are created via reflection). `IAdapter` itself is an empty marker interface.

---

### IAuthenticationAdapter

```csharp
public interface IAuthenticationAdapter : IAdapter
```

**Namespace:** `BFG.Apollo.Auth`

Connects your authentication service to Apollo. Required whenever an `IAuthenticationListener` is registered — SDK initialization fails without it. The adapter drives its own login flow and reports outcomes through the `IAuthenticationListener` it receives in `Initialize`; Apollo never initiates logins or logouts itself.

| Member | Signature | Description |
|---|---|---|
| `Initialize` | `void Initialize(IAuthenticationListener authenticationListener)` | Called during SDK init. Store the listener and report init success/failure through it. |
| `Start` | `void Start()` | Called once all SDK components have initialized. |
| `IsAuthenticated` | `bool IsAuthenticated()` | Whether a user is currently authenticated. Feeds auth state on GTS events. |
| `IsAnonymouslyAuthenticated` | `bool IsAnonymouslyAuthenticated()` | Whether the current authentication is anonymous. |
| `UserID` | `string UserID { get; }` | The authenticated user's ID. Feeds GTS events. |
| `ProviderName` | `string ProviderName { get; }` | Name of the underlying auth provider. |

> A shipped stand-in, `MockAuthenticationAdapter` (`BFG.Apollo.Auth`), satisfies the auth requirement for samples and testing without a real third-party SDK.

---

### IPurchasingAdapter

```csharp
public interface IPurchasingAdapter : IAdapter
```

**Namespace:** `BFG.Apollo.Purchasing`

Connects your purchasing/store library to Apollo. The contract is a single member — Apollo hands the adapter its configuration and listeners at init, and the adapter reports purchase outcomes by calling the `IPurchaseListener` callbacks (`ProcessPurchase`, `OnPurchaseFailed`, etc.).

| Member | Signature | Description |
|---|---|---|
| `Initialize` | `void Initialize(PurchasingConfiguration purchasingConfiguration, IPurchaseListener purchaseListener, IPurchasingInitializationListener initializationListener)` | Called during SDK init with the product configuration (from `PurchasingProductIds.json`) and the listeners to report through. |

---

### IFirebaseAdapter

```csharp
public interface IFirebaseAdapter : IAdapter
```

**Namespace:** `BFG.Apollo.Firebase`

Abstraction over the Firebase Unity SDK used by Apollo's `FirebaseController`. **Apollo ships a concrete default implementation (`DefaultFirebaseAdapter`), so games normally do not implement this interface** — register your own via `RegisterAdapter<T>()` only to customize behavior or for testing. The interface exposes only Apollo-owned/primitive types, so referencing it requires no direct Firebase dependency. All methods must be safe to call when their feature is disabled — implementations no-op rather than throw.

| Member | Signature | Description |
|---|---|---|
| `Initialize` | `void Initialize(FirebaseSettings settings, bool dataCollectionConsentGranted, IFirebaseMessagingListener messagingListener, Action<bool, string> onInitializationComplete)` | Initializes the Firebase SDK (async dependency check) and wires Messaging callbacks. Consent state is applied immediately; completion callback delivers success + optional failure reason on the Unity main thread. |
| `SetDataCollectionConsent` | `void SetDataCollectionConsent(bool granted)` | Enables/disables Analytics data collection (Crashlytics unaffected). |
| `LogEvent` | `void LogEvent(string eventName, IDictionary<string, object> parameters)` | Logs an Analytics event; no-ops without consent. |
| `SetUserProperty` | `void SetUserProperty(string name, string value)` | Sets an Analytics user property. |
| `SetAnalyticsUserId` | `void SetAnalyticsUserId(string userId)` | Sets the Analytics user ID. |
| `LogCrashlyticsMessage` | `void LogCrashlyticsMessage(string message)` | Writes a Crashlytics breadcrumb log. |
| `SetCrashlyticsCustomKey` | `void SetCrashlyticsCustomKey(string key, string value)` | Attaches a custom key/value to crash reports. |
| `RecordException` | `void RecordException(Exception exception)` | Records a non-fatal exception. |
| `SetCrashlyticsUserId` | `void SetCrashlyticsUserId(string userId)` | Associates a user id with crash reports (Apollo passes the App User ID). |
| `GetFcmToken` | `void GetFcmToken(Action<string> onToken)` | Requests the FCM registration token. |
| `SubscribeToTopic` | `void SubscribeToTopic(string topic)` | Subscribes the device to an FCM topic. |
| `UnsubscribeFromTopic` | `void UnsubscribeFromTopic(string topic)` | Unsubscribes the device from an FCM topic. |
| `RequestNotificationPermission` | `void RequestNotificationPermission()` | Requests OS notification permission where required. |
| `DeleteFcmToken` | `void DeleteFcmToken(Action<bool> onComplete)` | Deletes the current FCM token. |
| `SetFcmTokenRegistrationEnabled` | `void SetFcmTokenRegistrationEnabled(bool enabled)` | Enables/disables automatic token generation. |
| `IsFcmTokenRegistrationEnabled` | `bool IsFcmTokenRegistrationEnabled()` | Whether automatic token generation is enabled. |

---

## Listener Interfaces

Listeners receive callbacks from the SDK. There are two registration mechanisms:

- **Type-registered** (`BFGUnitySDK.RegisterListener<T>()`, before `Initialize()`): `IAuthenticationListener`, `IPurchaseListener`, `ITelemetryListener`, `IInitializationListener`, `IFirebaseMessagingListener`. Instances are created via reflection — a public parameterless constructor is required. `IListener` itself is an empty marker interface.
- **Instance-registered** (runtime add/remove, multiple listeners supported): `IPolicyListener` via `AddPolicyListener`/`RemovePolicyListener`, and `IAttListener` via `AddAttListener`/`RemoveAttListener`. These do not implement `IListener`.

---

### IAuthenticationListener

```csharp
public interface IAuthenticationListener : IListener
```

**Namespace:** `BFG.Apollo.Auth`

Receives authentication callbacks, raised by your `IAuthenticationAdapter`. Registering this listener makes authentication mandatory: a matching `IAuthenticationAdapter` must also be registered or SDK initialization fails.

| Method | Signature |
|---|---|
| `OnAuthenticationInitialized` | `void OnAuthenticationInitialized()` |
| `OnAuthenticationInitializeFailed` | `void OnAuthenticationInitializeFailed(string failureReason)` |
| `OnLoginSuccess` | `void OnLoginSuccess()` |
| `OnLoginFailed` | `void OnLoginFailed(string failureReason)` |
| `OnLogoutSuccess` | `void OnLogoutSuccess()` |
| `OnLogoutFailed` | `void OnLogoutFailed(string failureReason)` |

Failure reasons arrive as strings; see [`AuthenticationFailureReason`](#authenticationfailurereason) for the SDK's own vocabulary.

---

### IPurchaseListener

```csharp
public interface IPurchaseListener : IListener
```

**Namespace:** `BFG.Apollo.Purchasing`

Receives purchasing callbacks, raised by your `IPurchasingAdapter`. Registering this listener causes the purchasing subsystem to be constructed at init.

| Method | Signature |
|---|---|
| `OnPurchasingInitialized` | `void OnPurchasingInitialized()` |
| `OnPurchasingInitializationFailed` | `void OnPurchasingInitializationFailed(FetchFailureReason failureReason)` |
| `OnProductsFetched` | `void OnProductsFetched()` |
| `OnProductFetchFailed` | `void OnProductFetchFailed(FetchFailureReason failureReason)` |
| `ProcessPurchase` | `PurchaseProcessingResult ProcessPurchase(PurchaseSuccessData purchaseData)` |
| `OnPurchaseFailed` | `void OnPurchaseFailed(PurchaseFailureData purchaseFailureData)` |
| `OnRestoreInitiated` | `void OnRestoreInitiated()` |
| `OnRestoreFailed` | `void OnRestoreFailed()` |

`ProcessPurchase` returns a [`PurchaseProcessingResult`](#purchaseprocessingresult) indicating whether the purchase was handled immediately (`Complete`) or will be finished later (`Pending`).

---

### IPurchasingInitializationListener

```csharp
public interface IPurchasingInitializationListener
```

**Namespace:** `BFG.Apollo.Purchasing`

Passed to `IPurchasingAdapter.Initialize` alongside the `IPurchaseListener`.

| Method | Signature | Description |
|---|---|---|
| `OnPurchasingInitializedWithNoInternet` | `void OnPurchasingInitializedWithNoInternet()` | Called when the purchasing system initialized but there is no internet connectivity. |

---

### ITelemetryListener

```csharp
public interface ITelemetryListener : IListener
```

**Namespace:** `BFG.Apollo.Telemetry`

| Method | Signature | Description |
|---|---|---|
| `OnTelemetrySent` | `void OnTelemetrySent(bool success, string message)` | Called when telemetry data has been sent, with the outcome and an informational message. |

---

### IInitializationListener

```csharp
public interface IInitializationListener : IListener
```

**Namespace:** `BFG.Apollo.Core`

| Method | Signature | Description |
|---|---|---|
| `InitializationComplete` | `void InitializationComplete()` | SDK initialization finished successfully. |
| `InitializationFailed` | `void InitializationFailed(string failureReason)` | SDK initialization failed. |

---

### IPolicyListener

```csharp
public interface IPolicyListener
```

**Namespace:** `BFG.Apollo.Consent`

Consent-dialog listener. **Instance-registered** via `BFGUnitySDK.AddPolicyListener`/`RemovePolicyListener` (not `RegisterListener<T>`).

| Method | Signature | Description |
|---|---|---|
| `WillShowPolicies` | `void WillShowPolicies()` | Fired once when one or more uncompleted policies are about to be presented. This is the game's opportunity to pause gameplay, intro/loading flow, audio, etc. if necessary while the policy dialog is displayed — it is safe to unpause once `OnPoliciesCompleted` fires. |
| `OnPoliciesCompleted` | `void OnPoliciesCompleted()` | Fired once the consent flow is fully resolved for this check — zero policies outstanding, the fetch failed open, or the dialog queue was answered in full. A listener registered after this already fired is immediately re-delivered the known state. |

See [`Documentation/CONSENT_DESIGN.md`](Documentation/CONSENT_DESIGN.md) for the full flow.

---

### IAttListener

```csharp
public interface IAttListener
```

**Namespace:** `BFG.Apollo.Policy`

ATT-selection listener. **Instance-registered** via `BFGUnitySDK.AddAttListener`/`RemoveAttListener` (not `RegisterListener<T>`).

| Method | Signature | Description |
|---|---|---|
| `OnAttAuthorizationCompleted` | `void OnAttAuthorizationCompleted(ATTStatus status)` | Fired when a `RequestTrackingAuthorization()` call resolves with the user's ATT selection. Can fire in the same frame as the request when iOS has already determined the status — register before requesting. Never fired on non-iOS platforms. Apollo has already consumed the status (GTS `aptts` + IDFA gating) by the time this fires; the callback exists purely so the game can react. |

---

### IFirebaseMessagingListener

```csharp
public interface IFirebaseMessagingListener : IListener
```

**Namespace:** global (no namespace)

Optional. Register via `RegisterListener<T>()` before `Initialize()` to receive Firebase Cloud Messaging callbacks; all are raised on the Unity main thread.

| Method | Signature | Description |
|---|---|---|
| `OnFcmTokenReceived` | `void OnFcmTokenReceived(string token)` | Called when the FCM registration token is first obtained and whenever it is refreshed. |
| `OnMessageReceived` | `void OnMessageReceived(FirebaseRemoteMessage message)` | Called for a push message received while the app is in the foreground. |
| `OnMessageOpened` | `void OnMessageOpened(FirebaseRemoteMessage message)` | Called when the user taps a notification that launches or foregrounds the app. |

---

## Data Types

---

### CustomEventData

```csharp
[Serializable]
public class CustomEventData
```

**Namespace:** `BFG.Apollo.Telemetry.DataObjects.CustomEvent`

Base class for all custom telemetry event payloads. Subclass it to add game-specific fields; subclasses must keep a parameterless constructor (required by `SendCustomEvent<T>`'s `new()` constraint).

| Field | Type | Description |
|---|---|---|
| `eventName` | `string` | Name of the event. |

```csharp
class InventoryChangeEvent : CustomEventData
{
    public string Item;    // e.g. "Sword"
    public string Status;  // e.g. "Drop"
}
```

---

### PurchaseSuccessData

```csharp
public class PurchaseSuccessData
```

**Namespace:** `BFG.Apollo.Purchasing`

Carries the details of a completed purchase. Pass a populated instance to `BFGUnitySDK.SendPurchasingSuccessEvent`; every field is serialized to the GTS purchase event.

| Field | Type | Description |
|---|---|---|
| `productId` | `string` | Store-specific product identifier. |
| `transactionID` | `string` | Unique transaction identifier from the store. |
| `transactionTimestamp` | `long` | Unix timestamp (seconds UTC) of the transaction. Use `0` for restored purchases when the original timestamp is unavailable. |
| `price` | `string` | Purchase price as a decimal string (e.g., `"2.99"`). |
| `currency` | `string` | ISO 4217 currency code (e.g., `"USD"`). |
| `uniqueReceiptID` | `string` | A unique identifier derived from the receipt (e.g., a hash). `null` for restored purchases if not available. |
| `restore` | `bool` | `true` if this is a restore; `false` for a new purchase. |

---

### PurchaseFailureData

```csharp
public class PurchaseFailureData
```

**Namespace:** `BFG.Apollo.Purchasing`

Carries the details of a failed purchase. Pass a populated instance to `BFGUnitySDK.SendPurchasingFailureEvent`.

| Field | Type | Description |
|---|---|---|
| `productId` | `string` | Store-specific product identifier of the attempted purchase. |
| `errorCode` | `int` | Raw numeric error code from the store or purchasing library. |
| `errorReason` | [`PurchaseErrorReason`](#purchaseerrorreason) | Normalized failure reason. |
| `purchasePhase` | [`PurchasePhase`](#purchasephase) | The pipeline phase at which the failure occurred. |

---

### ProductInfo

```csharp
[System.Serializable]
public class ProductInfo
```

**Namespace:** `BFG.Apollo.Purchasing`

Represents a purchasable product.

| Member | Signature | Description |
|---|---|---|
| `ProductID` | `string ProductID` | ID of the product. |
| ctor | `ProductInfo(string productID)` | Creates an instance with the given product ID. |

---

### PurchasingConfiguration

```csharp
[System.Serializable]
public class PurchasingConfiguration
```

**Namespace:** `BFG.Apollo.Core`

The product configuration Apollo passes to `IPurchasingAdapter.Initialize` (loaded from `Resources/PurchasingProductIds.json`).

| Field | Type | Description |
|---|---|---|
| `ProductIds` | `ProductInfo[]` | The configured products. |

---

### FirebaseRemoteMessage

```csharp
public class FirebaseRemoteMessage
```

**Namespace:** `BFG.Apollo.Firebase`

Apollo-owned representation of an FCM push message, delivered through [`IFirebaseMessagingListener`](#ifirebasemessaginglistener) so games can read push payloads without a compile-time Firebase dependency.

| Field | Type | Description |
|---|---|---|
| `From` | `string` | The sender ID / "from" field, if provided by FCM. |
| `MessageId` | `string` | The unique message ID assigned by FCM, if present. |
| `NotificationTitle` | `string` | Notification title, if the message contains a notification block. |
| `NotificationBody` | `string` | Notification body, if the message contains a notification block. |
| `Data` | `Dictionary<string, string>` | Custom key/value data payload. Never null; empty when there is no data payload. |
| `WasOpened` | `bool` | `true` when the message was tapped by the user (launched/foregrounded the app) rather than received in the foreground. |
| `Link` | `string` | The notification's deep-link URL (`link`), if specified; otherwise null. |
| `ClickAction` | `string` | Android `click_action`, if specified; otherwise null. |
| `NotificationIcon` | `string` | Notification icon resource name (Android), if specified; otherwise null. |
| `NotificationSound` | `string` | Notification sound (Android), if specified; otherwise null. |
| `NotificationTag` | `string` | Notification tag (replaces/updates an existing notification), if specified; otherwise null. |
| `NotificationColor` | `string` | Notification accent color (Android, e.g. `"#RRGGBB"`), if specified; otherwise null. |
| `CollapseKey` | `string` | The message collapse key, if provided; otherwise null. |
| `Priority` | `string` | Message priority (e.g. `"high"` / `"normal"`), if provided; otherwise null. |
| `MessageType` | `string` | The FCM message type, if provided; otherwise null. |

> On Android, tap-opened messages carry metadata and `Data` only — FCM strips the notification title/body from the tap intent by design, so `NotificationTitle`/`NotificationBody` are null on tap (they are populated on iOS). Put values the game needs on open into `data`. See [`Documentation/FIREBASE_INTEGRATION_GUIDE.md`](Documentation/FIREBASE_INTEGRATION_GUIDE.md).

---

## Enums

---

### ATTStatus

```csharp
public enum ATTStatus
```

**Namespace:** `BFG.Apollo.Policy`

Mirrors iOS `ATTrackingManager.AuthorizationStatus`. Values are mapped 1:1 to the native integer values — do not reorder or renumber. Delivered to `IAttListener.OnAttAuthorizationCompleted`.

| Value | Integer | Description |
|---|---|---|
| `NotDetermined` | `0` | The user has not yet been prompted. |
| `Restricted` | `1` | Access is restricted by device policy or parental controls. |
| `Denied` | `2` | The user denied permission. |
| `Authorized` | `3` | The user granted permission; the IDFA may be read. |

---

### AuthenticationFailureReason

```csharp
public enum AuthenticationFailureReason
```

**Namespace:** `BFG.Apollo.Auth`

The SDK's authentication-failure vocabulary. Failure reasons reach listeners as strings (`OnLoginFailed(string)` / `OnLogoutFailed(string)`).

| Value | Integer |
|---|---|
| `Unknown` | `0` |
| `AlreadyAuthenticated` | `1` |
| `NotAuthenticated` | `2` |

---

### PurchaseProcessingResult

```csharp
public enum PurchaseProcessingResult
```

**Namespace:** `BFG.Apollo.Purchasing`

Returned by `IPurchaseListener.ProcessPurchase`.

| Value | Description |
|---|---|
| `Complete` | The purchase was fully handled; the transaction can be closed. |
| `Pending` | The purchase will be completed later (e.g. after server-side fulfillment). |

---

### PurchaseErrorReason

```csharp
public enum PurchaseErrorReason
```

**Namespace:** `BFG.Apollo.Purchasing`

Normalized reason for a purchase failure, set on `PurchaseFailureData.errorReason` and serialized to GTS as an integer.

| Value | Integer | Description |
|---|---|---|
| `PurchasingUnavailable` | `0` | Purchasing system unavailable on this device. |
| `ExistingPurchasePending` | `1` | A prior transaction for this product is still open. |
| `ProductUnavailable` | `2` | The product is not available in the store. |
| `SignatureInvalid` | `3` | Receipt signature validation failed. |
| `UserCancelled` | `4` | The user cancelled the purchase flow. |
| `PaymentDeclined` | `5` | The payment method was declined. |
| `DuplicateTransaction` | `6` | This transaction was already processed. |
| `NoConnection` | `7` | No network connectivity. |
| `Unknown` | `8` | Failure reason could not be determined. |

---

### PurchasePhase

```csharp
public enum PurchasePhase
```

**Namespace:** `BFG.Apollo.Purchasing`

Identifies the pipeline stage where a purchase failure occurred, set on `PurchaseFailureData.purchasePhase` and serialized to GTS as an integer. Use `Unknown` if your purchasing library doesn't expose enough detail to distinguish phases.

| Value | Integer | Description |
|---|---|---|
| `Unknown` | `0` | Phase undetermined. |
| `StartPhase` | `1` | Failure at purchase initiation. |
| `PreBuyPhase` | `2` | Failure during pre-purchase validation. |
| `HealthCheckPhase` | `3` | Reserved; not currently used. |
| `StoreResponsePhase` | `4` | Failure processing the store's response. |
| `ClientVerificationPhase` | `5` | Failure during client-side receipt verification. |
| `ServerVerificationPhase` | `6` | Failure during server-side receipt verification. |

---

### FetchFailureReason

```csharp
public enum FetchFailureReason
```

**Namespace:** `BFG.Apollo.Purchasing`

Reason for a purchasing-initialization or product-fetch failure, delivered to `IPurchaseListener.OnPurchasingInitializationFailed` / `OnProductFetchFailed`.

| Value | Integer | Description |
|---|---|---|
| `Unknown` | `0` | Failure reason could not be determined. |
| `PurchasingUnavailable` | `1` | Purchasing system unavailable on this device. |
| `ApplicationNotKnown` | `2` | The application is not recognized by the store. |
| `NoProductsAvailable` | `3` | No products were returned for the configured IDs. |
| `NoConnection` | `4` | No network connectivity. |
| `AndroidBillingIntialization` | `5` | Android billing-client initialization failed. (Spelling is the pinned public name.) |
