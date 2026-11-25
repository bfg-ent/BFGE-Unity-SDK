# Unity (Apollo) SDK Firebase Integration Guide (Analytics, Crashlytics, FCM Push)

Step-by-step integration of the Unity (Apollo) SDK's Firebase features into a game consuming the prebuilt
`bfg.apollo` package. This guide covers **what you must do**; for how the features behave (GDPR
consent via Firebase Consent Mode, token lifecycle, notification-open handling, edge cases), see
`FIREBASE_DESIGN.md`.
For the full API surface, see the [API Reference](../Apollo_Documentation.md).

The shipped Apollo DLLs already contain the Firebase integration — you do **not** set any scripting
define or rebuild anything. Your game's job is: import the Firebase Unity SDK, add the per-app
config files, create one settings asset, register one listener, and make two calls at the right
moments.

---

## Upgrading: Firebase Consent Mode (action required)

Apollo now applies the GDPR decision to Firebase Analytics through Google's **Consent Mode**
(`FirebaseAnalytics.SetConsent`) instead of the collection kill switch. This matches the native BFG
Android 8.16.0 / iOS 8.14.0 SDKs and the legacy Unity SDK 10.16.0. **Why:** the kill switch
(`firebase_analytics_collection_enabled` / `FIREBASE_ANALYTICS_COLLECTION_ENABLED` = false) shuts the
Firebase SDK down at launch. It then never registers its Google Play Billing purchase observer
(~85% of automatic `in_app_purchase` events were lost) and never captures the Play Install Referrer
(Google Ads conversions unattributed). Re-enabling collection after GDPR acceptance recovers neither
for that session.

**Required changes (every game that integrated Firebase with an earlier Apollo):**

1. **Remove the kill switch** everywhere you added it:
   - Android: `<meta-data android:name="firebase_analytics_collection_enabled" android:value="false" />`
     from `Assets/Plugins/Android/AndroidManifest.xml` **and** any custom `LauncherManifest.xml`.
   - iOS: any `FIREBASE_ANALYTICS_COLLECTION_ENABLED` write in your own `Info.plist` post-process
     script.
2. **Remove** `<meta-data android:name="google_analytics_default_allow_analytics_storage" android:value="false" />`,
   which the previous version of this guide told Android games to add.
3. **Add nothing.** Apollo's editor build processors (shipped in the package's `Editor/` folder) write
   the four Consent Mode defaults into every build. They also strip leftover kill-switch entries, with
   a warning in the Unity console:

   | Android `<application>` meta-data | iOS `Info.plist` key | Value |
   |---|---|---|
   | `google_analytics_default_allow_analytics_storage` | `GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE` | `true` (Boolean YES) |
   | `google_analytics_default_allow_ad_storage` | `GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE` | `true` (Boolean YES) |
   | `google_analytics_default_allow_ad_user_data` | `GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_USER_DATA` | `eu_consent_policy` (String) |
   | `google_analytics_default_allow_ad_personalization_signals` | `GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS` | `eu_consent_policy` (String) |

   `eu_consent_policy` = denied by default only for users in EEA regions (Google determines the
   region). The processors run at `callbackOrder` 999. A post-process of yours ordered **above 999**
   that still writes the kill switch runs after them and re-breaks Firebase, so don't write it in any
   post-process.
4. **Firebase Unity SDK 11.6.0 or later** (required for `FirebaseAnalytics.SetConsent`).
5. **Custom `IFirebaseAdapter` only** (most games don't have one): map the consent bool to
   `SetConsent` yourself. `true` → `analytics_storage`, `ad_storage`, `ad_user_data` and
   `ad_personalization` all granted. `false` → only `ad_user_data` and `ad_personalization` denied.
   Also call `FirebaseAnalytics.SetAnalyticsCollectionEnabled(true)` once per launch. The build
   processors only fix the manifest/plist.

No game code changes otherwise: `BFGUnitySDK.SetFirebaseDataCollectionConsent(bool)` is still the one
consent call.

**Behavior changes to expect:**

- A declining EU user keeps analytics measurement with `ad_user_data` / `ad_personalization`
  denied. Previously Analytics was fully off.
- `LogFirebaseEvent` is no longer dropped before consent. Events flow from launch, with the ad
  signals denied until acceptance.
- Installs that declined GDPR under an older Apollo come back with Analytics alive. Apollo clears
  the persisted kill switch at every launch.
- A game shipping Firebase **without** `Resources/ApolloConsentConfig.json` (Apollo's consent system
  disabled) previously had Analytics off forever. It now collects with the ad signals denied.

## 1. Import the Firebase Unity SDK + EDM4U (tarballs)

Firebase is not published to a public UPM registry, and the Apollo package deliberately declares
**no** Firebase UPM dependencies — each game imports Firebase itself. The precompiled
`Bfg.Apollo.dll` only *references* Firebase; without these packages present its Firebase features
are a logged no-op. **Minimum Firebase Unity SDK: 11.6.0** (Apollo's Consent Mode integration calls
`FirebaseAnalytics.SetConsent`; Apollo itself is built against 13.13.0).

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

### 5b. GDPR consent → Analytics Consent Mode

Apollo pushes the GDPR decision into Firebase **Consent Mode** (Crashlytics is not consent-gated).
Accepted (or GDPR not applicable) → `analytics_storage`, `ad_storage`, `ad_user_data` and
`ad_personalization` all granted. Declined or not yet answered → `ad_user_data` and
`ad_personalization` denied; the storage signals keep their granted defaults.

- **Using Apollo's built-in consent dialog** (see `CONSENT_INTEGRATION_GUIDE.md`): nothing to do.
  The dialog calls `SetFirebaseDataCollectionConsent` automatically on accept/decline (and on
  auto-opt-in when GDPR does not apply, and from `EnableTargetedAdvertising`).
- **Game runs its own consent UI**: call this after the GDPR decision resolves (persisted across
  sessions; affects Analytics only):

```csharp
BFGUnitySDK.SetFirebaseDataCollectionConsent(accepted);
```

Analytics events are **not** held back before consent. `LogFirebaseEvent` works from launch, with
the ad signals denied until the user accepts.

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
conveniences in step 11). Apollo's own `ApolloIosBuildProcessor` now covers the `Info.plist`
consent keys (step 4). If your copy still writes `FIREBASE_ANALYTICS_COLLECTION_ENABLED`, **delete
that write** — a game post-process must not write the kill switch.

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
4. **Consent Mode defaults: automatic, nothing to add.** Apollo's `ApolloIosBuildProcessor`
   (`callbackOrder` 999) writes the four `GOOGLE_ANALYTICS_DEFAULT_ALLOW_*` keys into the exported
   `Info.plist` (see the table in *Upgrading* above) and removes `FIREBASE_ANALYTICS_COLLECTION_ENABLED`.
   **Do not set `FIREBASE_ANALYTICS_COLLECTION_ENABLED`** in any post-process: it shuts Firebase down
   at launch. To override a default, set that key yourself; Apollo keeps your value (except
   `GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE = NO`, which it rewrites to YES as legacy
   guidance).
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
4. **Consent Mode defaults: automatic, nothing to add.** Apollo's `ApolloAndroidBuildProcessor`
   (`callbackOrder` 999) edits the generated `unityLibrary/src/main/AndroidManifest.xml`. If you use a
   custom `LauncherManifest.xml`, it also edits `launcher/src/main/AndroidManifest.xml`. It removes
   `firebase_analytics_collection_enabled` and adds whichever of these are missing:

   ```xml
   <meta-data android:name="google_analytics_default_allow_analytics_storage" android:value="true" />
   <meta-data android:name="google_analytics_default_allow_ad_storage" android:value="true" />
   <meta-data android:name="google_analytics_default_allow_ad_user_data" android:value="eu_consent_policy" />
   <meta-data android:name="google_analytics_default_allow_ad_personalization_signals" android:value="eu_consent_policy" />
   ```

   **Do not add `firebase_analytics_collection_enabled`** to your `AndroidManifest.xml` or
   `LauncherManifest.xml`: it shuts Firebase down at launch. To override a default, declare that key
   yourself; Apollo keeps your value and doesn't duplicate it (except
   `google_analytics_default_allow_analytics_storage="false"`, which it rewrites to `true` as legacy
   guidance). Do **not** add `firebase_crashlytics_collection_enabled=false` either (see the warning
   in step 6).

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
2. **Consent Mode states** — fresh install with verbose Firebase logging on (Android:
   `adb shell setprop log.tag.FA VERBOSE` and `adb shell setprop log.tag.FA-SVC VERBOSE`; iOS: the
   `-FIRDebugEnabled` launch argument; see step 8):
   - Firebase initializes at launch (no "collection disabled" shutdown) and logs the four consent
     defaults.
   - **Accept** GDPR → all four consent types `GRANTED`.
   - **Decline** → `ad_user_data` / `ad_personalization` `DENIED`, while `LogFirebaseEvent` events
     keep appearing in DebugView.
   - With `verboseDebugLogging` on, Apollo also logs each change as
     `[Apollo.Firebase] Consent Mode: …`.
   - Also inspect the exported `Info.plist` / merged Android manifest. It should have the four
     defaults and no `FIREBASE_ANALYTICS_COLLECTION_ENABLED` / `firebase_analytics_collection_enabled`.
   - **Games with Play Billing / StoreKit purchases:** a sandbox purchase made in the same session
     as GDPR acceptance logs `in_app_purchase` exactly once in DebugView. Apollo sends no purchase
     events to Firebase; Firebase auto-collects them.
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
| Analytics events missing from DebugView/console | Debug mode not enabled (§8), `enableAnalytics` off (§4), or Firebase shut down at launch by the kill switch (next row). Consent does not hold events back (§5b). |
| Firebase shut down at launch (logs show Analytics collection disabled) | The kill switch is still in the merged manifest / exported `Info.plist`. Check for a game post-process ordered above 999 that writes `FIREBASE_ANALYTICS_COLLECTION_ENABLED` / `firebase_analytics_collection_enabled`, and remove it (*Upgrading*, §6.4, §7.4) |
| `in_app_purchase` missing or under-counted | The kill switch is still in the merged manifest / `Info.plist`, so Firebase never registered its purchase observer at launch. Same fix as the row above |
| Unity console shows Apollo build warnings about removing the kill switch or rewriting `analytics_storage` | The build output is already fixed, but your manifest / post-process still carries the legacy entries. Remove them (*Upgrading*) |
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
