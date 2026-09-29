# Unity (Apollo) SDK Integration Guide

This document is a companion to the [API Reference](../Apollo_Documentation.md). While the API Reference describes what each type and method does, this guide walks through *how* to integrate the SDK from scratch — covering configuration, setup, and each feature in context.

**Platform:** Unity (iOS & Android)

---

## Table of Contents

1. [How the SDK Works](#how-the-sdk-works)
2. [Required Files](#required-files)
   - [BfgSettings.asset — Game Configuration](#bfgsettingsasset--game-configuration)
   - [BfgFirebaseSettings.asset — Firebase Configuration](#bfgfirebasesettingsasset--firebase-configuration)
   - [BfgConsent.asset — Consent Environment](#bfgconsentasset--consent-environment)
   - [ApolloNetworkConfig.json — Network Endpoints](#apollonetworkconfigjson--network-endpoints)
   - [ApolloConsentConfig.json — Policy Service URL](#apolloconsentconfigjson--policy-service-url)
3. [Integration Walkthrough](#integration-walkthrough)
   - [Step 1 — Implement IAuthenticationAdapter](#step-1--implement-iauthenticationadapter)
   - [Step 2 — Implement IAuthenticationListener](#step-2--implement-iauthenticationlistener)
   - [Step 3 — Implement ITelemetryListener](#step-3--implement-itelemetrylistener)
   - [Step 4 — Register, Initialize, and Supply the Attribution ID](#step-4--register-initialize-and-supply-the-attribution-id)
4. [Feature Guide](#feature-guide)
   - [Game Telemetry Service (GTS)](#game-telemetry-service-gts)
   - [Consent (GDPR + ATT)](#consent-gdpr--att)
   - [Firebase (Analytics, Crashlytics, Messaging)](#firebase-analytics-crashlytics-messaging)
5. [What Happens Inside Initialize()](#what-happens-inside-initialize)
6. [Common Pitfalls](#common-pitfalls)

---

## How the SDK Works

The Unity (Apollo) SDK follows an **adapter/listener pattern**. Before calling `Initialize()`, your game registers:

- **Adapters** — classes you implement that connect third-party services (e.g., authentication providers) to the Unity (Apollo) SDK. The SDK calls into your adapter.
- **Listeners** — classes you implement to receive callbacks when the SDK reports events (login success, telemetry sent, etc.).

At initialization the SDK reads its configuration asset from the `Resources` folder, then constructs and starts its internal subsystems in a fixed order. Telemetry events are queued and flushed to a configurable network endpoint defined in a JSON file also in `Resources`.

The minimum integration requires:

1. One adapter: `IAuthenticationAdapter`
2. Two listeners: `IAuthenticationListener`, `ITelemetryListener`
3. Two configuration files: `BfgSettings.asset`, `ApolloNetworkConfig.json`

Two optional subsystems add listeners of their own, registered at the same point in startup if
your game uses them: **Firebase** (an `IFirebaseMessagingListener` for push callbacks) and the
**built-in consent dialog** (an `IPolicyListener` via `AddPolicyListener`). They appear marked
*optional* throughout this guide.

---

## Required Files

> **Create them all in one step:** the package ships an editor menu, **BFG → Apollo → Create
> Missing Settings Files**, that creates every file in the table below that your project doesn't
> already have. Assets are created with their default field values (fill them in via the
> Inspector); the JSON files are created from templates pointing at the **production** endpoints
> (switch to the test URLs during development — see the per-file sections below). Files that
> already exist in *any* `Resources` folder are detected (via the same `Resources.Load()` lookup
> the SDK uses) and left untouched; new files land in `Assets/Resources/`.

The SDK loads these files automatically during `Initialize()`. Each must live in a Unity `Resources` folder.

| File | Type | Required | Purpose |
|---|---|---|---|
| `BfgSettings.asset` | `GameInfos` ScriptableObject | **Yes** | Store IDs and telemetry key per platform ([details](#bfgsettingsasset--game-configuration)) |
| `BfgFirebaseSettings.asset` | `FirebaseSettings` ScriptableObject | For Firebase | Firebase master/feature switches, FCM options ([details](#bfgfirebasesettingsasset--firebase-configuration)). Absent = Firebase skipped |
| `BfgConsent.asset` | `ConsentSettings` ScriptableObject | Recommended | Environment reported on consent tracking events ([details](#bfgconsentasset--consent-environment)). Absent = defaults to `Prod` |
| `ApolloNetworkConfig.json` | JSON TextAsset | **Yes** | Telemetry endpoint routing ([details](#apollonetworkconfigjson--network-endpoints)) |
| `ApolloConsentConfig.json` | JSON TextAsset | For the built-in consent dialog | Policy-service URL root ([details](#apolloconsentconfigjson--policy-service-url)). Absent = the consent system silently disables itself |

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

The SDK's stable device id (`bfgudid`, used by GTS telemetry and FCM token uploads) is derived
**exactly like the legacy Big Fish SDKs**, so Apollo and a legacy-SDK game produce the same value
on the same device: on iOS `SHA1(IDFV)` (the raw uppercase, hyphenated UUID string — no salt), on
Android `SHA1(ANDROID_ID + "BFGUDID")`. On iOS it is therefore identical for every app from the
same App Store vendor on a device and survives reinstalls while at least one vendor app is
installed. The iOS Keychain (item `com.apollo.sdk.bfgudid.v2`, service `com.bfg.apollo`) covers
the remaining case — the user removing every vendor app.

> **Upgrade note:** earlier Apollo builds used a different derivation
> (`SHA1(deviceId + "BFGUDID")` over a pre-hashed Android id / salted IDFV). Those values are
> **abandoned, not migrated**: the SDK stores the id under new key names (Keychain
> `com.apollo.sdk.bfgudid.v2`, PlayerPrefs `BFGUDID.v2`) and never reads the old entries, so an
> upgrading install generates a fresh legacy-matching id on first launch.

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

### BfgSettings.asset — Game Configuration

`BfgSettings.asset` is a Unity ScriptableObject of type `GameInfos`. It is the primary configuration asset for the SDK and contains separate configuration blocks for iOS and Android. At runtime, the SDK automatically selects the correct platform block (the Android block is also used in the Unity Editor).

#### Creating the Asset

Use **BFG → Apollo → Create Missing Settings Files** — it creates the asset (along with any other missing Apollo settings files) in `Assets/Resources/` with empty defaults; fill in the fields below via the Inspector. The asset must live in a `Resources` folder and be named exactly `BfgSettings`.

#### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `IosConfiguration` | `GameConfiguration` | Platform-specific settings for iOS builds. |
| `AndroidConfiguration` | `GameConfiguration` | Platform-specific settings for Android builds and the Unity Editor. |

#### GameConfiguration Fields (IosConfiguration / AndroidConfiguration)

These fields are filled in twice — once for each platform block.

| Field | Type | Used By | Description |
|---|---|---|---|
| `GameStoreId` | `string` | Telemetry (`apsid` field on every GTS event) | The App Store ID (iOS) or Play Store package name (Android), e.g. `com.bigfishgames.yourgame.google`. |
| `GameCenterId` | `string` | Telemetry (`ios.gcid` field, iOS only) | The Game Center identifier for the title. The field also appears in the Android block (both blocks share the `GameConfiguration` class), but the Android value is ignored. |
| `TelemetryKey` | `string` | Telemetry (`x-api-key` header on every POST) | The GTS API key for your game. Empty = no header sent. Check with your producer for this value. |

> **Platform selection:** In Android builds and in the Unity Editor, `AndroidConfiguration` is read. In iOS builds, `IosConfiguration` is read. The two blocks are otherwise identical in structure.

Notes:

- The telemetry endpoint URL and version do **not** live here — they come from
  `ApolloNetworkConfig.json` ([details](#apollonetworkconfigjson--network-endpoints)).
- If your project has a pre-cleanup asset with extra keys (`FacebookAppId`, `AuthApplicationId`,
  `SdkList`, …), those keys are ignored — re-save the asset in the Inspector to drop them.
  `BfgDebugSettings.asset` no longer exists; delete it if your project has one.

GTS telemetry integration steps live in [`GTS_INTEGRATION_GUIDE.md`](GTS_INTEGRATION_GUIDE.md) (this folder).

### BfgFirebaseSettings.asset — Firebase Configuration

`BfgFirebaseSettings.asset` is an optional ScriptableObject of type `FirebaseSettings` — the
single place Firebase is configured for your game (master/per-feature switches, FCM
auto-subscribe topics, push-server token upload). If the file is absent or `enableFirebase` is
`false`, the SDK skips Firebase entirely. Create it via **BFG → Apollo → Create Missing Settings
Files**. (The Firebase *credentials* — `google-services.json` / `GoogleService-Info.plist` — are
per-game project files, not stored here.)

#### Fields — standard configuration (features + visible push notifications)

| Field | Type | Default | Description |
|---|---|---|---|
| `enableFirebase` | `bool` | `true` | Master switch. `false` (or asset absent) = the Firebase controller is never constructed; the whole subsystem is skipped. |
| `enableAnalytics` | `bool` | `true` | Enables Firebase Analytics. Collection additionally requires GDPR consent at runtime. `false` = Analytics APIs are silent no-ops and the consent value is not applied to Firebase. |
| `enableCrashlytics` | `bool` | `true` | Enables Crashlytics. Deliberately **not** consent-gated — collection starts at Firebase init. `false` = Crashlytics APIs are silent no-ops. |
| `enableMessaging` | `bool` | `true` | Enables Cloud Messaging (push). `false` = no FCM listeners attached, no token handling, all messaging APIs no-op (callbacks get null/false). |
| `autoSubscribeTopics` | `List<string>` | empty | FCM topics the SDK auto-subscribes the device to once messaging attaches (on iOS fresh installs that happens at the notification-permission call, not at init). |
| `requestNotificationPermissionOnStart` | `bool` | `false` | `true` = Apollo requests the OS notification permission itself during Firebase init. Keep `false` for any game with a consent flow so prompt timing stays under game control — call `BFGUnitySDK.RequestNotificationPermission()` yourself at the right moment. |
| `verboseDebugLogging` | `bool` | `true` | Verbose `[Apollo.Firebase]` debug logs (FCM tokens, full message payloads, Analytics events, consent changes) to aid testing. |

#### Fields — data-only pushes (optional)

These two keys apply only to **data-only (background) pushes** — server-sent messages with no
visible notification, delivered silently to the game. Data-only pushes are an optional feature:
if your game doesn't use them, leave both fields empty (the defaults).

| Field | Type | Default | Description |
|---|---|---|---|
| `tokenUploadUrl` | `string` | empty | Your push server's token endpoint. The SDK POSTs `{ token, platform, deviceId }` there on every FCM token issue/rotation. Empty = uploading disabled. |
| `tokenUploadApiKey` | `string` | empty | Optional `x-api-key` header value sent with token uploads. Empty = no header. |

Setup steps (Firebase Unity SDK package import, portal prerequisites, per-platform build steps)
live in [`FIREBASE_INTEGRATION_GUIDE.md`](FIREBASE_INTEGRATION_GUIDE.md) (this folder).

### BfgConsent.asset — Consent Environment

`BfgConsent.asset` is an optional ScriptableObject of type `ConsentSettings` — the home for
game-set consent toggles. Create it via **BFG → Apollo → Create Missing Settings Files**.

| Field | Type | Description |
|---|---|---|
| `environment` | `ApolloEnvironment` (`Test` / `Prod`) | Reported on every consent tracking event (shown/accepted/declined) sent to the compliance backend. Use `Test` during development and **set it to `Prod` before shipping**. |

If the asset is missing, Apollo defaults to `Prod` so an unconfigured build never mislabels real
events as test data. Note this field only affects consent *tracking* events — the policy-service
and telemetry endpoints are chosen by `ApolloConsentConfig.json` and `ApolloNetworkConfig.json`
respectively.

Consent integration steps live in [`CONSENT_INTEGRATION_GUIDE.md`](CONSENT_INTEGRATION_GUIDE.md) (this folder).

### ApolloNetworkConfig.json — Network Endpoints

`ApolloNetworkConfig.json` controls where the SDK sends telemetry events. It lives in a `Resources` folder and must be named exactly `ApolloNetworkConfig`. **BFG → Apollo → Create Missing Settings Files** creates a complete template (all seven routing entries below, pointed at the production endpoints).

#### Structure

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
        },
        ...
    ]
}
```

Each entry in `ConfigItems` maps one event type to an endpoint:

| Key | Type | Default | Description |
|---|---|---|---|
| `MessageType` | `int` | — | The event type this entry routes (values below). |
| `UrlRoot` | `string` | — | Base URL for the endpoint. This is also where environments are switched (see below). |
| `Version` | `string` | — | Version path suffix appended to the URL (e.g. `/2.2.0`). |
| `AppendProductVersionSuffix` | `bool` | `true` | When `true`, the full request URL is `{UrlRoot}{eventType}/{productName}{Version}` (where `{eventType}` is the GTS event-type string, e.g. `sessionStart`, and `{productName}` is Unity's `Application.productName` — renaming the product changes the endpoint path). When `false`, the URL is just `{UrlRoot}{eventType}` — used by the consent-reporting entry (`MessageType` `8`). |

An event whose `MessageType` has **no entry** in this file is never sent — the SDK logs
`network message type does not have a target URL` and the message fails after exhausting its
retry budget.

#### MessageType Values

| Value | Event Type | Triggered By |
|---|---|---|
| `0` | Install | First launch detection (automatic, internal) |
| `1` | SessionStart | App resume/foreground (automatic, internal) |
| `2` | SessionEnd | App pause/background (automatic, internal) |
| `3` | PurchaseSuccess | `BFGUnitySDK.SendPurchasingSuccessEvent()` |
| `4` | CustomEvent | `BFGUnitySDK.SendCustomEvent()` |
| `6` | Error | `BFGUnitySDK.SendPurchasingFailureEvent()` |
| `8` | PolicyEvent | Consent shown/accepted/declined tracking from the built-in policy dialog (automatic, internal) |

> `MessageType` value `5` (`BFGCustomEvent`) still exists in the enum but nothing dispatches it — the config file needs no entry for it. Value `7` (`InternetConnectionCheck`) likewise needs no entry.

#### Switching Environments

All telemetry entries in the file share the same `UrlRoot` in typical configurations, making an environment switch a matter of updating the URL in every `ConfigItems` entry. (The consent-reporting entry, `MessageType` `8`, points at the policy service rather than the events endpoint and has its own test/production URL roots.)

**Test environment** (development and QA):
```
"UrlRoot": "https://test.mobile.bigfishgames.com/events/"
```

> ⚠️ The test environment is currently not available — please use production for now.

**Production environment** (shipping builds):
```
"UrlRoot": "https://mobile.bigfishgames.com/events/"
```

> Maintain separate copies of `ApolloNetworkConfig.json` for test and production, and swap them as part of your build pipeline. Shipping a build pointed at the test endpoint will result in events being silently dropped from production analytics.

### ApolloConsentConfig.json — Policy Service URL

`ApolloConsentConfig.json` gives the SDK the policy-service URL root used by the built-in
GDPR/consent dialog (policy fetch and consent-dialog content). It lives in a `Resources` folder
and must be named exactly `ApolloConsentConfig`. **This file is the on/off switch for the entire
consent system: without it (or with invalid JSON) the consent subsystem silently disables
itself**, emitting only a log warning. **BFG → Apollo → Create Missing Settings Files** creates
it with the production URL.

#### Structure

```json
{
    "PolicyServiceUrlRoot": "https://policy.bigfishgames.com"
}
```

| Key | Type | Description |
|---|---|---|
| `PolicyServiceUrlRoot` | `string` | Root URL of the Big Fish policy service — used for the policy check at init/foreground and for fetching the consent dialog's server-driven content. |

| Environment | URL | Notes |
|---|---|---|
| Production | `https://policy.bigfishgames.com` | |
| Test | `https://test.policy.bigfishgames.com` | ⚠️ The test environment is currently not available — please use production for now. |

Make sure your build pipeline ships the production URL. (Consent-*reporting* traffic is routed
separately, via the `MessageType` `8` entry in `ApolloNetworkConfig.json`.)

Consent integration steps live in [`CONSENT_INTEGRATION_GUIDE.md`](CONSENT_INTEGRATION_GUIDE.md) (this folder).

---

## Integration Walkthrough

The sections below walk through each piece of the integration in the order you would implement it.
Steps 1–3 implement the required adapter and listeners; games using Firebase or the built-in
consent dialog also implement an `IFirebaseMessagingListener` / `IPolicyListener` (optional — see
[`FIREBASE_INTEGRATION_GUIDE.md`](FIREBASE_INTEGRATION_GUIDE.md) and
[`CONSENT_INTEGRATION_GUIDE.md`](CONSENT_INTEGRATION_GUIDE.md)) and register them in Step 4.

---

### Step 1 — Implement IAuthenticationAdapter

The `IAuthenticationAdapter` is the only adapter required for a minimal integration. It is the bridge between the Unity (Apollo) SDK's authentication subsystem and whatever authentication backend your game uses.

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
- The adapter contract has no login/logout commands — the SDK never initiates authentication flows. Your game drives its own login/logout with its auth provider and reports the outcomes by firing the corresponding `IAuthenticationListener` callbacks (`OnLoginSuccess`, `OnLoginFailed(string)`, etc.).

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

        // Optional — Firebase push callbacks (only if your game uses Firebase Cloud
        // Messaging; see FIREBASE_INTEGRATION_GUIDE.md).
        BFGUnitySDK.RegisterListener<MyFirebaseMessagingListener>();

        // Optional — built-in consent dialog hooks (only if your game uses Apollo's
        // GDPR/consent flow; see CONSENT_INTEGRATION_GUIDE.md). Note: unlike the
        // RegisterListener<T>() calls above, IPolicyListener is registered BY INSTANCE.
        BFGUnitySDK.AddPolicyListener(new MyPolicyListener());

        // 3. Initialize — wires everything together and starts the SDK
        BFGUnitySDK.Initialize();

        // 4. Supply the attribution ID
        //    This value is stamped on all subsequent GTS events as 'afid'.
        //    Set it as soon as your attribution SDK has obtained the ID.
        BFGUnitySDK.SetAttributionID(ATTRIBUTION_ID);
    }
}
```

**Registration rules:**
- All `RegisterAdapter<T>()` and `RegisterListener<T>()` calls must occur **before** `Initialize()`. The SDK reads registrations at initialization time and throws `InvalidOperationException` if a type does not match any known adapter or listener interface.
- The optional listeners follow the same rule: register the Firebase messaging listener (and add the policy listener) before `Initialize()` so no early callbacks are missed. `AddPolicyListener` takes an instance rather than a type and has a matching `RemovePolicyListener`.
- Calling `Initialize()` more than once in the same session logs a warning and returns without re-initializing.
- An `IAuthenticationListener` registration is required. If one is not registered, the SDK logs an error during initialization.

**Authentication is required.** The SDK expects an `IAuthenticationAdapter` and `IAuthenticationListener` to be registered. Auth state (`UserID`, `IsAuthenticated`) is used to populate fields in every telemetry event.

---

## Feature Guide

---

### Game Telemetry Service (GTS)

Apollo's core event pipeline — always on. `install`, `sessionStart`, and `sessionEnd` fire
automatically on app lifecycle transitions; game code reports everything else through a small
API surface: custom events (`SendCustomEvent` with a `CustomEventData` payload you define),
purchase success/failure reporting from your own purchasing flow (`SendPurchasingSuccessEvent` /
`SendPurchasingFailureEvent` — Apollo never manages the purchase itself), and the identity
setters (`SetAppUserId` / `GetAppUserId`, `SetAttributionID`). Every event is assembled with
full device, session, identity, and consent context and delivered through a disk-persisted
retry queue.

- **Integration steps** (config files, registration, identity-field timing, custom/purchase
  event examples, verification): [`GTS_INTEGRATION_GUIDE.md`](GTS_INTEGRATION_GUIDE.md) (this folder)
- **Behavior/design details** (event triggers, wire format, queue/retry semantics, identity
  fields): [`GTS_DESIGN.md`](GTS_DESIGN.md)
- **API surface**: the [Telemetry](../Apollo_Documentation.md#telemetry) and
  [Purchase Reporting](../Apollo_Documentation.md#purchase-reporting) sections of the API Reference

---

### Consent (GDPR + ATT)

Apollo owns both compliance flows end to end. The **built-in GDPR/consent dialog** checks the Big
Fish policy service at init and on every foreground, presents any outstanding policies (GDPR-style
opt-in/opt-out and mandatory Terms-of-Use/Privacy-Policy acceptance) in its own server-driven
dialog, records every shown/accepted/declined decision to the compliance backend, and applies the
outcome to Apollo's telemetry (the GTS `tpte` field) and Firebase Analytics automatically. The
**iOS ATT prompt** is likewise Apollo-owned: the game decides *when*
(`RequestTrackingAuthorization()`), Apollo displays the native prompt, consumes the selection for
the GTS `aptts` field and IDFA gating itself, and reports the result through instance-registered
`IAttListener`s. Your game's job: provide two config files, register two listeners, trigger ATT at
the right moment, and feed the GDPR decision to any third-party ad/attribution SDKs it integrates
directly.

- **Integration steps:** [`CONSENT_INTEGRATION_GUIDE.md`](CONSENT_INTEGRATION_GUIDE.md) (this folder)
- **Behavior/design details:** [`CONSENT_DESIGN.md`](CONSENT_DESIGN.md)
- **API surface**: the
  [Consent & Policy](../Apollo_Documentation.md#consent--policy) (policy listeners, consent queries,
  game-managed overrides) and
  [App Tracking Transparency](../Apollo_Documentation.md#app-tracking-transparency-requesttrackingauthorization--iattlistener)
  sections of the API Reference

> **Game-managed consent (not recommended):** a game that runs its own consent system UI instead
> of Apollo's dialog reports the decision itself with `EnableTargetedAdvertising(bool)` (records
> to the compliance backend) plus `ApplyThirdPartyTrackingConsentStatus(bool)` (GTS `tpte`) and
> `SetFirebaseDataCollectionConsent(bool)` (Firebase Analytics) — see the
> [Consent & Policy section of the API Reference](../Apollo_Documentation.md#consent--policy) for those
> three calls.

---

### Firebase (Analytics, Crashlytics, Messaging)

Apollo wraps Firebase Analytics, Crashlytics, and Cloud Messaging behind its adapter/listener
pattern — Apollo ships the adapter, so your game imports the Firebase Unity SDK, creates
`BfgFirebaseSettings.asset`, optionally registers an `IFirebaseMessagingListener`, and calls small
`BFGUnitySDK` APIs instead of writing Firebase glue. **Analytics** is GDPR-gated and off by
default (Apollo's built-in consent dialog drives it automatically). **Crashlytics** starts at init
and is deliberately not consent-gated. **Cloud Messaging** covers the FCM token lifecycle
(including automatic token upload to your push server), OS notification-permission timing under
game control, and notification-open delivery on both platforms including cold starts. In-App
Messaging is not included — the Firebase Unity SDK does not support it. The whole subsystem is
optional: without the settings asset (or with `enableFirebase` off), Firebase is skipped entirely.

- **Integration steps** (package import, config files, portal prerequisites, iOS/Android build
  steps, verification): [`FIREBASE_INTEGRATION_GUIDE.md`](FIREBASE_INTEGRATION_GUIDE.md) (this folder)
- **Behavior/design details:** [`FIREBASE_DESIGN.md`](FIREBASE_DESIGN.md)
- **API surface** (Analytics, Crashlytics, standard vs. data-only push): the
  [Firebase section of the API Reference](../Apollo_Documentation.md#firebase)

---

## What Happens Inside Initialize()

Understanding the internal initialization sequence helps diagnose setup problems. When `BFGUnitySDK.Initialize()` is called, the following happens in order:

1. **Guard check** — if already initialized, logs a warning and returns.
2. **BootstrapFactory.Init()** — loads `BfgSettings.asset` from `Resources` and maps it to a `ConfigData` object (selecting the correct platform block).
3. **Component construction** — creates internal components:
   - `Logging`
   - `Encoding` (JSON serialization)
   - `NetworkingController` — loads `ApolloNetworkConfig.json` from `Resources` to build the endpoint map
   - `TelemetryController` — always constructed
   - `PurchasingController` — only constructed if an `IPurchaseListener` was registered
   - `AuthenticationController` — only constructed if an `IAuthenticationListener` was registered
   - `FirebaseController` — only constructed if `BfgFirebaseSettings.asset` exists with `enableFirebase = true`; initializes Firebase asynchronously and treats init failure as non-fatal
   - `ConsentController` — always constructed; self-disables (with a log warning) if `Resources/ApolloConsentConfig.json` is missing or invalid
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

**Showing the ATT prompt yourself instead of through Apollo**
`BFGUnitySDK.RequestTrackingAuthorization()` is the only supported way to display the ATT prompt — Apollo records the selection the moment it resolves, so GTS events are correct from the very next event. A game-shipped prompt bypasses that recording: there is no API to report the result manually anymore (`ApplyAttConsentStatus` was removed), and events would carry the stale pre-prompt status until the next cold start's OS re-seed.

**Registering the ATT listener after requesting authorization**
When iOS has already determined the status, the result is delivered immediately — a listener added after `RequestTrackingAuthorization()` can miss it. Always `AddAttListener` first.

**Pointing production builds at the test endpoint**
The `ApolloNetworkConfig.json` file controls where events are delivered. Test and production use different `UrlRoot` values. Ensure your build pipeline substitutes the production config before shipping.

**Registering after `Initialize()`**
Adapter and listener registrations are read once during `Initialize()`. Any call to `RegisterAdapter` or `RegisterListener` after `Initialize()` has been called has no effect on the current session — this includes the optional `IFirebaseMessagingListener`. (The optional policy listener is different: `AddPolicyListener` is instance-based and can be called later, with the current policy state re-delivered to a late-added listener — but registering it before `Initialize()` is still the recommended pattern so no dialog events are missed.)

**Registering an unrecognized type**
`RegisterAdapter<T>()` and `RegisterListener<T>()` throw `InvalidOperationException` at registration time if `T` does not implement one of the recognized adapter or listener interfaces. Ensure your class explicitly implements the correct interface.

**Not persisting `UserID` across restarts**
The SDK reads `UserID` from your `IAuthenticationAdapter.UserID` property on every event. If your implementation returns an in-memory value that is not persisted (e.g., a field that starts empty on each launch), events after a restart will have no auth user ID. Persist the value to `PlayerPrefs` or Keychain in `SetUserID()` and read it back in the `UserID` getter.

**Setting the attribution ID too late**
`SetAttributionID` stores the value in `PlayerPrefs`. Any GTS event dispatched before `SetAttributionID` is called carries an empty `afid` field. Set the attribution ID as the first action after `Initialize()`, or inside an `OnInitializationComplete` callback, before any other telemetry calls. The one exception: on the very first launch the SDK defers the automatic `install` and `sessionStart` events for up to 5 seconds waiting for `SetAttributionID` (they are sent immediately when it is called, or with an empty `afid` when the window expires), so calling it promptly after `Initialize()` is enough for the install event to be attributed.
