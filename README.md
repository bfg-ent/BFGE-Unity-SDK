# Apollo SDK API Reference

**SDK Version:** 0.1.0
**Platform:** Unity (iOS & Android)

---

## Table of Contents

1. [Overview](#overview)
2. [Setup & Initialization](#setup--initialization)
3. [BFGUnitySDK](#bfgunitysdksdk-entry-point) — SDK entry point
4. [Firebase](#firebase) — Analytics, Crashlytics, Cloud Messaging
5. [Adapter Interfaces](#adapter-interfaces)
   - [IAuthenticationAdapter](#iauthenticationadapter)
6. [Listener Interfaces](#listener-interfaces)
   - [IAuthenticationListener](#iauthenticationlistener)
   - [ITelemetryListener](#itelemetrylistener)
   - [IFirebaseMessagingListener](#ifirebasemessaginglistener)
7. [Data Types](#data-types)
   - [CustomEventData](#customeventdata)
   - [PurchaseSuccessData](#purchasesuccessdata)
   - [PurchaseFailureData](#purchasefailuredata)
8. [Enums](#enums)
   - [ATTStatus](#attstatus)
   - [IdentityProviderName](#identityprovidername)
   - [PurchaseErrorReason](#purchaseerrorreason)
   - [PurchasePhase](#purchasephase)

---

## Overview

This reference covers the following Apollo SDK subsystems:

| Subsystem | Description |
|---|---|
| **Initialization** | Registers adapters/listeners, then calls `Initialize()` |
| **Authentication** | Implements `IAuthenticationAdapter` and `IAuthenticationListener` |
| **Telemetry** | Sends custom game-lifecycle events and purchase events; implements `ITelemetryListener` |
| **Purchasing** | Reports purchase success and failure via `BFGUnitySDK` telemetry helpers |
| **Consent / Privacy** | Applies ATT status (iOS) and third-party tracking consent (GDPR) |
| **Firebase** | Analytics (GDPR-gated), Crashlytics (always on), and Cloud Messaging (push) — configured via `BfgFirebaseSettings.asset` |

This reference does not cover the Attribution adapter, Purchasing adapter, or Consent management types (`ConsentList`, `ConsentStatus`, `GDPRStatus`).

---

## Setup & Initialization

Initialize the SDK as follows:

```csharp
// 1. Register the authentication adapter implementation
BFGUnitySDK.RegisterAdapter<AuthenticationAdapter>();

// 2. Register listener implementations
BFGUnitySDK.RegisterListener<BasicAuthListener>();
BFGUnitySDK.RegisterListener<BasicTelemetryListener>();

// 3. Initialize — must follow all registrations
BFGUnitySDK.Initialize();

// 4. Supply the attribution ID (e.g. AppsFlyer device ID) — included in all GTS events as 'afid'
BFGUnitySDK.SetAttributionID(ATTRIBUTION_ID);
```

All `RegisterAdapter<T>` and `RegisterListener<T>` calls must occur before `Initialize()`.

---

## BFGUnitySDK — SDK Entry Point

```csharp
public static class BFGUnitySDK
```

No namespace; available globally.

---

### Initialization

#### `Initialize`

```csharp
public static void Initialize()
```

Starts the SDK. Wires all registered adapters and listeners and begins lifecycle tracking. Call once per session, after all registrations.

---

### Adapter & Listener Registration

#### `RegisterAdapter<T>`

```csharp
public static void RegisterAdapter<T>() where T : IAdapter, new()
```

Registers a concrete adapter. `T` must implement `IAdapter` and have a parameterless constructor. Call before `Initialize()`.

#### `RegisterListener<T>`

```csharp
public static void RegisterListener<T>() where T : IListener, new()
```

Registers a concrete listener. `T` must implement `IListener` and have a parameterless constructor. Call before `Initialize()`.

---

### Attribution ID

#### `SetAttributionID`

```csharp
public static void SetAttributionID(string attributionID)
```

Stores the attribution provider's device ID (e.g., the AppsFlyer ID). Once set, this value is included in all outbound GTS telemetry events as the `afid` field. The value is persisted across sessions via `PlayerPrefs`.

| Parameter | Type | Description |
|---|---|---|
| `attributionID` | `string` | The attribution provider's device identifier. |

> Call this as soon as the attribution ID is available — typically immediately after `Initialize()`, once your attribution adapter has obtained the ID from its underlying SDK. Any telemetry events dispatched before `SetAttributionID` is called will have an empty `afid`.

---

### Consent & Privacy

#### `ApplyAttConsentStatus`

```csharp
public static void ApplyAttConsentStatus(ATTStatus authorized)
```

Stores the iOS App Tracking Transparency (ATT) consent result. Call this after receiving the OS callback from the ATT prompt. The SDK reads this value when building telemetry payloads to determine whether the IDFA may be included.

| Parameter | Type | Description |
|---|---|---|
| `authorized` | [`ATTStatus`](#attstatus) | The authorization status returned by the OS after the ATT prompt. |

```csharp
// Example: native bridge delivers status as a string integer
if (int.TryParse(statusCode, out int value))
{
    ATTStatus status = (ATTStatus)value;
    BFGUnitySDK.ApplyAttConsentStatus(status);
}
```

> iOS-specific. No-op on Android.

#### `ApplyThirdPartyTrackingConsentStatus`

```csharp
public static void ApplyThirdPartyTrackingConsentStatus(bool authorized = true)
```

Stores the user's consent for third-party tracking. This value is written into all outbound GTS telemetry events as the `tpte` (third-party tracking enabled) field. Call when the GDPR/consent UI is dismissed.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `authorized` | `bool` | `true` | `true` if the user granted consent; `false` if denied or withdrawn. |

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

| Type parameter | Constraint |
|---|---|
| `T` | Subclass of `CustomEventData`, `new()` |

#### `SetAppUserId`

```csharp
public static void SetAppUserId(string appUserId)
```

Sets a game-level user identifier attached to all subsequent telemetry events. Persisted across sessions.

| Parameter | Type | Description |
|---|---|---|
| `appUserId` | `string` | Your game's identifier for this user. |

#### `GetAppUserId`

```csharp
public static string GetAppUserId()
```

Returns the currently stored application user ID.

**Returns:** `string` — The app user ID, or an empty string if none has been set.

---

### Purchasing Telemetry

#### `SendPurchasingSuccessEvent`

```csharp
public static void SendPurchasingSuccessEvent(PurchaseSuccessData customEventData)
```

Reports a completed purchase (including restores) to the telemetry system.

| Parameter | Type | Description |
|---|---|---|
| `customEventData` | [`PurchaseSuccessData`](#purchasesuccessdata) | Transaction details. |

#### `SendPurchasingFailureEvent`

```csharp
public static void SendPurchasingFailureEvent(PurchaseFailureData customEventData)
```

Reports a failed purchase to the telemetry system.

| Parameter | Type | Description |
|---|---|---|
| `customEventData` | [`PurchaseFailureData`](#purchasefailuredata) | Failure details. |

---

## Firebase

The SDK wraps Firebase Analytics, Crashlytics, and Cloud Messaging (push). Apollo owns the Firebase
integration internally — you enable features in a settings asset and call simple APIs; you do not
write Firebase glue code. An optional listener delivers push callbacks.

> **In-App Messaging note:** Firebase In-App Messaging is **not supported by the Firebase Unity SDK**
> (Android/iOS/Flutter only), so it is intentionally not part of this integration.

**Enabling Firebase:** create the settings asset via right-click
**Create → BFG/Apollo/Firebase Settings** and name it `BfgFirebaseSettings.asset` inside any
`Resources/` folder — the SDK loads it from `Resources/BfgFirebaseSettings` at runtime. (In the
Apollo source project the **BFG → Apollo → Firebase Settings** menu does the same and places it at
`Assets/Dependencies/Bfg/Configuration/Resources/`; that menu is an editor script and is not
included in the DLL package games consume.) If the asset is missing or `enableFirebase` is off, the
SDK skips Firebase entirely. The Firebase Unity SDK + EDM4U must also be imported and the `APOLLO_FIREBASE`
build define set — see `FIREBASE_SETUP.md`.

> **GDPR:** Firebase **Analytics** data collection is **disabled by default** and gated on consent.
> **Crashlytics is not consent-gated** — it starts at Firebase init (when `enableCrashlytics` is
> set), regardless of or before any GDPR selection.
> The SDK does not implement GDPR — your game owns the consent prompt and calls
> [`SetFirebaseDataCollectionConsent`](#setfirebasedatacollectionconsent) with the result.

---

### Consent

#### `SetFirebaseDataCollectionConsent`

```csharp
public static void SetFirebaseDataCollectionConsent(bool granted)
```

Enables or disables Firebase Analytics data collection. Call after your GDPR flow resolves.
The choice is persisted across sessions. Crashlytics is not affected — it is always on when
`enableCrashlytics` is set.

| Parameter | Type | Description |
|---|---|---|
| `granted` | `bool` | `true` if the user consented to data collection; otherwise `false`. |

---

### Analytics

```csharp
public static void LogFirebaseEvent(string eventName, Dictionary<string, object> parameters = null)
public static void SetFirebaseUserProperty(string name, string value)
public static void SetFirebaseAnalyticsUserId(string userId)
```

Logs Firebase Analytics events and user attributes. Events are dropped (and logged) until
data-collection consent has been granted. Parameter values should be `string`, `long`/`int`, or
`double`/`float`; other types are converted to strings.

---

### Crashlytics

```csharp
public static void LogCrashlyticsMessage(string message)
public static void SetCrashlyticsCustomKey(string key, string value)
public static void RecordCrashlyticsException(Exception exception)
```

Adds breadcrumb logs / custom keys to crash reports and records handled (non-fatal) exceptions. The
SDK automatically sets the Crashlytics user id to the Apollo App User ID for correlation.

---

### Cloud Messaging (Push)

```csharp
public static void GetFcmToken(Action<string> onToken)
public static void SubscribeToFcmTopic(string topic)
public static void UnsubscribeFromFcmTopic(string topic)
public static void RequestNotificationPermission()
public static void DeleteFcmToken(Action<bool> onComplete = null)
public static void SetFcmTokenRegistrationEnabled(bool enabled)
public static bool IsFcmTokenRegistrationEnabled()
```

Retrieves the FCM registration token (also logged for debugging), manages topic subscriptions, and
requests OS notification permission where required (Android 13+ `POST_NOTIFICATIONS`, iOS APNs).
`DeleteFcmToken` invalidates the current token (e.g. on logout);
`SetFcmTokenRegistrationEnabled` / `IsFcmTokenRegistrationEnabled` control automatic token
generation (e.g. to defer token creation until consent).
Implement [`IFirebaseMessagingListener`](#ifirebasemessaginglistener) to receive token-refresh and
message callbacks.

**Automatic token upload:** when `tokenUploadUrl` is set in `BfgFirebaseSettings`, the SDK POSTs the
token to that URL whenever Firebase issues or rotates it — JSON body `{ token, platform, deviceId }`
where `deviceId` is the SDK's stable device id (BFGUDID) and `platform` is `ios`/`android`/`editor`.
If `tokenUploadApiKey` is set it is sent as an `x-api-key` header. Game code does not need to handle
token uploads itself.

On iOS the permission prompt appears **only** when the game calls `RequestNotificationPermission()`
(or when `requestNotificationPermissionOnStart` is enabled) — the game controls the timing, e.g.
after its GDPR/ATT flow. Until the first request is made on a given install, **all Cloud Messaging
APIs are inert** — `GetFcmToken` invokes its callback with `null`; topic subscribe/unsubscribe,
`DeleteFcmToken` and `SetFcmTokenRegistrationEnabled` no-op; `IsFcmTokenRegistrationEnabled` returns
`false` — because on iOS the first touch of any FirebaseMessaging API shows the OS prompt and
fetches a token. From the next launch onward the listeners attach automatically during init. On a
fresh install, expect the token to be issued once before APNs registration completes and rotated
once the APNs token is set (so `OnFcmTokenReceived` / the token upload fire twice — the push server
keys rows by deviceId+platform, so the latest wins).

> **iOS builds** additionally require Firebase-Console and Xcode-export configuration that Unity
> does not produce (APNs Auth Key, push entitlement, `remote-notification` background mode,
> `UNITY_USES_REMOTE_NOTIFICATIONS=1`) — see the iOS section of `FIREBASE_SETUP.md`.

On Android there is no messaging gate: the FCM listeners attach at SDK init, so the token (and its
automatic upload) and foreground `OnMessageReceived` callbacks work regardless of permission state.
`RequestNotificationPermission()` shows the Android 13+ `POST_NOTIFICATIONS` runtime prompt (no-op
below API 33) via Unity's Android permission API — the permission only controls whether
notifications display. Notification opens are delivered to `OnMessageOpened` with no game code:
cold-start launches are read from the launch Activity's intent at init, warm background taps come
via the Firebase opened event (filled in from the tap intent), and both paths are de-duplicated by
message id. Note that on Android an opened message carries metadata and the custom `data` payload
only — FCM strips the notification title/body from the tap intent by design, so
`NotificationTitle`/`NotificationBody` are null on tap (they are populated on iOS). Put values the
game needs on open into `data`.

> **Android builds** must declare `POST_NOTIFICATIONS` in the game's `AndroidManifest.xml` and use
> Firebase's `MessagingUnityPlayerActivity` as the launcher activity for background-tap opens —
> see the Android section of `FIREBASE_SETUP.md`.

---

## Adapter Interfaces

Adapters are interfaces your game implements to connect third-party services into the Apollo SDK.

---

### IAuthenticationAdapter

```csharp
public interface IAuthenticationAdapter : IAdapter
```

**Namespace:** `BFG.Apollo.Auth`
**Implemented by:** `AuthenticationAdapter`

This adapter connects a Firebase-backed authentication service to the Apollo SDK. It exposes a singleton via `AuthenticationAdapter.getInstance()` so other systems can read and set auth state directly.

| Member | Signature | Implementation Notes |
|---|---|---|
| `ProviderName` | `string ProviderName { get; }` | Returns `"FirebaseAuthentication"` |
| `UserID` | `string UserID { get; }` | Reads from `PlayerPrefs`; defaults to a constant default ID if not set |
| `Initialize` | `void Initialize(IAuthenticationListener authenticationListener)` | Stores the singleton reference; immediately calls `authenticationListener.OnAuthenticationInitialized()` |
| `Start` | `void Start()` | Empty — no deferred startup work needed |
| `IsAuthenticated` | `bool IsAuthenticated()` | Returns `authenticatedState`, which is backed by `PlayerPrefs` and survives restarts |
| `IsAnonymouslyAuthenticated` | `bool IsAnonymouslyAuthenticated()` | Returns `false` — anonymous auth is not used |
| `Login` | `void Login(IdentityProviderName identityProviderName)` | Empty — logins are not initiated through the SDK in this implementation |
| `Logout` | `void Logout()` | Empty — logouts are not initiated through the SDK in this implementation |

> **Note on persistence:** Both `UserID` and `IsAuthenticated()` read from `PlayerPrefs`, so their values survive app restarts without requiring a new login. They can be updated at runtime through `SetUserID(string)` and `SetAuthenticatedState(bool)` (non-interface helpers on `AuthenticationAdapter`).

---

## Listener Interfaces

Listeners receive callbacks from the SDK. Your implementations are registered before `Initialize()`.

---

### IAuthenticationListener

```csharp
public interface IAuthenticationListener : IListener
```

**Namespace:** `BFG.Apollo.Auth`
**Implemented by:** `BasicAuthListener`

| Method | Signature | Behavior |
|---|---|---|
| `OnAuthenticationInitialized` | `void OnAuthenticationInitialized()` | Logs `"Authentication initialization successful"` |
| `OnAuthenticationInitializeFailed` | `void OnAuthenticationInitializeFailed(string failureReason)` | Logs the failure reason |
| `OnLoginSuccess` | `void OnLoginSuccess()` | Logs `"Login Success"` |
| `OnLoginFailed` | `void OnLoginFailed(string failureReason)` | Logs a warning with the failure reason |
| `OnLogoutSuccess` | `void OnLogoutSuccess()` | Logs `"Logout Success"` |
| `OnLogoutFailed` | `void OnLogoutFailed(string failureReason)` | Logs the failure reason |

---

### ITelemetryListener

```csharp
public interface ITelemetryListener : IListener
```

**Namespace:** `BFG.Apollo.Telemetry`
**Implemented by:** `BasicTelemetryListener`

| Method | Signature | Behavior |
|---|---|---|
| `OnTelemetrySent` | `void OnTelemetrySent(bool success, string message)` | Logs `message` to the Unity console regardless of `success` |

---

### IFirebaseMessagingListener

```csharp
public interface IFirebaseMessagingListener : IListener
```

**Namespace:** global (no namespace)

Optional. Register before `Initialize()` to receive Firebase Cloud Messaging callbacks.

| Method | Signature | Behavior |
|---|---|---|
| `OnFcmTokenReceived` | `void OnFcmTokenReceived(string token)` | Called when the FCM registration token is obtained or refreshed. |
| `OnMessageReceived` | `void OnMessageReceived(FirebaseRemoteMessage message)` | Called for a message received while the app is foregrounded. |
| `OnMessageOpened` | `void OnMessageOpened(FirebaseRemoteMessage message)` | Called when the user taps a notification that launches/foregrounds the app. |

---

## Data Types

---

### CustomEventData

```csharp
[Serializable]
public class CustomEventData
```

**Namespace:** `BFG.Apollo.Telemetry.DataObjects.CustomEvent`

Base class for all custom telemetry event payloads. Subclass this to add game-specific fields.

| Field | Type | Description |
|---|---|---|
| `eventName` | `string` | Name of the event. Set this on your subclass instance before passing to `SendCustomEvent`. |

**Example subclasses:**

```csharp
// Game lifecycle event
class GameLifecycleEvent : CustomEventData
{
    public string HeartsAvailable;  // Current lives count as a string
}

// Inventory change event
class InventoryChangeEvent : CustomEventData
{
    public string Item;    // Item name (e.g., "Sword")
    public string Status;  // Action (e.g., "Drop")
}
```

Type constraint for `SendCustomEvent<T>`: `T` must subclass `CustomEventData` and have a parameterless constructor.

---

### PurchaseSuccessData

```csharp
public class PurchaseSuccessData
```

**Namespace:** `BFG.Apollo.Purchasing`

Carries the details of a completed purchase. Pass a populated instance to `BFGUnitySDK.SendPurchasingSuccessEvent`.

| Field | Type | Description |
|---|---|---|
| `productId` | `string` | Store-specific product identifier. |
| `transactionID` | `string` | Unique transaction identifier from the store. |
| `transactionTimestamp` | `long` | Unix timestamp (seconds UTC) of the transaction. Use `0` for restored purchases when the original timestamp is unavailable. |
| `price` | `string` | Purchase price as a decimal string (e.g., `"2.99"`). Use `localizedPrice.ToString(CultureInfo.InvariantCulture)` for new purchases; use `localizedPriceString` for restored purchases. |
| `currency` | `string` | ISO 4217 currency code (e.g., `"USD"`). |
| `receipt` | `string` | Raw receipt data from the store. |
| `uniqueReceiptID` | `string` | A unique identifier derived from the receipt (e.g., a hash). Pass `null` for restored purchases if not available. |
| `restore` | `bool` | `true` if this is a restore; `false` for a new purchase. |
| `signature` | `string` | Purchase signature (Android). Pass `null` on iOS or when unavailable. |
| `description` | `string` | Localized product description from the store. |

**Example — new purchase:**

```csharp
BFGUnitySDK.SendPurchasingSuccessEvent(new PurchaseSuccessData
{
    currency             = cartItem.Product.metadata.isoCurrencyCode,
    description          = cartItem.Product.metadata.localizedDescription,
    price                = cartItem.Product.metadata.localizedPrice.ToString(CultureInfo.InvariantCulture),
    productId            = cartItem.Product.definition.storeSpecificId,
    receipt              = obj.Info.Receipt,
    uniqueReceiptID      = obj.Info.Receipt.GetHashCode().ToString(),
    restore              = false,
    signature            = null,
    transactionID        = obj.Info.TransactionID,
    transactionTimestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
});
```

**Example — restore:**

```csharp
BFGUnitySDK.SendPurchasingSuccessEvent(new PurchaseSuccessData
{
    currency             = cartItem.Product.metadata.isoCurrencyCode,
    description          = cartItem.Product.metadata.localizedDescription,
    price                = cartItem.Product.metadata.localizedPriceString,
    productId            = cartItem.Product.definition.storeSpecificId,
    receipt              = confirmedOrder.Info.Receipt,
    uniqueReceiptID      = null,
    restore              = true,
    signature            = null,
    transactionID        = confirmedOrder.Info.TransactionID,
    transactionTimestamp = 0
});
```

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
| `errorMessage` | `string` | Human-readable description of the error. |
| `errorReason` | [`PurchaseErrorReason`](#purchaseerrorreason) | Normalized failure reason. When using Unity IAP, cast the `FailureReason` integer directly: `(PurchaseErrorReason)(int)obj.FailureReason`. |
| `purchasePhase` | [`PurchasePhase`](#purchasephase) | The pipeline phase at which the failure occurred. |

**Example:**

```csharp
BFGUnitySDK.SendPurchasingFailureEvent(new PurchaseFailureData
{
    errorCode     = (int)obj.FailureReason,
    errorMessage  = obj.Details,
    productId     = cartItem.Product.definition.storeSpecificId,
    errorReason   = (PurchaseErrorReason)(int)obj.FailureReason,
    purchasePhase = PurchasePhase.Unknown
});
```

---

## Enums

---

### ATTStatus

```csharp
public enum ATTStatus
```

**Namespace:** `BFG.Apollo.Policy`

Mirrors iOS `ATTrackingManager.AuthorizationStatus`. Values are mapped 1:1 to the native integer values delivered by the iOS ATT callback.

| Value | Integer | Description |
|---|---|---|
| `NotDetermined` | `0` | The user has not yet been prompted. |
| `Restricted` | `1` | Access is restricted by device policy or parental controls. |
| `Denied` | `2` | The user denied permission. |
| `Authorized` | `3` | The user granted permission; the IDFA may be read. |

When the native iOS bridge delivers the status as a string integer, cast it as follows:

```csharp
ATTStatus status = (ATTStatus)value;
BFGUnitySDK.ApplyAttConsentStatus(status);
```

> `ATTStatus.Unknown` is an alias for `NotDetermined` (both equal `0`) and is used only internally by the SDK. Always use `NotDetermined` in app code.

---

### IdentityProviderName

```csharp
public enum IdentityProviderName
```

**Namespace:** `BFG.Apollo.Auth`

Used as the parameter type for `IAuthenticationAdapter.Login()`. If your implementation does not initiate identity-provider logins through the SDK, `Login()` may be a no-op.

| Value | Description |
|---|---|
| `Mock` | Test/mock provider. Do not ship. |
| `Apple` | Sign in with Apple. |
| `Google` | Sign in with Google. |
| `Facebook` | Sign in with Facebook. |

---

### PurchaseErrorReason

```csharp
public enum PurchaseErrorReason
```

**Namespace:** `BFG.Apollo.Purchasing`

Normalized reason for a purchase failure, set on `PurchaseFailureData.errorReason`. When using Unity IAP, cast the `FailureReason` integer directly: `(PurchaseErrorReason)(int)failureReason`.

| Value | Description |
|---|---|
| `PurchasingUnavailable` | Purchasing system unavailable on this device. |
| `ExistingPurchasePending` | A prior transaction for this product is still open. |
| `ProductUnavailable` | The product is not available in the store. |
| `SignatureInvalid` | Receipt signature validation failed. |
| `UserCancelled` | The user cancelled the purchase flow. |
| `PaymentDeclined` | The payment method was declined. |
| `DuplicateTransaction` | This transaction was already processed. |
| `NoConnection` | No network connectivity. |
| `Unknown` | Failure reason could not be determined. |

---

### PurchasePhase

```csharp
public enum PurchasePhase
```

**Namespace:** `BFG.Apollo.Purchasing`

Identifies the pipeline stage where a purchase failure occurred, set on `PurchaseFailureData.purchasePhase`. When using Unity IAP, which does not map directly to these phases, use `PurchasePhase.Unknown`.

| Value | Integer | Description |
|---|---|---|
| `Unknown` | `0` | Phase undetermined. Use when the failure source does not map to a specific phase. |
| `StartPhase` | `1` | Failure at purchase initiation. |
| `PreBuyPhase` | `2` | Failure during pre-purchase validation. |
| `HealthCheckPhase` | `3` | Reserved; not currently used. |
| `StoreResponsePhase` | `4` | Failure processing the store's response. |
| `ClientVerificationPhase` | `5` | Failure during client-side receipt verification. |
| `ServerVerificationPhase` | `6` | Failure during server-side receipt verification. |
