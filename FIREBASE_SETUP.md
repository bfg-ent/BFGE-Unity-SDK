# Firebase Setup for the Apollo SDK

This document covers the one-time, Unity-Editor / environment steps required to enable the Firebase
integration that was added to the Apollo SDK in code. The C# integration (controller, adapter,
settings, public API) is already in the repo, but it stays inert until the Firebase Unity SDK is
imported and the `APOLLO_FIREBASE` scripting define is set.

> **Why a manual step?** Firebase is not published to a public Unity (UPM) registry. Google
> distributes the Firebase Unity SDK as downloadable `.tgz` tarballs (plus the External Dependency
> Manager, EDM4U). These must be added to **each** Unity project; they cannot be auto-resolved from a
> URL alone.
>
> **Important:** the Apollo package does **not** declare Firebase as UPM `dependencies` in
> `Apollo-Package/package.json`. BFG games (e.g. Galaxy Gems) import Firebase via EDM4U / `.unitypackage`,
> not as UPM packages — declaring `com.google.firebase.*` UPM deps would break their package resolution.
> Firebase must therefore be imported into each consuming project directly (this section + §3).

---

## 1. Add Firebase + EDM4U to the Apollo SOURCE project (`Apollo_Rebuild`)

This is required so `Bfg.Apollo.dll` compiles against the Firebase APIs.

1. Download the **Firebase Unity SDK** zip from Google
   (<https://firebase.google.com/download/unity>) and extract it.
2. In Unity: **Window → Package Manager → + → Add package from tarball…** and add each of these
   `.tgz` files from the extracted SDK (versions below are examples — match what you downloaded):
   - `com.google.external-dependency-manager` (EDM4U) — add this first
   - `com.google.firebase.app`
   - `com.google.firebase.analytics`
   - `com.google.firebase.crashlytics`
   - `com.google.firebase.messaging`

   (Do **not** import `com.google.firebase.in-app-messaging` — In-App Messaging is not supported by
   the Firebase Unity SDK and is intentionally excluded from the Apollo integration.)

   After import, `Packages/manifest.json` will contain entries like:
   ```jsonc
   "com.google.external-dependency-manager": "file:<path-or-tarball>",
   "com.google.firebase.app": "file:<path-or-tarball>",
   "com.google.firebase.analytics": "file:<path-or-tarball>",
   "com.google.firebase.crashlytics": "file:<path-or-tarball>",
   "com.google.firebase.messaging": "file:<path-or-tarball>"
   ```

3. Add the **`APOLLO_FIREBASE`** scripting define so Apollo's Firebase code is compiled in:
   **Project Settings → Player → Other Settings → Scripting Define Symbols** → add `APOLLO_FIREBASE`
   for the **Android** and **iOS** platform tabs (and the platform you build the DLL from).

   > Without this define the SDK still compiles and runs, but the Firebase adapter is a logged no-op.

4. Let **EDM4U** resolve native dependencies: **Assets → External Dependency Manager → Android
   Resolver → Resolve** (and accept iOS Cocoapods on the iOS build).

5. Add the Firebase project config files (per game — see §3). For the SDK source project a
   placeholder config is fine for compiling/Editor testing.

---

## 2. Build the Apollo DLLs

Use **Tools → Build → Build Apollo DLLs** (the existing `DLLBuilder`). Because `APOLLO_FIREBASE` is
set, the produced `Bfg.Apollo.dll` references the Firebase assemblies. Publish the DLLs to the
`Apollo-Package` repo as usual.

**For local testing** (without publishing to git), run `./copy-apollo-dlls.sh` from `Apollo_Rebuild` —
it copies the three per-platform DLLs from `BuildOutput/` into `Apollo-Package/Plugins/` and bumps the
package version. A consuming project that references `Apollo-Package` via a local `file:` path in its
`manifest.json` (e.g. Galaxy Gems: `"bfg.apollo": "file:../../Apollo-Package"`) then picks up the new
DLLs on the next Editor focus / package re-resolve.

---

## 3. Per-game setup (consuming projects, e.g. Galaxy Gems)

1. **Firebase config files** (from the Firebase console, per game/app):
   - Android: place `google-services.json` at the **Unity project root**. The Firebase Unity editor
     tooling converts it into a generated Android resource library —
     `Assets/Plugins/Android/FirebaseApp.androidlib/res/values/google-services.xml` (this is what
     Galaxy Gems ships) — which is what actually reaches the APK. If you move/replace the json,
     regenerate and commit the updated `.androidlib`.
   - iOS: add `GoogleService-Info.plist` to the project (it is copied into the Xcode project).
2. **Firebase + EDM4U packages**: the game project also needs the Firebase Unity SDK + EDM4U imported
   (same tarballs as step 1), since the precompiled `Bfg.Apollo.dll` only references — it does not
   contain — Firebase's native libraries. Setting the `APOLLO_FIREBASE` define is **not** needed in the
   game (the DLL is already compiled); the game just needs the Firebase packages present so the DLL's
   references resolve and EDM4U pulls the native deps.
3. Run **EDM4U → Resolve** for Android; for iOS, build and let Cocoapods install the Firebase pods.
4. **Crashlytics (iOS)**: ensure dSYM upload is configured for symbolicated crash reports.

---

## 4. iOS: APNs + Xcode export steps (required for Cloud Messaging)

FCM on iOS rides on APNs, and neither the Firebase project nor Unity's exported Xcode project is
push-ready out of the box. Galaxy Gems automates every export-time step below in a single
`[PostProcessBuild]` script — `GalaxyGems/Assets/Scripts/Editor/iOSPostProcessBuild.cs` — which is
the reference implementation to copy into a new game.

### 4.1 Firebase Console prerequisite: upload an APNs Auth Key (.p8)

Apple Developer portal → **Certificates, Identifiers & Profiles → Keys** → create a key with the
**Apple Push Notifications service (APNs)** capability and download the `.p8` file. Then in the
Firebase Console: **Project settings → Cloud Messaging →** your iOS app → **APNs Authentication
Key → Upload** (enter the Key ID and your Team ID).

> Without this, FCM **accepts** sends (returns a message id, no error) but **silently never
> delivers** to iOS devices. Note that a production-only APNs *certificate* cannot reach
> development-signed builds — the `.p8` Auth Key covers both environments and is the recommended
> setup.

### 4.2 Required Xcode-project changes (apply on every export)

Unity's export does not enable push, so post-process the exported project (see GG's script):

1. **Push Notifications entitlement** — add the `aps-environment` entitlement via
   `ProjectCapabilityManager.AddPushNotifications(...)`, which creates the `.entitlements` file and
   wires `CODE_SIGN_ENTITLEMENTS` on the app target. Use the `development` value for Xcode/dev-signed
   builds and `production` for TestFlight / App Store builds.
2. **`UIBackgroundModes` → `remote-notification` in `Info.plist`** — iOS only delivers background /
   data-only (`content-available`) pushes to apps that declare this background mode.
3. **Flip `UNITY_USES_REMOTE_NOTIFICATIONS` from 0 to 1 in the exported `Classes/Preprocessor.h`** —
   **critical and non-obvious.** Unity writes this define as `0` whenever push is not enabled at
   export time — and it never is here, because the entitlement is added *post*-export (step 1). With
   the flag at 0, `UnityAppController`'s `didRegisterForRemoteNotificationsWithDeviceToken:` /
   `didReceiveRemoteNotification:fetchCompletionHandler:` handlers are compiled out.
   **Symptom:** everything else looks healthy — permission granted, FCM token issued and uploaded,
   the native Firebase layer even receives the push — but data-only messages silently never reach the
   Unity C# `OnMessageReceived` callback. **Fix:** replace
   `#define UNITY_USES_REMOTE_NOTIFICATIONS 0` with `#define UNITY_USES_REMOTE_NOTIFICATIONS 1` in
   `Classes/Preprocessor.h` after every export (see `EnableUnityRemoteNotifications()` in GG's
   script).

### 4.3 Dev-only conveniences (label as such; do not ship enabled)

- **ATS local-network exception** — to POST the FCM token to a LAN test console over plain HTTP
  (e.g. the Firebase Messaging Console dev server), add `NSAppTransportSecurity →
  NSAllowsLocalNetworking = true` plus an `NSLocalNetworkUsageDescription` string to `Info.plist`
  (iOS 14+ shows a one-time local-network prompt). Only needed while `tokenUploadUrl` points at a
  plain-HTTP LAN server during testing.
- **`-FIRDebugEnabled` launch argument** — injected into the Xcode Run scheme, this turns on verbose
  Firebase/FCM/APNs logging. Scheme arguments only apply to runs **launched from Xcode**; launching
  the app from the home screen ignores them.

### 4.4 iOS runtime behavior (what to expect)

- **The OS push prompt stays under the game's control.** On iOS, the *first* touch of any
  FirebaseMessaging API initializes the native messaging module, which immediately shows the OS
  permission prompt and fetches an FCM token (before APNs registration). Apollo therefore keeps every
  messaging API inert on a fresh install — `GetFcmToken` returns `null` via its callback;
  `SubscribeToFcmTopic` / `UnsubscribeFromFcmTopic` / `DeleteFcmToken` /
  `SetFcmTokenRegistrationEnabled` no-op; `IsFcmTokenRegistrationEnabled` returns `false` — until the
  game calls `BFGUnitySDK.RequestNotificationPermission()`. Call it at exactly the moment the prompt
  should appear (Galaxy Gems: after its GDPR → ATT flow, see `GDPRManager.cs` / `ATTManager.cs`).
  Keep `requestNotificationPermissionOnStart` **false** for games with a consent flow.
  `autoSubscribeTopics` is also applied at this moment, so it works with the gate.
- **Two token uploads on a fresh install are expected.** Firebase issues an FCM token before APNs
  registration completes and rotates it once the APNs token is set, so `OnFcmTokenReceived` (and the
  automatic token upload) fires twice on a fresh install. The push server upserts by
  `deviceId + platform`, so the latest token wins.
- **Data-only messages** (no `title`/`body`) arrive via `OnMessageReceived` while the app is
  foregrounded, and on the next background→foreground resume. Background delivery of silent pushes is
  best-effort on iOS — see the Firebase Messaging Console README ("data-only vs hybrid") for the
  delivery guidance.

---

## 5. Android: push messaging setup (required for Cloud Messaging)

The Android side needs no Xcode-style post-processing, but a few project pieces are required for
push to work end-to-end. Galaxy Gems (`GalaxyGems/Assets/Plugins/Android/`) is the reference
implementation for all of them.

### 5.1 Declare `POST_NOTIFICATIONS` in the manifest

Neither Unity nor the Firebase Unity SDK adds this permission — declare it yourself in the game's
custom manifest (`Assets/Plugins/Android/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

Without it, the Android 13+ runtime prompt can never be shown and notifications will not display on
API 33+ devices.

### 5.2 Launcher activity: `MessagingUnityPlayerActivity`

For notification taps (app backgrounded or killed) to reach `OnMessageOpened`, the launcher activity
must be Firebase's `com.google.firebase.MessagingUnityPlayerActivity` (it extends
`UnityPlayerActivity` and forwards the tap intent's payload to Firebase). Galaxy Gems ships both
pieces in `Assets/Plugins/Android/`:

- `MessagingUnityPlayerActivity.java` — generated by the Firebase Unity SDK's
  `FirebaseMessagingActivityGenerator` editor script; commit it alongside the manifest.
- A custom `AndroidManifest.xml` whose MAIN/LAUNCHER activity is
  `com.google.firebase.MessagingUnityPlayerActivity` (with the
  `unityplayer.UnityActivity = "true"` meta-data).

This requires **Player Settings → Application Entry Point = Activity** (not GameActivity).

### 5.3 Request the permission after your consent flow

`BFGUnitySDK.RequestNotificationPermission()` on Android requests the `POST_NOTIFICATIONS` runtime
permission via Unity's Android permission API (Android 13 / API 33+ only; a logged no-op below,
where the permission is granted by default). Apollo handles this itself because Firebase's
`RequestPermissionAsync()` is a known no-op for Android's `POST_NOTIFICATIONS`.

Galaxy Gems calls it from `GDPRManager` immediately after the GDPR decision (Android has no ATT
step). Keep `requestNotificationPermissionOnStart` **false** so the prompt timing stays under the
game's control.

### 5.4 Android runtime behavior (what to expect)

- **Listeners attach at SDK init** — unlike iOS there is no permission gate on the messaging API.
  The FCM token is issued (and auto-uploaded) and foreground `OnMessageReceived` fires regardless of
  the permission state; the permission only controls whether notifications *display*.
- **Data-only messages** (no `title`/`body`) arrive via `OnMessageReceived` reliably while the app
  is foregrounded (send them high-priority — the Firebase Messaging Console does by default).
- **Notification opens are handled by the SDK — no game code needed.** Cold start (app killed):
  Apollo reads the launch Activity's intent at init and fires `OnMessageOpened`. Warm background
  tap: the Firebase C# opened event fires and Apollo fills any missing fields from the tap intent.
  Deliveries are de-duplicated by message id, so `OnMessageOpened` fires once per tap in both cases.
- **Android opened messages do NOT carry the notification title/body.** FCM strips the entire
  notification block (`gcm.n.*` / `gcm.notification.*` — title, body, icon, sound, …) from the tap
  intent before displaying the notification, so on Android `OnMessageOpened` delivers message
  metadata (message id, from, collapse key, priority) plus the **custom `data` payload only** —
  `NotificationTitle`/`NotificationBody` are null. This is FCM platform behavior, not an Apollo
  limitation (on iOS the tap carries the full APNs payload, so title/body ARE populated there).
  **Put anything the game needs on open into the `data` payload** — it survives the tap intent on
  both platforms.

### 5.5 Dev-only: plain-HTTP token upload to a local console

`UnityWebRequest` blocks `http://` URLs by default, so a `tokenUploadUrl` pointing at a LAN/localhost
test console (e.g. the Firebase Messaging Console dev server) needs
**Player Settings → Other Settings → Allow downloads over HTTP** set to *Allowed in development
builds* (or *Always allowed* — what Galaxy Gems currently uses for testing; do not ship that). No
Android network-security-config change was needed in Galaxy Gems.

Device → host reachability: over USB run `adb reverse tcp:8080 tcp:8080` and point `tokenUploadUrl`
at `http://localhost:8080/api/tokens` (re-run the reverse after every unplug/reboot), or use the host
machine's LAN IP over Wi-Fi. See the Firebase Messaging Console README for the full dev workflow.

---

## 6. Create the Apollo Firebase settings asset

In a game consuming the Apollo DLL package: right-click **Create → BFG/Apollo/Firebase Settings**,
name the asset `BfgFirebaseSettings`, and keep it in a `Resources` folder (the SDK loads
`Resources/BfgFirebaseSettings` at runtime). In the Apollo source project the
**BFG → Apollo → Firebase Settings** menu does the same and places it at
`Assets/Dependencies/Bfg/Configuration/Resources/BfgFirebaseSettings.asset`; that menu is an editor
script and is not shipped in the DLL package. Toggle the per-feature flags and set FCM
auto-subscribe topics as needed. If this asset does not exist or `enableFirebase` is off, Apollo
skips Firebase entirely.

---

## 7. GDPR / data collection

Consent gating applies to **Analytics only**:

- **Analytics** — collection is **disabled by default** and gated on the game's GDPR decision.
- **Crashlytics** — **not consent-gated.** Crash reporting starts at app launch (Firebase's native
  default) and Apollo re-asserts it on at SDK init whenever `enableCrashlytics` is set, regardless
  of — or before — any GDPR selection.
- **Messaging** — not gated on the GDPR *selection*; on iOS it is gated on the game calling
  `RequestNotificationPermission()` (see §4.4).

To guarantee Analytics collects nothing before consent, also set the startup flags so it does not
auto-collect on first launch:

- **Android** — in the manifest (or `Assets/Plugins/Android/...`):
  ```xml
  <meta-data android:name="firebase_analytics_collection_enabled" android:value="false" />
  <meta-data android:name="google_analytics_default_allow_analytics_storage" android:value="false" />
  ```
- **iOS** — in `Info.plist`:
  ```xml
  <key>FIREBASE_ANALYTICS_COLLECTION_ENABLED</key><false/>
  ```

> **Do NOT set** `firebase_crashlytics_collection_enabled=false` (Android) or
> `FirebaseCrashlyticsCollectionEnabled=false` (iOS). Those flags would stop Crashlytics from
> collecting between app launch and Apollo's init, defeating launch-time crash coverage.

After your game's GDPR flow resolves, call:
```csharp
BFGUnitySDK.SetFirebaseDataCollectionConsent(true);  // or false
```
This enables/disables Analytics data collection and is persisted across sessions. Crashlytics is
unaffected by this call.

---

## 8. Quick API reference

```csharp
// Consent (call after your GDPR decision)
BFGUnitySDK.SetFirebaseDataCollectionConsent(true);

// Analytics (no-ops until consent granted)
BFGUnitySDK.LogFirebaseEvent("level_complete", new Dictionary<string, object> { { "level", 7L } });
BFGUnitySDK.SetFirebaseUserProperty("favorite_mode", "endless");
BFGUnitySDK.SetFirebaseAnalyticsUserId("user-123");

// Crashlytics
BFGUnitySDK.LogCrashlyticsMessage("Entered shop screen");
BFGUnitySDK.SetCrashlyticsCustomKey("coins", "1500");
BFGUnitySDK.RecordCrashlyticsException(new Exception("handled"));

// Cloud Messaging
BFGUnitySDK.GetFcmToken(token => Debug.Log(token));
BFGUnitySDK.SubscribeToFcmTopic("promotions");
BFGUnitySDK.RequestNotificationPermission();
```

> **iOS:** all Cloud Messaging APIs are inert on a fresh install until the game calls
> `RequestNotificationPermission()` — `GetFcmToken` returns `null`, topic and token APIs no-op.
> See §4.4.

> **Android:** the messaging APIs work from SDK init (no gate). `RequestNotificationPermission()`
> shows the Android 13+ `POST_NOTIFICATIONS` prompt and requires the manifest entry from §5.1;
> call it after your consent flow. See §5.

**Token upload:** set `tokenUploadUrl` (and optionally `tokenUploadApiKey`) in
`BfgFirebaseSettings.asset` and the SDK POSTs `{ token, platform, deviceId }` to your push server on
every FCM token issue/rotation — `deviceId` is the SDK's stable BFGUDID, so the server can key its
device store by `deviceId + platform`. Leave the URL empty to disable uploading.

To receive push callbacks, implement and register a listener **before** `BFGUnitySDK.Initialize()`:
```csharp
BFGUnitySDK.RegisterListener<MyFirebaseMessagingListener>();      // IFirebaseMessagingListener
```
