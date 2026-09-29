# Unity (Apollo) SDK Firebase Integration Guide (Analytics, Crashlytics, FCM Push)

Step-by-step integration of the Unity (Apollo) SDK's Firebase features into a game consuming the prebuilt
`bfg.apollo` package. This guide covers **what you must do**; for how the features behave (consent
gating rules, token lifecycle, notification-open handling, edge cases), see `FIREBASE_DESIGN.md`.
For the full API surface, see the [API Reference](../Apollo_Documentation.md).

The shipped Apollo DLLs already contain the Firebase integration — you do **not** set any scripting
define or rebuild anything. Your game's job is: import the Firebase Unity SDK, add the per-app
config files, create one settings asset, register one listener, and make two calls at the right
moments.

---

## 1. Import the Firebase Unity SDK + EDM4U (tarballs)

Firebase is not published to a public UPM registry, and the Apollo package deliberately declares
**no** Firebase UPM dependencies — each game imports Firebase itself. The precompiled
`Bfg.Apollo.dll` only *references* Firebase; without these packages present its Firebase features
are a logged no-op.

1. Download the **Firebase Unity SDK** zip from <https://firebase.google.com/download/unity> and
   extract it.
2. **Window → Package Manager → + → Add package from tarball…** — add these `.tgz` files:
   - `com.google.external-dependency-manager` (EDM4U) — add this first
   - `com.google.firebase.app`
   - `com.google.firebase.analytics`
   - `com.google.firebase.crashlytics`
   - `com.google.firebase.messaging`

   Do **not** import `com.google.firebase.in-app-messaging` — In-App Messaging is not supported by
   the Firebase Unity SDK and is excluded from the Apollo integration.
3. Resolve native dependencies: **Assets → External Dependency Manager → Android Resolver →
   Resolve**. On iOS, CocoaPods installs the Firebase pods during the Xcode build.

## 2. Add the Firebase app config files (Firebase console, per app)

- **Android**: place `google-services.json` at the **Unity project root**. The Firebase editor
  tooling converts it into a generated resource library —
  `Assets/Plugins/Android/FirebaseApp.androidlib/res/values/google-services.xml` — which is what
  actually reaches the APK. If you replace the json, **regenerate and commit the updated
  `.androidlib`**.
- **iOS**: add `GoogleService-Info.plist` to the project (it is copied into the Xcode project).

## 3. Portal prerequisites (Firebase / Google Cloud / Apple, once per project)

All push (notification and data-only) rides the FCM HTTP v1 API. Verify once per Firebase project:

1. **FCM v1 API enabled** — Firebase console → **Project settings → Cloud Messaging**: "Firebase
   Cloud Messaging API (V1)" must show **Enabled**. If not: three-dot menu → *Manage API in Google
   Cloud Console* → Enable (or go directly to
   `https://console.cloud.google.com/apis/library/fcm.googleapis.com?project=<project-id>`).
2. **APNs Auth Key uploaded** (iOS delivery) — Apple Developer portal → **Certificates,
   Identifiers & Profiles → Keys** → create a key with the **APNs** capability and download the
   `.p8`. Then Firebase console → **Project settings → Cloud Messaging →** your iOS app → **APNs
   Authentication Key → Upload** (Key ID + Team ID). **Without this, FCM accepts sends (returns a
   message id, no error) but silently never delivers to iOS devices.** The `.p8` key covers both
   dev- and production-signed builds; a production-only APNs *certificate* does not.
3. **Service-account key** for your send server — Firebase console → **Project settings → Service
   accounts → Generate new private key**. The downloaded JSON is the server's send credential.
   **Never commit it.**
4. **Custom service accounts only**: a non-default account needs the **Firebase Cloud Messaging
   API Admin** role in Google Cloud Console → IAM & Admin → IAM. (The default
   `firebase-adminsdk-…` account can already send.)

## 4. Create `Assets/Resources/BfgFirebaseSettings.asset`

Use the Unity menu **BFG → Apollo → Create Missing Settings Files** (creates every missing Apollo
settings file, this asset included, under `Assets/Resources/`). The asset must be named
`BfgFirebaseSettings` and live under `Resources/` (the SDK loads `Resources/BfgFirebaseSettings`
at runtime). If the asset is missing or `enableFirebase` is off,
Apollo skips Firebase entirely.

The field-by-field reference lives in
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → BfgFirebaseSettings.asset](APOLLO_SDK_INTEGRATION_GUIDE.md#bfgfirebasesettingsasset--firebase-configuration).
For this integration: set `enableFirebase = true` and the per-feature switches you use, point
`tokenUploadUrl`/`tokenUploadApiKey` at your push server, and keep
`requestNotificationPermissionOnStart = false` for any game with a consent flow — the prompt
timing stays under your control (step 5c).

## 5. Code

### 5a. Register an `IFirebaseMessagingListener` (before `Initialize()`)

Push callbacks arrive through this listener. Register it like other Apollo listeners — the class
needs a public parameterless constructor:

```csharp
public class MyFirebaseMessagingListener : IFirebaseMessagingListener
{
    public void OnFcmTokenReceived(string token) { /* token issued/rotated */ }
    public void OnMessageReceived(FirebaseRemoteMessage message) { /* foreground / data message */ }
    public void OnMessageOpened(FirebaseRemoteMessage message) { /* user tapped a notification */ }
}

// BEFORE BFGUnitySDK.Initialize():
BFGUnitySDK.RegisterListener<MyFirebaseMessagingListener>();
BFGUnitySDK.Initialize();
```

Notification taps (cold start and warm background) are handled by the SDK and delivered as
`OnMessageOpened` — no extra game code. See `FIREBASE_DESIGN.md` for the delivery rules.

### 5b. GDPR consent → Analytics

Analytics collection is **off by default and consent-gated** (Crashlytics is not).

- **Using Apollo's built-in consent dialog** (see `CONSENT_INTEGRATION_GUIDE.md`): nothing to do —
  the dialog calls `SetFirebaseDataCollectionConsent` automatically on accept/decline.
- **Game runs its own consent UI**: call this after the GDPR decision resolves (persisted across
  sessions; gates Analytics only):

```csharp
BFGUnitySDK.SetFirebaseDataCollectionConsent(accepted);
```

Analytics events logged before consent are dropped (and logged as such).

### 5c. Request the notification permission at the right moment

```csharp
BFGUnitySDK.RequestNotificationPermission();
```

Call it exactly when the OS push prompt should appear — **after** your GDPR → ATT flow on iOS,
after GDPR on Android. On iOS, every messaging API is inert on a fresh install (null token,
topic/token no-ops) until this call. On Android the token flows from init regardless; the call
shows the Android 13+ `POST_NOTIFICATIONS` prompt (requires the manifest entry from step 7).

### 5d. Feature APIs (once running)

```csharp
BFGUnitySDK.LogFirebaseEvent("level_complete", new Dictionary<string, object> { { "level", 7L } });
BFGUnitySDK.SetFirebaseUserProperty("favorite_mode", "endless");
BFGUnitySDK.LogCrashlyticsMessage("Entered shop screen");
BFGUnitySDK.RecordCrashlyticsException(new Exception("handled"));
BFGUnitySDK.GetFcmToken(token => Debug.Log(token));
BFGUnitySDK.SubscribeToFcmTopic("promotions");
```

Full surface: [API Reference → Firebase](../Apollo_Documentation.md#firebase).

## 6. iOS export steps (apply on every export)

Unity's export is not push-ready; apply these with a `[PostProcessBuild]` script so they never get
missed. **Copy the reference implementation:**
`GalaxyGems/Assets/Scripts/Editor/iOSPostProcessBuild.cs` (it automates 1–3 below plus the dev
conveniences in step 11).

1. **Push Notifications entitlement** — add `aps-environment` via
   `ProjectCapabilityManager.AddPushNotifications(...)` (`development` for Xcode/dev-signed builds,
   `production` for TestFlight / App Store).
2. **`UIBackgroundModes` → `remote-notification`** in `Info.plist` — iOS only delivers
   background/data-only pushes to apps declaring this mode.
3. **Flip `UNITY_USES_REMOTE_NOTIFICATIONS` from 0 to 1 in the exported
   `Classes/Preprocessor.h`** — critical and non-obvious. Unity writes it as `0` because the
   entitlement is added *post*-export, which compiles out `UnityAppController`'s
   remote-notification handlers. **Symptom when missed:** everything looks healthy — permission
   granted, token issued and uploaded, the native Firebase layer even receives the push — but
   data-only messages silently never reach the C# `OnMessageReceived`.
4. **`FIREBASE_ANALYTICS_COLLECTION_ENABLED = false`** in `Info.plist` — prevents Analytics from
   auto-collecting in the window between app launch and Apollo applying the consent state.
5. **Crashlytics dSYM upload** — ensure it is configured so crash reports are symbolicated.

> **Do NOT set `FirebaseCrashlyticsCollectionEnabled = false`** (or the Android equivalent in
> step 7). Crashlytics is intentionally not consent-gated; disabling it at startup would kill
> launch-time crash coverage.

## 7. Android steps

1. **`POST_NOTIFICATIONS` permission** — neither Unity nor the Firebase Unity SDK adds it. In your
   custom `Assets/Plugins/Android/AndroidManifest.xml`:

   ```xml
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
   ```

   Without it, notifications never display on Android 13+ (API 33+).
2. **Launcher activity = `com.google.firebase.MessagingUnityPlayerActivity`** — required for
   notification taps (backgrounded/killed app) to reach `OnMessageOpened`. Generate
   `MessagingUnityPlayerActivity.java` with the Firebase Unity SDK's
   `FirebaseMessagingActivityGenerator` editor script, **commit it** to
   `Assets/Plugins/Android/`, and make it the MAIN/LAUNCHER activity in your manifest (with the
   `unityplayer.UnityActivity = "true"` meta-data).
3. **Player Settings → Application Entry Point = Activity** (not GameActivity) — required by
   step 2.
4. **GDPR startup flags** — in the manifest `<application>` block, so Analytics never
   auto-collects before the consent state is applied:

   ```xml
   <meta-data android:name="firebase_analytics_collection_enabled" android:value="false" />
   <meta-data android:name="google_analytics_default_allow_analytics_storage" android:value="false" />
   ```

   Do **not** add `firebase_crashlytics_collection_enabled=false` (see the warning in step 6).

## 8. Verbose Firebase debug information (optional)

Development-time switches for watching Analytics activity. Two independent mechanisms per
platform: **DebugView** (events upload to the Firebase console immediately, flagged as debug
traffic) and **verbose local logging** (event activity in the device log).

### Android

- **DebugView** — `adb shell setprop debug.firebase.analytics.app <package>` puts the app in
  Analytics debug mode: event batching is disabled and events are uploaded immediately as debug
  traffic, so they appear in the console's **DebugView** in near real time (and are excluded from
  production reporting). It has no effect on logcat output. Turn it off with
  `adb shell setprop debug.firebase.analytics.app .none.`.
- **Verbose logcat** — two properties, because Analytics runs in two processes:

  ```
  adb shell setprop log.tag.FA VERBOSE
  adb shell setprop log.tag.FA-SVC VERBOSE
  ```

  `FA` is the Analytics code inside the app process; `FA-SVC` is the measurement service inside
  Google Play services. With both set, `adb logcat -s FA FA-SVC` shows every event recorded,
  parameter validation warnings, and upload scheduling. No effect on DebugView or upload timing.
- **Persistence** — these properties survive USB disconnect/reconnect (no need to re-run after
  unplugging the device), but they are cleared on device **reboot** — re-run all three after every
  reboot.

### iOS

Both are launch arguments added to the Xcode **Run scheme** (Product → Scheme → Edit Scheme →
Arguments Passed On Launch). They only apply to launches from Xcode; home-screen launches ignore
scheme arguments.

- **DebugView** — `-FIRDebugEnabled` enables Analytics debug mode (immediate debug-flagged
  uploads → DebugView) plus verbose Firebase/FCM/APNs logging. Note it **persists across
  launches** until you explicitly run once with `-FIRDebugDisabled`.
- **Verbose Analytics logging** — `-FIRAnalyticsDebugEnabled` is the closest equivalent of the
  Android `log.tag.FA*` properties: verbose Analytics event/validation logging in the Xcode
  console without changing upload behavior.

## 9. Verify the integration

On a device (fresh install where noted):

1. **Init** — device logs show Firebase initializing successfully at Apollo startup (no
   dependency-check failure).
2. **Consent gating** — before consent, `LogFirebaseEvent` calls log as dropped; after
   accepting, Analytics collection is enabled.
3. **FCM token** — `OnFcmTokenReceived` fires and (if `tokenUploadUrl` is set) the upload POST
   succeeds. **Two uploads on a fresh iOS install are expected** — the token rotates once APNs
   registration completes; the latest token wins.
4. **Foreground message** — a send to the device's token reaches `OnMessageReceived` while the
   app is foregrounded.
5. **Notification tap** — with the app backgrounded and then killed, tapping a notification fires
   `OnMessageOpened` once in each case.
6. **Analytics** — events appear in Firebase console **DebugView** (enable debug mode per
   platform as described in step 8).
7. **Crashlytics** — force a test crash, relaunch, and confirm the (symbolicated) report in the
   Crashlytics console.

## 10. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| FCM accepts sends (returns message id) but iOS devices never receive | APNs Auth Key (.p8) not uploaded in Firebase Cloud Messaging settings (§3.2) |
| Data-only push never reaches `OnMessageReceived` on iOS (native logs show it arriving) | `UNITY_USES_REMOTE_NOTIFICATIONS` still 0 in the exported `Classes/Preprocessor.h` (§6.3) |
| Android 13+ notifications don't display | `POST_NOTIFICATIONS` missing from the manifest (§7.1) |
| Notification tap doesn't fire `OnMessageOpened` on Android | Launcher activity is not `MessagingUnityPlayerActivity`, or Application Entry Point is GameActivity (§7.2–7.3) |
| Analytics events missing from DebugView/console | Consent never granted — `SetFirebaseDataCollectionConsent(true)` not reached (§5b) |
| `NotificationTitle`/`NotificationBody` null in `OnMessageOpened` on Android | FCM platform behavior (the tap intent strips the notification block) — put anything needed on open into the `data` payload |
| EDM4U Android resolution failures | Enable **Custom Gradle Properties Template** in Player Settings so EDM4U can write the AndroidX/Jetifier properties, then re-resolve |

## 11. Dev-only notes (do not ship enabled)

- **Plain-HTTP token upload to a local console** — `UnityWebRequest` blocks `http://` by default:
  set **Player Settings → Allow downloads over HTTP → Allowed in development builds**. Over USB run
  `adb reverse tcp:8080 tcp:8080` and point `tokenUploadUrl` at
  `http://localhost:8080/api/tokens` (re-run after every unplug/reboot), or use the host's LAN IP.
- **iOS ATS local-network exception** — for the same LAN-HTTP upload on iOS, add
  `NSAppTransportSecurity → NSAllowsLocalNetworking = true` plus an
  `NSLocalNetworkUsageDescription` string to `Info.plist`.
