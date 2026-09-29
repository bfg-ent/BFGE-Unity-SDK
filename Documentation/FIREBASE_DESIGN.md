# Design: Firebase Integration for the Unity (Apollo) SDK

**Scope:** Firebase Analytics, Crashlytics, and Cloud Messaging (FCM)
**Companion document:** `FIREBASE_INTEGRATION_GUIDE.md` — the steps to get the feature working. This document describes *how the feature behaves* — for testers and developers who need the full picture, including edge cases. Setup instructions are deliberately absent here.

## Contents

- [1. Purpose & scope](#1-purpose--scope)
- [2. Overall design](#2-overall-design)
  - [2.1 Adapter/listener architecture](#21-adapterlistener-architecture)
  - [2.2 `FirebaseController` lifecycle](#22-firebasecontroller-lifecycle)
  - [2.3 Configuration: `BfgFirebaseSettings.asset`](#23-configuration-bfgfirebasesettingsasset)
  - [2.4 The `APOLLO_FIREBASE` scripting define / no-op mode](#24-the-apollo_firebase-scripting-define--no-op-mode)
  - [2.5 GDPR consent gating (summary)](#25-gdpr-consent-gating-summary)
  - [2.6 GTS isolation and `BfgUdid`](#26-gts-isolation-and-bfgudid)
- [3. Analytics](#3-analytics)
- [4. Crashlytics](#4-crashlytics)
- [5. Cloud Messaging (FCM)](#5-cloud-messaging-fcm)
  - [5.1 Common plumbing](#51-common-plumbing)
  - [5.2 Notification permission flow](#52-notification-permission-flow)
  - [5.3 FCM token lifecycle & upload](#53-fcm-token-lifecycle--upload)
  - [5.4 Standard push notifications](#54-standard-push-notifications)
  - [5.5 Data-only push](#55-data-only-push)
- [6. Cross-cutting behaviors / good to know](#6-cross-cutting-behaviors--good-to-know)
- [7. Design decisions & rationale](#7-design-decisions--rationale)
- [8. Reference](#8-reference)

## 1. Purpose & scope

The Unity (Apollo) SDK wraps three Firebase products — **Analytics**, **Crashlytics**, and **Cloud Messaging (FCM/push)** — behind the SDK's standard adapter/listener pattern, so game teams configure a settings asset, register one listener, and call a small set of `BFGUnitySDK` APIs instead of writing Firebase glue themselves. Apollo owns the Firebase initialization, the GDPR gating of Analytics, the FCM token lifecycle (including uploading it to the game's push server), and the platform quirks around notification permission and notification-open delivery.

**Non-goals / exclusions:**

- **In-App Messaging is intentionally excluded.** The Firebase *Unity* SDK does not support it (Android/iOS/Flutter only); the `Firebase.InAppMessaging` namespace does not exist in the Unity SDK, so it was removed from the integration entirely (it briefly existed in early scaffolding).
- **No GTS coupling.** The Firebase subsystem makes zero changes to GTS telemetry or `GtsInfoProvider`, and there is no auto-mirroring of Analytics events into GTS (or vice versa). See §2.6 for the one deliberately shared piece.
- **Apollo does not decide GDPR consent for Firebase.** It *enforces* the decision (§2.5). The decision itself comes either from Apollo's built-in consent dialog (`Core/Consent/` — see `CONSENT_DESIGN.md`), which calls the Firebase consent API automatically, or from a game-owned consent flow calling it directly.

## 2. Overall design

### 2.1 Adapter/listener architecture

The subsystem follows Apollo's standard seam pattern with one twist: **Apollo ships the adapter**.

- `IFirebaseAdapter` (`Public API/Adapters/IFirebaseAdapter.cs`) is the seam between the controller and the Firebase Unity SDK. Apollo's built-in `DefaultFirebaseAdapter` (`Core/Firebase/DefaultFirebaseAdapter.cs`) is used automatically — games normally do **not** author or register a Firebase adapter. A game-registered `IFirebaseAdapter` *overrides* the default (checked first in `FirebaseController.Initialize`); this exists for special cases and testing.
- `IFirebaseMessagingListener` (`Public API/Listeners/IFirebaseMessagingListener.cs`) is the game-facing callback surface for push: `OnFcmTokenReceived(string)`, `OnMessageReceived(FirebaseRemoteMessage)`, `OnMessageOpened(FirebaseRemoteMessage)`. It is registered via `BFGUnitySDK.RegisterListener<T>()` **before** `BFGUnitySDK.Initialize()`, must have a public parameterless constructor (instantiated via reflection), and its callbacks are raised on the Unity main thread. Registering the listener is optional — without it, tokens and messages are still processed (and uploaded/logged) but nothing reaches game code.
- Everything else is internal: `FirebaseController` (orchestrator), `FcmTokenUploader`, and the `FirebaseSettings` ScriptableObject.

### 2.2 `FirebaseController` lifecycle

- **Optional construction.** `Bootstrap` constructs `FirebaseController` only when `Resources/BfgFirebaseSettings.asset` exists **and** `enableFirebase` is true (`Bootstrap.cs` — `firebaseEnabled` check). Otherwise the subsystem does not exist at runtime and any Firebase API call logs a warning telling the developer to create/enable the settings asset.
- **Standard init gate, async init.** The controller implements `IInitializable` and participates in the normal component init sequence. Its `Initialize` hands off to the adapter, which runs `FirebaseApp.CheckAndFixDependenciesAsync()` with a main-thread continuation — SDK init waits for the result like any other component, but the wait is asynchronous, not a frame stall.
- **Init failure is non-fatal.** A faulted/canceled dependency check, `DependencyStatus != Available`, or an exception during setup is logged (`"Initialization failed (continuing without Firebase)"`), the controller's state becomes `ServiceUnused`, and **overall SDK startup proceeds normally**. Firebase can never block the game from starting. This applies only to genuine Firebase setup failures — exceptions from game-registered listener/callback code (cold-start notification delivery, or the game's own `IInitializationListener`/`IFirebaseMessagingListener` implementations) are isolated, logged separately, and never affect Firebase's own initialization result.
- **`Start()` is a no-op** — Firebase begins working as soon as initialization completes. Immediately after all components start, `Bootstrap` calls `SetCrashlyticsUserId` with the Apollo **App User ID** (from `TelemetryController`) so Crashlytics reports correlate with Apollo telemetry (§4).
- **Every forwarded operation is `Ready`-gated.** If Firebase is disabled, still initializing, or failed init, each API call logs `"<op> called but Firebase is not initialized/enabled. Ignored."` — never a throw. Callback-taking APIs still complete their callback (`GetFcmToken` → `null`, `DeleteFcmToken` → `false`, `IsFcmTokenRegistrationEnabled` → `false`).

**Good to know:** because init is async, a Firebase API called *very* early (before the dependency check resolves) hits the not-ready warning and is dropped — it is not queued. In practice game code runs after `OnInitializationComplete`, where Firebase is already resolved one way or the other.

### 2.3 Configuration: `BfgFirebaseSettings.asset`

A `FirebaseSettings` ScriptableObject loaded from `Resources/BfgFirebaseSettings` at SDK init (`BootstrapFactory.Init`). Created via **BFG → Apollo → Create Missing Settings Files** (`ApolloSettingsMenu`, shipped in the package's Editor assembly). The Firebase *credentials* (`google-services.json` / `GoogleService-Info.plist`) are per-game project files, not stored here.

The authoritative field-by-field reference (defaults + per-field behavior) lives in
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → BfgFirebaseSettings.asset](APOLLO_SDK_INTEGRATION_GUIDE.md#bfgfirebasesettingsasset--firebase-configuration).
Behavior details referenced there: topic auto-subscribe timing is §5.1, permission-prompt timing
is §5.2, token upload is §5.3 (this document).

### 2.4 The `APOLLO_FIREBASE` scripting define / no-op mode

All Firebase Unity SDK usage in Apollo is compiled only when the **`APOLLO_FIREBASE`** scripting define is set (which requires the Firebase Unity SDK packages to be present in the compiling project). Without it:

- The SDK still compiles and initializes normally.
- `DefaultFirebaseAdapter.Initialize` logs one warning ("Firebase is running in no-op mode") and — deliberately — reports init **success**, with an internal not-ready flag, so the SDK proceeds and every subsequent Firebase call is a quiet no-op (callbacks return null/false).

**Distribution note (internal):** the shipped `Bfg.Apollo.dll`s must be **built** with `APOLLO_FIREBASE` set (via `DLLBuilder`) to contain Firebase functionality. Consuming games do **not** set the define — the DLL is already compiled — but must have the Firebase Unity SDK + EDM4U imported so the DLL's references resolve and native dependencies are pulled (the DLL references Firebase assemblies; it does not contain them). See the integration guide.

### 2.5 GDPR consent gating (summary)

| Product | Gated on GDPR selection? | Detail |
|---|---|---|
| Analytics | **Yes** — off by default | §3 |
| Crashlytics | **No** — starts at Firebase init | §4 |
| Messaging | **No** (iOS is gated on the *permission* call instead) | §5.2 |

The single consent API is `BFGUnitySDK.SetFirebaseDataCollectionConsent(bool)`:

- Called **automatically** by Apollo's built-in GDPR/consent dialog when the user answers the targeted-advertising policy (and by the `EnableTargetedAdvertising` game-managed override). A game with its own consent UI calls it directly after its flow resolves.
- Persisted in PlayerPrefs key **`BFG.Apollo.Firebase.DataCollectionConsent`** (0/1, default 0 = denied), so it survives restarts — call it once per decision, not every launch (re-calling with the stored value is harmless).
- **Not `Ready`-gated:** the call persists the flag and forwards to the adapter even before/without Firebase init, so a consent decision recorded early (or while Firebase is disabled) is not lost — it is applied from the persisted value at the next Firebase init.

### 2.6 GTS isolation and `BfgUdid`

The one piece shared with the rest of the SDK is **`BfgUdid`** (`Core/Utils/BfgUdid.cs`) — the stable device id used both as the GTS `bfgudid` field and as the `deviceId` in FCM token uploads (§5.3). Its persistence keys/derivation must never change; everything else in the Firebase subsystem is isolated from telemetry.

## 3. Analytics

**Consent model.** Analytics data collection is **disabled by default** and enabled only by consent:

- At Firebase init, the adapter applies the *persisted* consent value via `FirebaseAnalytics.SetAnalyticsCollectionEnabled(granted)` **before anything can collect data**, and re-applies it on every `SetFirebaseDataCollectionConsent` call. The Firebase-level toggle is only touched when `enableAnalytics` is set.
- `LogFirebaseEvent` calls made **before consent is granted are dropped and logged** ("Analytics consent not granted; ignoring event '<name>'"). They are not queued or replayed.
- Revoking consent (`false`) disables collection again, immediately and persistently.

**API behavior:**

- `BFGUnitySDK.LogFirebaseEvent(string eventName, Dictionary<string, object> parameters = null)` — parameter values convert as: `long`/`int` → long, `double`/`float` → double, `null` → empty string, anything else → `ToString()`. Null/empty dictionary logs a parameterless event.
- `BFGUnitySDK.SetFirebaseUserProperty(string name, string value)` — property names must be registered in the Firebase console.
- `BFGUnitySDK.SetFirebaseAnalyticsUserId(string userId)` — null clears it.

**Good to know:**

- `SetFirebaseUserProperty` / `SetFirebaseAnalyticsUserId` are gated on `enableAnalytics` but **not** on the consent flag — unlike `LogFirebaseEvent`, they pass straight through to Firebase. Nothing transmits while collection is disabled (Firebase holds them locally), but testers should not expect the "consent not granted; ignoring" log for these two calls.
- The runtime gate cannot cover the window between app launch and Apollo's consent application on the very first launch — guaranteeing *zero* pre-consent collection also requires the platform startup flags (`firebase_analytics_collection_enabled=false` in the Android manifest, `FIREBASE_ANALYTICS_COLLECTION_ENABLED=false` in `Info.plist`). Those are the game's responsibility; see the integration guide.

## 4. Crashlytics

**Crashlytics is deliberately NOT consent-gated.** Crash reporting starts at app launch (Firebase's native default) and Apollo **explicitly sets `Crashlytics.IsCrashlyticsCollectionEnabled = true` at Firebase init** whenever `enableCrashlytics` is set — regardless of, and before, any GDPR selection. `SetFirebaseDataCollectionConsent` never touches Crashlytics.

**Why the assignment is explicit** (rather than "just don't disable it"): Firebase *persists* `IsCrashlyticsCollectionEnabled` across launches. Under an earlier revision of this integration, GDPR consent gated Crashlytics too — so installs that declined GDPR under an older SDK version have the flag stuck `false` on-device and must be switched back on. (The gating decision was revised 2026-07-15: consent now governs Analytics only.)

**Corollary:** games must **not** ship `firebase_crashlytics_collection_enabled=false` (Android) or `FirebaseCrashlyticsCollectionEnabled=false` (iOS) startup flags — those would stop Crashlytics from collecting between app launch and Apollo's init, defeating launch-time crash coverage.

**API behavior** (all silent no-ops when `enableCrashlytics` is off):

- `BFGUnitySDK.LogCrashlyticsMessage(string message)` — breadcrumb log; the most recent entries are attached to the next crash report.
- `BFGUnitySDK.SetCrashlyticsCustomKey(string key, string value)` — key/value attached to subsequent reports.
- `BFGUnitySDK.RecordCrashlyticsException(Exception exception)` — records a handled (non-fatal) exception; a null exception is ignored.

**Crashlytics user id = Apollo App User ID.** Set automatically by `Bootstrap` right after all components start (`_firebase?.SetCrashlyticsUserId(_telemetry.GetAppUserId())`), so Crashlytics reports correlate with Apollo/GTS data by App User ID. There is no game-facing API for this — it is not overridable.

**Good to know:** symbolicated iOS reports require dSYM upload configuration at build time (integration guide); this is a build concern, not runtime behavior.

## 5. Cloud Messaging (FCM)

### 5.1 Common plumbing

- When messaging attaches (see the per-platform timing in §5.2), the adapter hooks Firebase's `TokenReceived` and `MessageReceived` events and subscribes to every topic in `autoSubscribeTopics`. Topic auto-subscribe happens **at attach time**, not at init — on an iOS fresh install that is inside `RequestNotificationPermission()`, because subscribing before the messaging API is safe to touch would be silently dropped by the availability gate.
- Messages are surfaced as `FirebaseRemoteMessage` (`Public API/Firebase/FirebaseRemoteMessage.cs`): `MessageId`, `From`, `WasOpened`, `Data` (the custom key/value payload), `NotificationTitle`/`NotificationBody`, plus metadata (`Link`, `ClickAction`, `NotificationIcon`/`Sound`/`Tag`/`Color`, `CollapseKey`, `Priority`, `MessageType`).
- Dispatch rule: `WasOpened == true` → `OnMessageOpened` (de-duplicated by message id, §5.4); otherwise → `OnMessageReceived`.

### 5.2 Notification permission flow

The two platforms differ fundamentally; this is the single most important thing to understand when testing push.

**iOS — all messaging APIs are inert on a fresh install until the game calls `BFGUnitySDK.RequestNotificationPermission()`.**

The *first* touch of any `FirebaseMessaging` member (not just attaching the C# events) initializes the native messaging module, which **immediately shows the OS permission prompt and fetches an FCM token** — not suppressible from Unity. To keep the prompt under the game's control, Apollo stays off the messaging API entirely on a fresh install:

- `GetFcmToken` returns `null` via its callback; `SubscribeToFcmTopic` / `UnsubscribeFromFcmTopic` / `DeleteFcmToken` / `SetFcmTokenRegistrationEnabled` no-op (with a debug log); `IsFcmTokenRegistrationEnabled` returns `false`.
- `RequestNotificationPermission()` is the unlock: it records the gate, attaches the FCM listeners (which triggers the Firebase SDK's own native permission request — the OS prompt appears at exactly this moment), applies `autoSubscribeTopics`, and calls `RequestPermissionAsync`, which joins the in-flight native request. Call it at exactly the moment the prompt should appear (e.g. after the GDPR → ATT flow).
- The gate is persisted per-install in PlayerPrefs **`BFG.Apollo.Firebase.PushPermissionRequested`**. On every later launch the OS can no longer prompt, so listeners attach at Firebase init and tokens/messages flow normally — whether the user granted or denied. Calling `RequestNotificationPermission()` again later completes immediately (the user has already decided).
- Keep `requestNotificationPermissionOnStart` **false** for consent-flow games; `true` makes Apollo run the unlock during init, i.e. the prompt appears at first launch.

**Android — no permission gate on the messaging API.** Listeners attach at SDK init. The FCM token is issued (and auto-uploaded) and foreground `OnMessageReceived` fires **regardless of the permission state** — the `POST_NOTIFICATIONS` permission only controls whether notifications *display*. `RequestNotificationPermission()`:

- Uses **Unity's Android permission API** (`Permission.RequestUserPermission`) for `POST_NOTIFICATIONS`, because Firebase's `RequestPermissionAsync()` is a **known no-op** for Android's `POST_NOTIFICATIONS` (it targets iOS APNs; firebase-unity-sdk issue #1286).
- Only prompts on Android 13 / API 33+ (logged no-op below — the permission is granted by default) and skips if already granted.
- Requires the game to declare `POST_NOTIFICATIONS` in its manifest (integration guide); without the declaration the prompt can never appear.

### 5.3 FCM token lifecycle & upload

`OnFcmTokenReceived` fires when the token is first issued and on every rotation. Each time, `FcmTokenUploader` registers the device with the game team's push server:

- **When `tokenUploadUrl` is set:** POST `{ "token": ..., "platform": ..., "deviceId": ... }` (JSON), with optional `x-api-key` header from `tokenUploadApiKey`. `platform` is `"ios"` / `"android"` / `"editor"`; `deviceId` is the SDK's stable **BFGUDID** (§2.6). **Empty URL = upload disabled** (the listener callback still fires).
- The server upserts by `deviceId + platform`, so repeat uploads are idempotent and a rotated token replaces the device's previous row — the latest token wins.
- The upload is fire-and-forget: 15-second timeout, success/failure logged, **no retry queue**. A failed upload is retried naturally the next time Firebase re-raises the token (every launch on iOS — see below — and on rotation).

**Edge cases / good to know:**

- **Two token uploads on a fresh iOS install are expected.** Firebase issues an FCM token *before* APNs registration completes and rotates it once the APNs token is set, so `OnFcmTokenReceived` (and the upload) fires twice. The upsert makes this harmless.
- On iOS, every later launch re-attaches listeners at init and Firebase re-raises the current token, so the upload also re-fires once per launch.
- Token-adjacent APIs: `GetFcmToken(Action<string>)` fetches asynchronously (null on failure); `DeleteFcmToken(Action<bool>)` invalidates the current token (e.g. logout/account switch) — the device stops receiving sends targeted at it until a new token is generated; `SetFcmTokenRegistrationEnabled(bool)` / `IsFcmTokenRegistrationEnabled()` wrap Firebase's `TokenRegistrationOnInitEnabled` to defer token creation until opt-in. For a token that is truly off from the very first launch, the manifest/plist auto-init flag (`firebase_messaging_auto_init_enabled=false` / `FirebaseMessagingAutoInitEnabled=NO`) must also be set — the runtime call then turns it on after consent.

### 5.4 Standard push notifications

"Standard" = messages with a notification block (title/body), including hybrid notification+data messages.

**Foreground:** the OS does **not** auto-display a notification for a foregrounded app; the message is delivered to `OnMessageReceived` and displaying anything is the game's choice.

**Background / killed → user taps the notification → `OnMessageOpened`.** The cold-start (app-killed) case is **SDK-compensated on both platforms**, because the Firebase C# opened event is unreliable when the app launches from a killed state (the native layer processes the launch payload seconds before Apollo can attach a handler):

- **Android:** at Firebase init, Apollo reads the launch Activity's intent extras via JNI. An intent stamped with an FCM message id (`google.message_id`/`from`) is synthesized into a `FirebaseRemoteMessage` (`WasOpened = true`) and delivered; the id is then removed from the intent so it is never re-read. Warm background taps use the Firebase C# opened event, with Apollo backfilling missing fields from the current tap intent (matched by message id). Requires the game's launcher activity to be Firebase's `MessagingUnityPlayerActivity` (integration guide) — without it, background/killed taps never reach the SDK at all.
- **iOS:** under Unity's UIScene lifecycle, a killed-state notification tap is delivered in the *scene connection options*, which neither Unity's scene delegate nor the Firebase iOS SDK reads — the payload would simply vanish. `Assets/Plugins/iOS/Apollo/ApolloPushLaunch.mm` captures it natively at launch (scene-connect hook plus legacy fallbacks) and the adapter consumes and replays it as `OnMessageOpened` after Firebase initializes. Warm background taps fire the Firebase C# opened event directly. The native capture only exists on device — in the Editor (iOS build target) the replay path is skipped via a runtime platform check.
- **De-duplication:** both platforms de-duplicate opened deliveries by message id, so `OnMessageOpened` fires **exactly once per tap** even when the cold-start path and the C# event would both deliver.

**Title/body asymmetry — the key cross-platform gotcha:**

- **Android opened messages do NOT carry the notification title/body.** Modern FCM strips the entire notification block (`gcm.n.*` / `gcm.notification.*` — title, body, icon, sound, …) from the tap intent by design, so `OnMessageOpened` on Android delivers message metadata (id, from, collapse key, priority) plus the **custom `data` payload only** — `NotificationTitle`/`NotificationBody` are null. This is FCM platform behavior, not an Apollo limitation (Apollo's legacy-FCM intent backfill is best-effort and does not apply on current FCM versions).
- **iOS opened messages DO carry title/body** — the tap delivers the full APNs payload.
- **Rule for games:** anything needed on open must ride the custom `data` payload — it survives the tap on both platforms.

**Silent wakes never count as opens.** A `content-available` background wake without a user tap on a displayed notification never produces `OnMessageOpened` — the iOS launch capture requires a real tap on a displayable push (and an FCM stamp), and the Android path requires an FCM-stamped tap intent.

#### Sending a test push from the Firebase console

The console has a built-in tool for sending a notification directly to a single device by its FCM registration token — no send server needed:

1. **Get the device's token** — it is delivered to your `IFirebaseMessagingListener.OnFcmTokenReceived` callback (log it during development), or grab it from the device log / the token-upload POST if `tokenUploadUrl` is configured.
2. **Find the tool:** Firebase console → your project → **Run → Messaging** (older console layouts: **Engage → Messaging**) → **New campaign → Notifications**.
3. Enter a notification title/text, then click **Send test message** (button next to the title/text fields in the first step of the composer — you do not need to complete or publish the campaign).
4. Paste the device's registration token, click **+** to add it, then **Test**. The message is sent immediately to just that device.
5. Optional `data` payload: in the campaign composer's **Additional options** step, add **Custom data** key/value pairs before using *Send test message* — they arrive as the message's `Data` dictionary (hybrid notification+data, §5.4's recommended shape).

Limitations: this tool always sends a **notification** message — true data-only pushes (§5.5) cannot be sent from the console and require the FCM v1 HTTP API or a send server. Behavior on receipt follows §5.4: foregrounded app → `OnMessageReceived` with nothing displayed; backgrounded/killed → system notification, and the tap fires `OnMessageOpened`.

### 5.5 Data-only push

Data-only = no notification block (no title/body); nothing displays; the payload is for the game.

- **Delivery to game code:** via `OnMessageReceived` while the app is foregrounded — on both platforms — and, on iOS, also on the next background→foreground resume. On Android, foreground delivery works regardless of the notification permission state.
- **iOS reliability:** background delivery of silent pushes is **best-effort** — iOS frequently throttles/drops silent data-only pushes (battery, Background App Refresh, budget heuristics). **The reliable pattern is a hybrid message (notification + data):** the notification block guarantees delivery/display and the data payload carries the game's values through the tap (§5.4). Data-only should be treated as foreground messaging, not a guaranteed background channel.
- **iOS prerequisites:** background delivery requires the `remote-notification` background mode *and* the `UNITY_USES_REMOTE_NOTIFICATIONS=1` export fix (integration guide). The failure symptom of the latter is worth knowing when testing: everything looks healthy — permission granted, token issued and uploaded, the native layer even receives the push — but `OnMessageReceived` silently never fires in C#.
- **Android:** send data-only messages **high-priority** for dependable prompt delivery (normal priority may be deferred by Doze).
- The token upload pipeline (§5.3) exists primarily for this feature — it is how a game's server learns which token targets which device for data-only sends.

## 6. Cross-cutting behaviors / good to know

- **Editor:** Firebase has limited Editor support; behavior depends on whether the Editor project has the packages + define. Token uploads from the Editor report `platform: "editor"`; the iOS cold-start replay is skipped in the Editor by a runtime platform check even with the iOS build target selected.
- **Logging surface for testers:** with `verboseDebugLogging` on, every FCM token, full message payload (received *and* opened, with per-field null markers), Analytics event (name + parameters), consent change, and skip/no-op reason is logged with the `[Apollo.Firebase]` prefix. This is the primary QA observation channel.
- **No Firebase call ever throws** for lifecycle reasons: disabled feature, missing settings asset, not-yet-initialized, failed init, missing define, and the iOS permission gate all produce logged warnings/debug lines and safe return values instead.
- **Calling Firebase APIs when the subsystem was never constructed** (no asset / master switch off) logs: *"Firebase is not enabled. Create a BfgFirebaseSettings asset (BFG → Apollo → Create Missing Settings Files) and enable Firebase before calling Firebase APIs."*

## 7. Design decisions & rationale

| Decision | Choice / rationale |
|---|---|
| Exposure model | Adapter/listener, consistent with the rest of Apollo — but Apollo ships the adapter (`DefaultFirebaseAdapter`); games only register a messaging listener. |
| Analytics ↔ GTS | Explicit API only; zero GTS changes, no auto-mirroring. |
| Settings home | Dedicated `BfgFirebaseSettings.asset`, separate from `BfgSettings` — Firebase is optional and per-game. |
| GDPR gating | Collection off by default; one consent API. Originally gated Analytics + Crashlytics + In-App Messaging together; IAM was removed 2026-06-30 (unsupported on Unity) and Crashlytics was un-gated 2026-07-15 (crash coverage is not tracking; launch-time crashes must be captured). |
| FCM token destination | Originally "log only"; revised to an SDK-owned upload (`FcmTokenUploader` → `tokenUploadUrl`) so games write no upload code. `deviceId` is BFGUDID (no App User ID in the payload). |
| Firebase package delivery | **Not** declared as UPM `dependencies` of the Apollo package — BFG games consume Firebase via EDM4U/`.unitypackage`, and declaring `com.google.firebase.*` UPM deps breaks their resolution. Imported per-project instead. |
| Cold-start open compensation | Added after on-device testing showed the Firebase C# opened event misses app-killed launches on both platforms; Android reads the launch intent, iOS captures the UIScene connection options natively. |
| Android permission request | Unity's permission API instead of Firebase's `RequestPermissionAsync` (a known no-op for `POST_NOTIFICATIONS`). |

## 8. Reference

Setup (packages, define, credentials, APNs/Xcode export steps, Android manifest/launcher, startup flags, settings asset creation): see **`FIREBASE_INTEGRATION_GUIDE.md`**.

**Public API (`BFGUnitySDK`):**

| API | Notes |
|---|---|
| `SetFirebaseDataCollectionConsent(bool granted)` | Analytics gate; persisted; Crashlytics unaffected (§2.5, §3, §4). |
| `LogFirebaseEvent(string eventName, Dictionary<string, object> parameters = null)` | Dropped + logged pre-consent (§3). |
| `SetFirebaseUserProperty(string name, string value)` | Not consent-checked (§3). |
| `SetFirebaseAnalyticsUserId(string userId)` | Null clears (§3). |
| `LogCrashlyticsMessage(string message)` | Breadcrumb (§4). |
| `SetCrashlyticsCustomKey(string key, string value)` | (§4) |
| `RecordCrashlyticsException(Exception exception)` | Handled/non-fatal (§4). |
| `GetFcmToken(Action<string> onToken)` | Null on failure / iOS pre-permission / disabled (§5.2, §5.3). |
| `SubscribeToFcmTopic(string topic)` / `UnsubscribeFromFcmTopic(string topic)` | iOS pre-permission: skipped with debug log (§5.2). |
| `RequestNotificationPermission()` | iOS unlock + APNs prompt; Android 13+ `POST_NOTIFICATIONS` via Unity API (§5.2). |
| `DeleteFcmToken(Action<bool> onComplete = null)` | Logout/account switch (§5.3). |
| `SetFcmTokenRegistrationEnabled(bool enabled)` / `IsFcmTokenRegistrationEnabled()` | Wraps `TokenRegistrationOnInitEnabled` (§5.3). |
| `RegisterListener<T>()` | Registers `IFirebaseMessagingListener` before `Initialize()` (§2.1). |

**PlayerPrefs keys:**

| Key | Meaning |
|---|---|
| `BFG.Apollo.Firebase.DataCollectionConsent` | GDPR data-collection consent for Analytics (0 = denied, 1 = granted; default 0). |
| `BFG.Apollo.Firebase.PushPermissionRequested` | iOS: notification permission has been requested at least once on this install — the messaging-API availability gate (§5.2). |

**Code map:** `Core/Firebase/FirebaseController.cs` (orchestrator), `Core/Firebase/DefaultFirebaseAdapter.cs` (Firebase wrapper, platform compensation), `Core/Firebase/FcmTokenUploader.cs`, `Data/ScriptableObjects/FirebaseSettings.cs`, `Public API/Adapters/IFirebaseAdapter.cs`, `Public API/Listeners/IFirebaseMessagingListener.cs`, `Public API/Firebase/FirebaseRemoteMessage.cs`, `Assets/Plugins/iOS/Apollo/ApolloPushLaunch.mm` (native iOS launch-tap capture), `Bootstrap/Bootstrap.cs` (construction gate, Crashlytics user id wiring).
