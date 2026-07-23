# Apollo SDK Integration Guide

This document is a companion to the [API Reference](./README.md). While the API Reference describes what each type and method does, this guide walks through *how* to integrate the SDK from scratch — covering configuration, setup, and each feature in context.

**SDK Version:** 0.1.0
**Platform:** Unity (iOS & Android)

---

## Table of Contents

1. [How the SDK Works](#how-the-sdk-works)
2. [Required Files](#required-files)
3. [BfgSettings.asset — Game Configuration](#bfgsettingsasset--game-configuration)
4. [BfgDebugSettings.asset — Debug Configuration](#bfgdebugsettingsasset--debug-configuration)
5. [BfgFirebaseSettings.asset — Firebase Configuration](#bfgfirebasesettingsasset--firebase-configuration)
6. [ApolloNetworkConfig.json — Network Endpoints](#apollonetworkconfigjson--network-endpoints)
7. [Integration Walkthrough](#integration-walkthrough)
   - [Step 1 — Implement IAuthenticationAdapter](#step-1--implement-iauthenticationadapter)
   - [Step 2 — Implement IAuthenticationListener](#step-2--implement-iauthenticationlistener)
   - [Step 3 — Implement ITelemetryListener](#step-3--implement-itelemetrylistener)
   - [Step 4 — Register, Initialize, and Supply the Attribution ID](#step-4--register-initialize-and-supply-the-attribution-id)
8. [Feature Guide](#feature-guide)
   - [Custom Telemetry Events](#custom-telemetry-events)
   - [App User ID](#app-user-id)
   - [Purchase Telemetry](#purchase-telemetry)
   - [Consent: App Tracking Transparency (iOS)](#consent-app-tracking-transparency-ios)
   - [Consent: Third-Party Tracking (GDPR)](#consent-third-party-tracking-gdpr)
   - [Firebase (Analytics, Crashlytics, Messaging)](#firebase-analytics-crashlytics-messaging)
9. [What Happens Inside Initialize()](#what-happens-inside-initialize)
10. [Common Pitfalls](#common-pitfalls)

---

## How the SDK Works

The Apollo SDK follows an **adapter/listener pattern**. Before calling `Initialize()`, your game registers:

- **Adapters** — classes you implement that connect third-party services (authentication providers, attribution SDKs) to the Apollo SDK. The SDK calls into your adapter.
- **Listeners** — classes you implement to receive callbacks when the SDK reports events (login success, telemetry sent, etc.).

At initialization the SDK reads two configuration assets from the `Resources` folder, then constructs and starts its internal subsystems in a fixed order. Telemetry events are queued and flushed to a configurable network endpoint defined in a JSON file also in `Resources`.

The minimum integration requires:

1. One adapter: `IAuthenticationAdapter`
2. Two listeners: `IAuthenticationListener`, `ITelemetryListener`
3. Three configuration files: `BfgSettings.asset`, `BfgDebugSettings.asset`, `ApolloNetworkConfig.json`

---

## Required Files

The SDK loads these files automatically during `Initialize()`. All three must be present in a Unity `Resources` folder.

| File | Type | Required |
|---|---|---|
| `BfgSettings.asset` | Unity ScriptableObject | Yes |
| `BfgDebugSettings.asset` | Unity ScriptableObject | No (defaults applied if absent) |
| `ApolloNetworkConfig.json` | JSON TextAsset | Yes |

The SDK looks for these files by name using `Resources.Load()`, so they must be named exactly as shown. They do not need to be in the root `Resources` folder — any `Resources` subfolder works.

### Native iOS plugins (bundled — no game action required)

The Apollo DLL calls native iOS code via `[DllImport("__Internal")]` for device info
(`_GetIfa`, `_GetIDFV`, `_GetCarrierName`, `_IsPushNotificationEnabled`,
`_GetApplicationBuildVersion`) and Keychain persistence (`getKey`, `setKey`, `deleteKey`). The
implementations ship **inside the package** at `Plugins/iOS/Apollo/` (`ApolloUtil.mm`,
`KeyChainPlugin.mm/.h`, `UICKeyChainStore.m/.h`) with iOS-only import settings and the
`AdSupport`/`CoreTelephony` framework dependencies preconfigured — Unity compiles them into iOS
builds automatically.

> **Migration note (upgrading from package versions without these files):** if your project
> previously hand-copied Apollo native files into `Assets/Plugins/iOS/` (e.g. an `Apollo/` folder
> with `ApolloUtil.mm` / `KeyChainPlugin.mm` / `UICKeyChainStore.*`), **delete your local copies**
> when upgrading — keeping both results in duplicate-symbol linker errors in Xcode. Without the
> package copies (older package versions), iOS builds fail with unresolved symbols like `_GetIfa`
> or `_getKey`; upgrading the package fixes that with no manual file copying.

### Device id (bfgudid) persistence on iOS

The SDK's stable device id (`bfgudid`, used by GTS telemetry and FCM token uploads) is
deterministic on iOS: derived as `SHA1(IDFV + "BFGUDID")`, so it is identical for every app from
the same App Store vendor on a device and survives reinstalls while at least one vendor app is
installed. The iOS Keychain (item `com.apollo.sdk.bfgudid`, service `com.bfg.apollo`) covers the
remaining case — the user removing every vendor app.

**For cross-app sharing and full uninstall-survival, each game must add the Keychain Sharing
entitlement** with the access group:

```
$(AppIdentifierPrefix)com.bfg.apollo.shared
```

Add it in a post-process build step via `ProjectCapabilityManager.AddKeychainSharing(...)` — see
Galaxy Gems' `Assets/Scripts/Editor/iOSPostProcessBuild.cs` for the reference implementation.
Sharing only works between apps signed by the **same Apple team** (the access group is prefixed by
the team's App Identifier Prefix). Without the entitlement the SDK automatically falls back to a
per-app keychain: the id still survives reinstalls of that app, it just isn't shared across apps.

> **Android caveat:** Android's id is derived from `ANDROID_ID`, which since Android 8 is scoped
> per app-**signing key** — different games share an id only if they ship with the same signing
> key (watch out for per-app Play App Signing keys).

### Android runtime dependency (bundled via EDM4U) + AD_ID permission

On Android the SDK reads the advertising id (`adid`/`ifa` telemetry fields) via
`com.google.android.gms.ads.identifier.AdvertisingIdClient`, which requires the
`com.google.android.gms:play-services-ads-identifier` Gradle dependency. The package declares it in
`Editor/ApolloDependencies.xml`, which the External Dependency Manager (EDM4U) resolves into your
Gradle build automatically — no game action needed when EDM4U is present (it is, for any game using
the Firebase features). If your project does not use EDM4U, add the line manually to
`mainTemplate.gradle`:

```groovy
implementation 'com.google.android.gms:play-services-ads-identifier:18.0.1'
```

**Beware the silent failure mode:** without this dependency the game still builds and runs — the
SDK catches the missing class and telemetry ships with an empty/unknown advertising id.

Games must also declare the ad-id permission in their `AndroidManifest.xml` (required on
Android 13+; without it the ad id is zeroed):

```xml
<uses-permission android:name="com.google.android.gms.permission.AD_ID" />
```

---

## BfgSettings.asset — Game Configuration

`BfgSettings.asset` is a Unity ScriptableObject of type `GameInfos`. It is the primary configuration asset for the SDK and contains separate configuration blocks for iOS and Android. At runtime, the SDK automatically selects the correct platform block (the Android block is also used in the Unity Editor).

### Creating the Asset

In the Unity Editor: **Assets → Create → BFG → Game Infos**. The resulting asset must be saved into a `Resources` folder and named `BfgSettings`.

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `GameName` | `string` | The game's display name. |
| `GameId` | `int` | The internal numeric game identifier. |
| `IosConfiguration` | `GameConfiguration` | Platform-specific settings for iOS builds. |
| `AndroidConfiguration` | `GameConfiguration` | Platform-specific settings for Android builds and the Unity Editor. |
| `AuthSetting` | `AuthSetting` | Authentication service configuration (shared across platforms). |
| `PolicySetting` | `PolicySetting` | Consent management configuration (shared across platforms). |

### GameConfiguration Fields (IosConfiguration / AndroidConfiguration)

These fields are filled in twice — once for each platform block.

| Field | Type | Used By | Description |
|---|---|---|---|
| `GameStoreId` | `string` | Telemetry | The App Store product ID (iOS) or Play Store package name (Android). Included in every outbound GTS event. |
| `GameCenterId` | `string` | Telemetry (iOS only) | The Game Center identifier for the title. Included in iOS GTS events. |
| `AuthApplicationId` | `string` | Authentication | The application ID for your authentication backend. Passed to `IAuthenticationAdapter.Initialize()` via `AttributionConfiguration`. |
| `AttributionApplicationID` | `string` | Attribution | The application ID for your attribution provider (e.g., AppsFlyer app ID). Passed to `IAttributionAdapter.Initialize()`. |
| `AttributionBusinessID` | `string` | Attribution | The business/account ID for your attribution provider. Passed to `IAttributionAdapter.Initialize()`. |
| `AttributionResolveLinkUrls` | `List<string>` | Attribution | URLs used by the attribution provider to resolve deep links. Passed to `IAttributionAdapter.Initialize()`. |
| `TelemetryKey` | `string` | Telemetry | API key for the telemetry service. |
| `FacebookAppId` | `string` | Authentication | Facebook App ID, used if implementing Facebook login via `IAuthenticationAdapter`. |

> **Platform selection:** In Android builds and in the Unity Editor, `AndroidConfiguration` is read. In iOS builds, `IosConfiguration` is read. The two blocks are otherwise identical in structure.

### AuthSetting Fields

The `AuthSetting` block is shared across both platforms and is passed to the authentication subsystem during initialization.

| Field | Type | Description |
|---|---|---|
| `ApplicationID` | `string` | The primary authentication application ID. |
| `RaveBaseURL` | `string` | Base URL for the authentication API. |
| `GoogleClientID` | `string` | Google OAuth client ID, used if implementing Google sign-in. |
| `GoogleBackendClientID` | `string` | Backend Google OAuth client ID for server-side token validation. |
| `FacebookApplicationID` | `string` | Facebook App ID for Facebook login. |
| `FacebookClientToken` | `string` | Facebook client token for authentication. |
| `FacebookReadPermissions` | `string` | Comma-separated Facebook permissions requested at login. |
| `AutoGuestLogin` | `string` | Controls automatic guest/anonymous login behavior. |
| `AutoCrossAppLogin` | `bool` | When `true`, enables cross-app login sharing. |
| `LogLevel` | `string` | Logging verbosity for the authentication subsystem. |

### PolicySetting Fields

The `PolicySetting` block configures the Usercentrics consent management platform. These values drive the behavior of `ApplyThirdPartyTrackingConsentStatus()` and ATT consent flows.

| Field | Type | Description |
|---|---|---|
| `SettingId` | `string` | The Usercentrics configuration ID for your title. Identifies which consent template to load. |
| `GeolocationRuleSetId` | `string` | The Usercentrics rule set ID that controls which consent UI is shown based on the user's geographic region (e.g., shows GDPR UI in Europe, CCPA UI in California). |

---

## BfgDebugSettings.asset — Debug Configuration

`BfgDebugSettings.asset` is an optional ScriptableObject of type `DebugSettings`. If the file is absent, the SDK creates a default instance with all flags disabled.

### Creating the Asset

In the Unity Editor: **Assets → Create → BFG → Debug Settings**. Save into any `Resources` folder and name it `BfgDebugSettings`.

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `appsFlyerDebug` | `bool` | `false` | Enables AppsFlyer SDK debug mode. When `true`, the attribution adapter receives `debugMode = true` in its `Initialize()` call, which causes AppsFlyer to log verbose output. Disable before shipping. |
| `usePurchaseDetailDebugUI` | `bool` | `false` | Enables a debug overlay UI for simulating purchasing scenarios (success, unavailable, no products, app not known). For QA use only. Disable before shipping. |

---

## BfgFirebaseSettings.asset — Firebase Configuration

`BfgFirebaseSettings.asset` is an optional ScriptableObject of type `FirebaseSettings`. It is the single
place you configure Firebase for your game. If the file is absent or `enableFirebase` is `false`, the
SDK skips Firebase entirely.

> The Firebase project credential files — `google-services.json` (Android) and `GoogleService-Info.plist`
> (iOS) — are provided per game as files in the project; they are **not** stored in this asset. The
> Firebase Unity SDK + EDM4U must be imported and the `APOLLO_FIREBASE` build define set. See
> `FIREBASE_SETUP.md`.

### Creating the Asset

In the Unity Editor: right-click **Create → BFG/Apollo/Firebase Settings**. Name it
`BfgFirebaseSettings` and keep it in a `Resources` folder — the SDK loads
`Resources/BfgFirebaseSettings` at runtime. (The **BFG → Apollo → Firebase Settings** menu exists
only in the Apollo source project — it is an editor script that is not shipped in the DLL package,
so games consuming the package must use the Create menu.)

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `enableFirebase` | `bool` | `true` | Master switch. When `false`, the Firebase controller is not constructed. |
| `enableAnalytics` | `bool` | `true` | Enables Firebase Analytics. Collection still requires GDPR consent at runtime. |
| `enableCrashlytics` | `bool` | `true` | Enables Crashlytics. Not consent-gated — collection starts at Firebase init. |
| `enableMessaging` | `bool` | `true` | Enables Cloud Messaging (push notifications). |
| `autoSubscribeTopics` | `List<string>` | empty | FCM topics auto-subscribed once Messaging initializes. |
| `requestNotificationPermissionOnStart` | `bool` | `false` | When `true`, Apollo requests OS notification permission during init; otherwise call `RequestNotificationPermission()` yourself. |
| `tokenUploadUrl` | `string` | empty | Push-server URL the SDK POSTs the FCM token to on issue/rotation (`{ token, platform, deviceId }`, deviceId = BFGUDID). Empty = upload disabled. |
| `tokenUploadApiKey` | `string` | empty | Optional `x-api-key` header value for token uploads. Must match the server's key. |
| `verboseDebugLogging` | `bool` | `true` | Emits debug logs for FCM tokens and message payloads for testing. |

---

## ApolloNetworkConfig.json — Network Endpoints

`ApolloNetworkConfig.json` controls where the SDK sends telemetry events. It lives in a `Resources` folder and must be named exactly `ApolloNetworkConfig`.

### Structure

```json
{
    "ConfigItems": [
        {
            "MessageType": 0,
            "UrlRoot": "https://test.mobile.bigfishgames.com/events/",
            "Version": "/2.2.0"
        },
        {
            "MessageType": 1,
            "UrlRoot": "https://test.mobile.bigfishgames.com/events/",
            "Version": "/2.2.0"
        }
    ]
}
```

Each entry in `ConfigItems` maps one event type to an endpoint. The SDK constructs the full request URL as `UrlRoot + eventTypeName + Version`.

### MessageType Values

| Value | Event Type | Triggered By |
|---|---|---|
| `0` | Install | First launch detection (automatic, internal) |
| `1` | SessionStart | App resume/foreground (automatic, internal) |
| `2` | SessionEnd | App pause/background (automatic, internal) |
| `3` | PurchaseSuccess | `BFGUnitySDK.SendPurchasingSuccessEvent()` |
| `4` | CustomEvent | `BFGUnitySDK.SendCustomEvent()` |
| `5` | BFGCustomEvent | Internal BFG events |
| `6` | Error | `BFGUnitySDK.SendPurchasingFailureEvent()` |

### Switching Environments

All entries in the file share the same `UrlRoot` in typical configurations, making an environment switch a matter of updating the URL in every `ConfigItems` entry.

**Test environment** (development and QA):
```
"UrlRoot": "https://test.mobile.bigfishgames.com/events/"
```

**Production environment** (shipping builds):
```
"UrlRoot": "https://mobile.bigfishgames.com/events/"
```

> Maintain separate copies of `ApolloNetworkConfig.json` for test and production, and swap them as part of your build pipeline. Shipping a build pointed at the test endpoint will result in events being silently dropped from production analytics.

---

## Integration Walkthrough

The sections below walk through each piece of the integration in the order you would implement it.

---

### Step 1 — Implement IAuthenticationAdapter

The `IAuthenticationAdapter` is the only adapter required for a minimal integration. It is the bridge between the Apollo SDK's authentication subsystem and whatever authentication backend your game uses.

The adapter is instantiated by the SDK via reflection (using its parameterless constructor), so it must have a public no-argument constructor. If you need to share state with other systems at runtime, expose a static singleton from within `Initialize()`.

```csharp
using BFG.Apollo.Auth;
using UnityEngine;

public class AuthenticationAdapter : IAuthenticationAdapter
{
    private const string USER_ID_KEY       = "Apollo.Auth.UserID";
    private const string IS_AUTH_KEY       = "Apollo.Auth.IsAuthenticated";
    private const string DEFAULT_USER_ID   = "anonymous";

    // Static singleton — lets other MonoBehaviours access auth state directly
    private static AuthenticationAdapter _instance;
    public static AuthenticationAdapter Instance => _instance;

    // IAuthenticationAdapter — properties
    public string ProviderName => "YourAuthProvider";
    public string UserID       => PlayerPrefs.GetString(USER_ID_KEY, DEFAULT_USER_ID);

    // IAuthenticationAdapter — Initialize
    // Called by the SDK during initialization. Store the listener and signal ready.
    public void Initialize(IAuthenticationListener authenticationListener)
    {
        _instance = this;
        authenticationListener.OnAuthenticationInitialized();
    }

    // IAuthenticationAdapter — Start
    // Called after all subsystems have initialized. Use for any deferred startup work.
    public void Start() { }

    // IAuthenticationAdapter — state queries
    public bool IsAuthenticated()         => PlayerPrefs.GetInt(IS_AUTH_KEY, 0) == 1;
    public bool IsAnonymouslyAuthenticated() => false;

    // IAuthenticationAdapter — actions
    // Implement Login/Logout to initiate flows with your actual auth provider.
    // Fire the corresponding IAuthenticationListener callbacks when complete.
    public void Login(IdentityProviderName identityProviderName)  { }
    public void Logout()                                           { }

    // Helpers for updating persisted state from other systems
    public void SetUserID(string id)
    {
        PlayerPrefs.SetString(USER_ID_KEY, id);
    }

    public void SetAuthenticatedState(bool isAuthenticated)
    {
        PlayerPrefs.SetInt(IS_AUTH_KEY, isAuthenticated ? 1 : 0);
    }
}
```

**Key points:**
- Call `authenticationListener.OnAuthenticationInitialized()` inside `Initialize()` to signal to the SDK that auth is ready. If you do not call this, the SDK will not complete its own initialization sequence.
- `UserID` and `IsAuthenticated()` are called by the SDK to populate telemetry event fields. Persisting them to `PlayerPrefs` means they survive app restarts without requiring a new login.
- `Login()` and `Logout()` must fire the corresponding `IAuthenticationListener` callbacks when their operations complete, even if the implementation is a stub.

---

### Step 2 — Implement IAuthenticationListener

The `IAuthenticationListener` receives callbacks from the authentication subsystem. Implement it to drive your game's UI in response to auth state changes.

```csharp
using BFG.Apollo.Auth;
using UnityEngine;

public class AuthenticationListener : IAuthenticationListener
{
    public void OnAuthenticationInitialized()
    {
        // Auth subsystem is ready. Safe to check IsAuthenticated() from here.
        Debug.Log("[Auth] Initialization successful.");
    }

    public void OnAuthenticationInitializeFailed(string failureReason)
    {
        Debug.LogError($"[Auth] Initialization failed: {failureReason}");
    }

    public void OnLoginSuccess()
    {
        Debug.Log("[Auth] Login successful.");
        // Update game state, unlock features, etc.
    }

    public void OnLoginFailed(string failureReason)
    {
        Debug.LogWarning($"[Auth] Login failed: {failureReason}");
        // Show error UI.
    }

    public void OnLogoutSuccess()
    {
        Debug.Log("[Auth] Logout successful.");
    }

    public void OnLogoutFailed(string failureReason)
    {
        Debug.LogWarning($"[Auth] Logout failed: {failureReason}");
    }
}
```

---

### Step 3 — Implement ITelemetryListener

The `ITelemetryListener` is called after each telemetry event dispatch attempt. At minimum, log the result. In production you may want to surface persistent failures.

```csharp
using BFG.Apollo.Telemetry;
using UnityEngine;

public class TelemetryListener : ITelemetryListener
{
    public void OnTelemetrySent(bool success, string message)
    {
        if (success)
            Debug.Log($"[Telemetry] Event sent: {message}");
        else
            Debug.LogWarning($"[Telemetry] Event failed: {message}");
    }
}
```

---

### Step 4 — Register, Initialize, and Supply the Attribution ID

Call this from a `MonoBehaviour.Start()` (or `Awake()`) that is guaranteed to run before any other game system sends telemetry. Attach it to a GameObject that is present in your very first scene.

```csharp
using UnityEngine;

public class SDKInitializer : MonoBehaviour
{
    // Replace with the device ID from your attribution provider (e.g. AppsFlyer UID).
    // Typically obtained asynchronously — see note below.
    private const string ATTRIBUTION_ID = "your-attribution-id-here";

    private void Start()
    {
        // 1. Register adapters — must implement IAdapter
        BFGUnitySDK.RegisterAdapter<AuthenticationAdapter>();

        // 2. Register listeners — must implement IListener
        BFGUnitySDK.RegisterListener<AuthenticationListener>();
        BFGUnitySDK.RegisterListener<TelemetryListener>();

        // 3. Initialize — wires everything together and starts the SDK
        BFGUnitySDK.Initialize();

        // 4. Supply the attribution ID
        //    This value is stamped on all subsequent GTS events as 'afid'.
        //    Set it as soon as your attribution adapter has obtained the ID.
        BFGUnitySDK.SetAttributionID(ATTRIBUTION_ID);
    }
}
```

**Registration rules:**
- All `RegisterAdapter<T>()` and `RegisterListener<T>()` calls must occur **before** `Initialize()`. The SDK reads registrations at initialization time and throws `InvalidOperationException` if a type does not match any known adapter or listener interface.
- Calling `Initialize()` more than once in the same session logs a warning and returns without re-initializing.
- An `IAuthenticationListener` registration is required. If one is not registered, the SDK logs an error during initialization.

**Authentication is required.** The SDK expects an `IAuthenticationAdapter` and `IAuthenticationListener` to be registered. Auth state (`UserID`, `IsAuthenticated`) is used to populate fields in every telemetry event.

---

## Feature Guide

---

### Custom Telemetry Events

Custom events let you report game-specific actions to the GTS telemetry service. Each event carries a name and a typed payload that you define.

**Define your payload** by subclassing `CustomEventData`:

```csharp
using BFG.Apollo.Telemetry.DataObjects.CustomEvent;

// Define a custom event payload
public class LevelCompleteEvent : CustomEventData
{
    public int    LevelNumber;
    public float  CompletionTimeSeconds;
    public int    Score;
    public bool   UsedPowerup;
}
```

`CustomEventData` provides a single inherited field, `eventName`. You can set it on the instance or rely entirely on the `eventName` parameter passed to `SendCustomEvent`.

**Send the event:**

```csharp
var evt = new LevelCompleteEvent
{
    eventName             = "level_complete",   // also passed as first arg below
    LevelNumber           = 5,
    CompletionTimeSeconds = 142.3f,
    Score                 = 87400,
    UsedPowerup           = false
};

BFGUnitySDK.SendCustomEvent(evt.eventName, evt);
```

**What gets sent:** The SDK wraps your payload in a GTS event envelope that includes device info, session IDs, auth state, timestamps, and the attribution ID. Your `CustomEventData` subclass fields are serialized as the `EventData` object within that envelope.

**Timing:** `SendCustomEvent` must be called after `Initialize()` has fully completed. The SDK guards against this — calls made before `_isStarted` is true log a warning and are dropped. If you need to send an event immediately at startup, use `BFGUnitySDK.OnInitializationComplete()`:

```csharp
BFGUnitySDK.Initialize();

BFGUnitySDK.OnInitializationComplete(() =>
{
    BFGUnitySDK.SendCustomEvent("sdk_ready", new MyStartupEvent());
});
```

---

### App User ID

The App User ID is a game-defined identifier that is attached to all telemetry events. It is distinct from the authentication `UserID` — it represents the player's identity within your game (e.g., a player account ID from your game server), whereas `UserID` comes from an identity provider.

**At first launch**, the SDK assigns the App User ID a random GUID automatically. You can replace it:

```csharp
// Set after the player logs in to your game backend
BFGUnitySDK.SetAppUserId(gameServer.CurrentPlayer.AccountId);
```

**Retrieve the current value** (e.g., to display it in a debug panel):

```csharp
string currentId = BFGUnitySDK.GetAppUserId();
```

The value is persisted in `PlayerPrefs` under the key `BFG.Apollo.Telemetry.AppUserId` and survives app restarts. Set it as soon as your game backend has authenticated the player and issued an account ID.

---

### Purchase Telemetry

The Apollo SDK does not manage the purchase flow itself — your existing purchasing library (e.g., Unity IAP) continues to do that. Apollo's role is to report the outcome of purchases as GTS telemetry events. Call `SendPurchasingSuccessEvent` or `SendPurchasingFailureEvent` from within your purchasing library's callbacks.

#### Reporting a Successful Purchase

```csharp
using BFG.Apollo.Purchasing;
using System.Globalization;
using System;

// Call this when your purchasing library confirms a completed transaction
private void OnPurchaseCompleted(YourOrderType order, YourCartItemType item)
{
    BFGUnitySDK.SendPurchasingSuccessEvent(new PurchaseSuccessData
    {
        productId            = item.Product.definition.storeSpecificId,
        transactionID        = order.Info.TransactionID,
        transactionTimestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        price                = item.Product.metadata.localizedPrice
                                   .ToString(CultureInfo.InvariantCulture),
        currency             = item.Product.metadata.isoCurrencyCode,
        receipt              = order.Info.Receipt,
        uniqueReceiptID      = order.Info.Receipt.GetHashCode().ToString(),
        restore              = false,
        signature            = null,   // Android only; null on iOS
        description          = item.Product.metadata.localizedDescription
    });
}
```

#### Reporting a Restored Purchase

Restored purchases use the same method but set `restore = true`. Use `localizedPriceString` instead of computing the decimal value, and pass `0` for the timestamp if the original transaction date is unavailable:

```csharp
BFGUnitySDK.SendPurchasingSuccessEvent(new PurchaseSuccessData
{
    productId            = item.Product.definition.storeSpecificId,
    transactionID        = confirmedOrder.Info.TransactionID,
    transactionTimestamp = 0,
    price                = item.Product.metadata.localizedPriceString,
    currency             = item.Product.metadata.isoCurrencyCode,
    receipt              = confirmedOrder.Info.Receipt,
    uniqueReceiptID      = null,
    restore              = true,
    signature            = null,
    description          = item.Product.metadata.localizedDescription
});
```

#### Reporting a Failed Purchase

```csharp
using BFG.Apollo.Purchasing;

private void OnPurchaseFailed(YourFailedOrderType order, YourCartItemType item)
{
    BFGUnitySDK.SendPurchasingFailureEvent(new PurchaseFailureData
    {
        productId     = item.Product.definition.storeSpecificId,
        errorCode     = (int)order.FailureReason,
        errorMessage  = order.Details,
        errorReason   = (PurchaseErrorReason)(int)order.FailureReason,
        purchasePhase = PurchasePhase.Unknown   // use Unknown if your library
                                                // doesn't distinguish phases
    });
}
```

**`purchasePhase`** identifies where in the purchase pipeline the failure happened. If you are reporting failures directly from Unity IAP callbacks (which don't map to the Apollo phases), use `PurchasePhase.Unknown`. If your server-side verification flow raises a failure, use the appropriate phase (`ClientVerificationPhase` or `ServerVerificationPhase`) to improve diagnostic precision.

---

### Consent: App Tracking Transparency (iOS)

On iOS 14.5 and later, apps must request permission before accessing the IDFA (Identifier for Advertisers). The ATT prompt is displayed by native iOS code; your Unity layer receives the result via a callback and must forward it to the Apollo SDK so the telemetry system can set the correct IDFA behavior.

**The ATT native bridge is the game's responsibility** — Apollo does not ship one; it only consumes
the result via `BFGUnitySDK.ApplyAttConsentStatus()`. For a working reference implementation see
Galaxy Gems: `Assets/Plugins/iOS/ATT/AppTrackingTransparency.mm` (native prompt +
`UnitySendMessage` callback) paired with `Assets/Scripts/Prototype/ATTManager.cs`.

**Call `ApplyAttConsentStatus` as soon as you receive the native result:**

```csharp
using BFG.Apollo.Policy;

// Called by your native iOS bridge when the ATT prompt resolves
private void OnTrackingAuthorizationCompleted(string statusCode)
{
    if (int.TryParse(statusCode, out int value))
    {
        ATTStatus status = (ATTStatus)value;
        BFGUnitySDK.ApplyAttConsentStatus(status);
    }
}
```

**What this does:** The SDK writes the status to `PlayerPrefs` under the key `BFG.Apollo.Policy.ATT`. The telemetry system reads this value when building GTS events to decide whether to include the IDFA in the payload.

**`ATTStatus` values** (map 1:1 to iOS `ATTrackingManager.AuthorizationStatus`):

| Status | Meaning |
|---|---|
| `NotDetermined` (0) | Prompt not yet shown |
| `Restricted` (1) | Blocked by device policy |
| `Denied` (2) | User refused |
| `Authorized` (3) | User accepted; IDFA is readable |

**Timing:** Show the ATT prompt after any GDPR/consent UI you display, since Apple's guidelines require that users understand why tracking is needed before being prompted. A typical sequence is: GDPR consent → ATT prompt → SDK initialization (or initialize first and call `ApplyAttConsentStatus` when the result arrives).

> This method is iOS-specific. On Android it is a no-op.

---

### Consent: Third-Party Tracking (GDPR)

`ApplyThirdPartyTrackingConsentStatus` records whether the user has consented to third-party data sharing. This value is included in every outbound GTS telemetry event as the `tpte` (third-party tracking enabled) field.

**Call it when your consent UI resolves:**

```csharp
// Called when the GDPR/consent dialog is accepted or declined
private void OnConsentDialogDismissed(bool userAccepted)
{
    BFGUnitySDK.ApplyThirdPartyTrackingConsentStatus(userAccepted);
}
```

**What this does:** The SDK writes the value (`1` or `0`) to `PlayerPrefs` under the key `BFG.Apollo.Telemetry.ThirdPartyTrackingStatus`. The telemetry system reads this key when building GTS events.

**Default behavior:** The parameter defaults to `true`, so calling `ApplyThirdPartyTrackingConsentStatus()` with no argument records consent as granted. Always pass the actual user decision explicitly.

**When to call it:** Call this every time the user's consent status changes — on first run after the consent UI, and any time the user modifies their consent settings from your privacy menu. The `PlayerPrefs` value persists across sessions, so you only need to call it when the state actually changes.

---

### Firebase (Analytics, Crashlytics, Messaging)

Apollo owns the Firebase integration: enable features in `BfgFirebaseSettings.asset`, optionally register
a messaging listener, then call the simple APIs. No Firebase glue code is required in your game.

> **In-App Messaging** is not included — the Firebase Unity SDK does not support it (Android/iOS/Flutter
> only).

**1. Configure** — create `BfgFirebaseSettings.asset` (right-click **Create → BFG/Apollo/Firebase Settings**, in a `Resources` folder) and toggle the
features you want. Complete the one-time package import in `FIREBASE_SETUP.md`.

**2. (Optional) Register a listener before `Initialize()`** for push callbacks:

```csharp
public class MyFirebaseMessagingListener : IFirebaseMessagingListener
{
    public void OnFcmTokenReceived(string token) { Debug.Log($"FCM token: {token}"); }
    public void OnMessageReceived(FirebaseRemoteMessage message) { /* foreground message */ }
    public void OnMessageOpened(FirebaseRemoteMessage message) { /* user tapped notification */ }
}

// before BFGUnitySDK.Initialize():
BFGUnitySDK.RegisterListener<MyFirebaseMessagingListener>();
```

**3. Grant consent after your GDPR flow** — nothing is collected until you call this:

```csharp
private void OnConsentDialogDismissed(bool userAccepted)
{
    // Gates Analytics only (Crashlytics is always on). Persisted across sessions.
    BFGUnitySDK.SetFirebaseDataCollectionConsent(userAccepted);
}
```

**4. Use the APIs:**

```csharp
// Analytics (dropped + logged until consent is granted)
BFGUnitySDK.LogFirebaseEvent("level_complete", new Dictionary<string, object> { { "level", 7L } });

// Crashlytics
BFGUnitySDK.LogCrashlyticsMessage("Entered shop");
BFGUnitySDK.RecordCrashlyticsException(new Exception("handled"));

// Cloud Messaging
BFGUnitySDK.GetFcmToken(token => Debug.Log(token));
BFGUnitySDK.SubscribeToFcmTopic("promotions");
BFGUnitySDK.RequestNotificationPermission();   // Android 13+ POST_NOTIFICATIONS, iOS APNs prompt
```

**Notes:**
- **iOS: the notification-permission prompt is shown only when you call
  `RequestNotificationPermission()`** (or set `requestNotificationPermissionOnStart`). Call it at the
  point in your consent flow where the prompt should appear (e.g. after GDPR/ATT — keep
  `requestNotificationPermissionOnStart` off if you have a consent flow). Until that first call on a
  given install, **every Cloud Messaging API is inert** (`GetFcmToken` returns `null`; topic and
  token APIs no-op) — on iOS the first touch of the FirebaseMessaging API would otherwise show the
  OS prompt immediately. On later launches the FCM listeners attach automatically at init.
  `autoSubscribeTopics` is applied when messaging becomes active, so it works with this gate.
- **iOS builds need APNs/Xcode configuration Unity does not produce** — an APNs Auth Key uploaded to
  the Firebase project, the push entitlement, the `remote-notification` background mode, and
  `UNITY_USES_REMOTE_NOTIFICATIONS=1` in the exported `Preprocessor.h`. Without the last one,
  data-only pushes are silently dropped before reaching C#. See the iOS section of
  `FIREBASE_SETUP.md` and the reference post-process script
  `GalaxyGems/Assets/Scripts/Editor/iOSPostProcessBuild.cs`.
- **Android: `RequestNotificationPermission()` shows the Android 13+ `POST_NOTIFICATIONS` runtime
  prompt** (a logged no-op below API 33, where the permission is granted by default). It requires
  `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` in the game's
  `Assets/Plugins/Android/AndroidManifest.xml` — neither Unity nor the Firebase SDK adds it. Call it
  after your consent flow (Galaxy Gems: from `GDPRManager` right after the GDPR decision). Unlike
  iOS there is no messaging gate on Android — the FCM listeners attach at SDK init, so the token
  (and its automatic upload) and foreground `OnMessageReceived` work regardless of the permission;
  it only controls whether notifications display.
- **Android notification opens need no game code, but do need the Firebase launcher activity.**
  Apollo delivers `OnMessageOpened` for cold-start launches (reads the launch intent at init) and
  warm background taps (filled from the tap intent), de-duplicated by message id. On Android the
  opened message carries metadata + the custom `data` payload only — FCM strips the notification
  title/body from the tap intent by design (they are null on tap; iOS populates them). Put
  open-relevant values in `data`.
  The game's launcher activity must be Firebase's `com.google.firebase.MessagingUnityPlayerActivity`
  (Application Entry Point = Activity) — see the Android section of `FIREBASE_SETUP.md` and the
  reference files in `GalaxyGems/Assets/Plugins/Android/`.
- Apollo sets the Crashlytics user id to the App User ID automatically for correlation.
- The FCM token is uploaded automatically to `tokenUploadUrl` (when set) on every issue/rotation,
  keyed by the SDK's stable device id (BFGUDID) + platform; games do not write upload code. On iOS
  the first upload happens after the game calls `RequestNotificationPermission()` (deferred FCM
  listeners); on later launches it re-fires at init. On a fresh iOS install the upload fires
  **twice** (the pre-APNs token is rotated once the APNs token is set) — expected; the server's
  deviceId+platform upsert keeps only the latest.
- Firebase makes **no changes to GTS telemetry** — the two pipelines are independent.

---

## What Happens Inside Initialize()

Understanding the internal initialization sequence helps diagnose setup problems. When `BFGUnitySDK.Initialize()` is called, the following happens in order:

1. **Guard check** — if already initialized, logs a warning and returns.
2. **BootstrapFactory.Init()** — loads `BfgSettings.asset` from `Resources`, maps it to a `ConfigData` object (selecting the correct platform block), and loads `BfgDebugSettings.asset`.
3. **Component construction** — creates internal components:
   - `Logging`
   - `Encoding` (JSON serialization)
   - `NetworkingController` — loads `ApolloNetworkConfig.json` from `Resources` to build the endpoint map
   - `AttributionController` — only constructed if an `IAttributionAdapter` was registered
   - `TelemetryController` — always constructed; receives a reference to `AttributionController` (may be null)
   - `PurchasingController` — only constructed if an `IPurchaseListener` was registered
   - `AuthenticationController` — only constructed if an `IAuthenticationListener` was registered
   - `FirebaseController` — only constructed if `BfgFirebaseSettings.asset` exists with `enableFirebase = true`; initializes Firebase asynchronously and treats init failure as non-fatal
4. **Component initialization** — each component is initialized in the order it was constructed. Each signals completion asynchronously via `ComponentInitializationComplete()`.
5. **All-complete check** — once every component has reported success (or `ServiceUnused`), `_isInitialized` is set to `true`.
   - If an `IInitializationListener` was registered, `InitializationComplete()` is called on it.
6. **StartSDK()** — calls `Start()` on all components. At this point the SDK is fully operational.
   - The `TelemetryController` auto-generates a random App User ID GUID if none was previously set.
   - Any callbacks registered via `BFGUnitySDK.OnInitializationComplete()` are fired.

**Authentication is not optional.** If an `IAuthenticationListener` is registered but no `IAuthenticationAdapter` is registered, the `AuthenticationController` will fail to initialize. If neither is registered, the SDK logs `"Authentication Required."` and initialization fails. The minimum viable integration must register both.

---

## Common Pitfalls

**Calling `SendCustomEvent` before initialization completes**
The SDK drops events and logs a warning if called before `_isStarted` is `true`. Wrap startup events in the `OnInitializationComplete` callback if you need to send them immediately.

**Forgetting to call `ApplyAttConsentStatus` before telemetry events are sent**
The IDFA consent status is read at event-build time. If you present the ATT prompt asynchronously and telemetry events fire before the result arrives, those events will include the IDFA based on the last-stored `PlayerPrefs` value (which defaults to `NotDetermined` / `0` on a fresh install). Call `ApplyAttConsentStatus` as soon as the OS delivers the result.

**Pointing production builds at the test endpoint**
The `ApolloNetworkConfig.json` file controls where events are delivered. Test and production use different `UrlRoot` values. Ensure your build pipeline substitutes the production config before shipping.

**Registering after `Initialize()`**
Adapter and listener registrations are read once during `Initialize()`. Any call to `RegisterAdapter` or `RegisterListener` after `Initialize()` has been called has no effect on the current session.

**Registering an unrecognized type**
`RegisterAdapter<T>()` and `RegisterListener<T>()` throw `InvalidOperationException` at registration time if `T` does not implement one of the recognized adapter or listener interfaces. Ensure your class explicitly implements the correct interface.

**Not persisting `UserID` across restarts**
The SDK reads `UserID` from your `IAuthenticationAdapter.UserID` property on every event. If your implementation returns an in-memory value that is not persisted (e.g., a field that starts empty on each launch), events after a restart will have no auth user ID. Persist the value to `PlayerPrefs` or Keychain in `SetUserID()` and read it back in the `UserID` getter.

**Setting the attribution ID too late**
`SetAttributionID` stores the value in `PlayerPrefs`. Any GTS event dispatched before `SetAttributionID` is called carries an empty `afid` field. Set the attribution ID as the first action after `Initialize()`, or inside an `OnInitializationComplete` callback, before any other telemetry calls.
