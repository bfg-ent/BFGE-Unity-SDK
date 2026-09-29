# Design: GTS Telemetry for the Unity (Apollo) SDK

**Scope:** Game Telemetry Service (GTS) event assembly and delivery — automatic lifecycle events, custom events, purchase events, error events, and the networking queue that carries them
**Companion document:** `GTS_INTEGRATION_GUIDE.md` — the steps to get the feature working. This document describes *how the feature behaves* — for testers and developers who need the full picture, including edge cases. Setup instructions are deliberately absent here.

## Contents

- [1. Purpose & scope](#1-purpose--scope)
- [2. Overall design](#2-overall-design)
  - [2.1 Pipeline](#21-pipeline)
  - [2.2 Lifecycle & ordering](#22-lifecycle--ordering)
  - [2.3 Endpoint routing — `ApolloNetworkConfig.json`](#23-endpoint-routing--apollonetworkconfigjson)
  - [2.4 `ITelemetryListener`](#24-itelemetrylistener)
- [3. Event catalog](#3-event-catalog)
  - [3.1 Automatic session lifecycle](#31-automatic-session-lifecycle)
  - [3.2 Install](#32-install)
  - [3.3 First-launch attribution deferral](#33-first-launch-attribution-deferral)
  - [3.4 Purchase events](#34-purchase-events)
  - [3.5 Custom events](#35-custom-events)
  - [3.6 policyError (internal — consent subsystem)](#36-policyerror-internal--consent-subsystem)
- [4. Payload assembly (`GtsInfoProvider`)](#4-payload-assembly-gtsinfoprovider)
  - [4.1 Standard `p` block](#41-standard-p-block)
  - [4.2 App User ID (`apuid`)](#42-app-user-id-apuid)
  - [4.3 `bfgudid`](#43-bfgudid)
  - [4.4 Device block (`dvi`)](#44-device-block-dvi)
  - [4.5 `pe` and `tpte` (both platform blocks)](#45-pe-and-tpte-both-platform-blocks)
- [5. Delivery guarantees (`NetworkingController` + `OutboundMessageQueue`)](#5-delivery-guarantees-networkingcontroller--outboundmessagequeue)
  - [5.1 Send timing](#51-send-timing)
  - [5.2 Retry semantics](#52-retry-semantics)
  - [5.3 Disk persistence](#53-disk-persistence)
  - [5.4 Queue cap](#54-queue-cap)
  - [5.5 Traffic inspection](#55-traffic-inspection)
- [6. Configuration](#6-configuration)
  - [6.1 `BfgSettings.asset` (`GameInfos`)](#61-bfgsettingsasset-gameinfos)
  - [6.2 Other files](#62-other-files)
- [7. Cross-cutting behaviors / good to know](#7-cross-cutting-behaviors--good-to-know)
- [8. Design decisions & rationale](#8-design-decisions--rationale)
- [9. Reference](#9-reference)

## 1. Purpose & scope

GTS is Big Fish's server-side game telemetry service. The Unity (Apollo) SDK owns the client half end-to-end: it decides *when* the standard events fire (install, session start/end are fully automatic), *assembles* every event payload (device info, session ids, auth state, consent flags, attribution id — game code supplies none of this), and *delivers* them through a disk-persisted outbound queue with retry semantics. Game code touches telemetry in exactly four places: `SendCustomEvent`, the two purchase-reporting calls, and the identity setters (`SetAppUserId` / `SetAttributionID`).

**Non-goals / exclusions:**

- **No Firebase Analytics mirroring.** GTS events and Firebase Analytics events are entirely separate pipelines; nothing is auto-forwarded in either direction (see `FIREBASE_DESIGN.md` §1). The one shared piece is the `BfgUdid` device id (§4.3).
- **No attribution events.** Apollo carries the attribution *id* (`afid` on every event, via `SetAttributionID`) but has no attribution event API — the old `SendAttributionEvent` no-op was removed in the 2026-08 cleanup.
- **Apollo does not decide consent.** The `tpte` and `aptts` fields *reflect* decisions made by the consent subsystem (GDPR dialog / game override / ATT prompt — see `CONSENT_DESIGN.md`); the telemetry code only reads the persisted flags at event-build time (§4.4, §4.5).

## 2. Overall design

### 2.1 Pipeline

```
BFGUnitySDK (static facade)
  → Bootstrap                         (routing + "is SDK started" guards)
    → TelemetryController             (event timing, session/identity state, lifecycle hooks)
      → GtsTelemetryAdapter           (event-name constants, MessageType selection, JSON encode)
        → GtsInfoProvider             (payload assembly — every field on every event)
          → NetworkingController      (URL routing, api key, retries)
            → OutboundMessageQueue    (in-memory + disk-persisted queue)
              → HTTP POST             (UnityWebRequest, JSON body)
```

- `GtsTelemetryAdapter` is the **only** `ITelemetryAdapter` implementation. The interface is `internal` — game teams cannot implement or replace it (unlike the game-facing adapter seams for auth/purchasing).
- `GtsInfoProvider` (extends `BaseSystemInfoProvider`, which owns the native-util platform switch and caching) builds the complete payload. `TelemetryController` passes it the per-event state (session ids, auth snapshot, app user id, attribution id); everything else is read from the device, config, or PlayerPrefs at build time.
- Every event is serialized with Newtonsoft.Json (`NewtonsoftEncoderAdapter`) using `NullValueHandling.Ignore` — **null fields are omitted from the wire payload entirely** (this is why Editor events have no `ios`/`android` block at all, §7).

### 2.2 Lifecycle & ordering

- `TelemetryController` is **always constructed** by `Bootstrap` (unlike purchasing/auth/Firebase, which are conditional). It implements `ILifecycleHandler` and registers with the `UnityLifecycleDaemon` during `Initialize`.
- The daemon does not start monitoring until `TelemetryController.Start()` runs (during `StartSDK`, after all components initialize). **`Start()` generates the persistent App User ID GUID (if missing) *before* starting the daemon** — the daemon's `LifecycleMonitor` fires the first `OnApplicationResume` synchronously from its `Initialize`, which produces install/sessionStart, so this ordering is load-bearing (issue #19): reversed, the first events of every fresh install would carry an empty `apuid`.
- Auth state on events comes from an `IAuthenticationTelemetryDataProvider` that `AuthenticationController` registers during its `Initialize`. Every `Log*` method except `LogPolicyError` **drops the event with a console warning** when no provider is registered ("Authentication system not initialized…"). Since authentication is mandatory for SDK init, in practice the provider is always there; `LogPolicyError` alone sends anyway with an empty auth snapshot, because a compliance error record must not silently vanish (§3.6).

### 2.3 Endpoint routing — `ApolloNetworkConfig.json`

`NetworkingController` loads `Resources/ApolloNetworkConfig.json` at init: a list of `{MessageType, UrlRoot, Version, AppendProductVersionSuffix}` entries (game-facing file reference:
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → ApolloNetworkConfig.json](APOLLO_SDK_INTEGRATION_GUIDE.md#apollonetworkconfigjson--network-endpoints)). For GTS entries (`AppendProductVersionSuffix` defaults true) the outbound URL is:

```
{UrlRoot}{eventType}/{Application.productName}{Version}
e.g.  https://test.mobile.bigfishgames.com/events/sessionStart/MyGame/2.2.0
```

where `{eventType}` is the message's `Subdirectories` field — the GTS event-type string (`install`, `sessionStart`, `sessionEnd`, `purchase`, `error`, `custom`). If `BfgSettings.asset` provides a `TelemetryKey`, it is sent as an `x-api-key` header on every POST.

The `MessageType` enum (`Core/Networking/NetworkMessage/MessageType.cs`) is the routing key. **Values are positional and persisted** (they are stored as ints in the JSON config *and* in the on-disk queue file) — never reorder or renumber:

| Value | Member | Routed? | Notes |
|---|---|---|---|
| 0 | `Install` | yes | |
| 1 | `SessionStart` | yes | |
| 2 | `SessionEnd` | yes | |
| 3 | `PurchaseSuccess` | yes | |
| 4 | `CustomEvent` | yes | |
| 5 | `BFGCustomEvent` | **no** | Enum member kept only so 6–8 keep their positions; its routing entry was removed in the 2026-08 cleanup because nothing ever dispatched it. A message of this type would fail with "message type does not have a target URL". |
| 6 | `Error` | yes | Carries both `purchase-error` and `policyError` payloads. |
| 7 | `InternetConnectionCheck` | n/a | Used by `UnityPingService` only, which bypasses the config with a hardcoded GET to `https://www.google.com` (5 s timeout) — it never needs a routing entry. |
| 8 | `PolicyEvent` | yes | Consent-tracking reports (shown/accepted/declined) — a consent-subsystem route (`AppendProductVersionSuffix: false`, different host); listed here for completeness, see `CONSENT_DESIGN.md` §3.4. |

**Good to know:**

- **Environment switching is done entirely by editing `UrlRoot`** in this file: test = `https://test.mobile.bigfishgames.com/events/`, production = `https://mobile.bigfishgames.com/events/`. There is no environment field in the GTS payload itself — `BaseSystemInfoProvider` still declares a `ENVIRONMENT = "test"` constant, but nothing reads it (the `environment` field on *consent tracking* events is a separate mechanism fed by `BfgConsent.asset`).
- The product name in the URL is `Application.productName` — a renamed Unity product changes the endpoint path.

### 2.4 `ITelemetryListener`

The one game-facing telemetry listener: `OnTelemetrySent(bool success, string message)` fires once per event when the network layer resolves it (success, or terminal failure after retries; `message` is the message-status string, e.g. `"Complete"`). Registered via `BFGUnitySDK.RegisterListener<T>()` before `Initialize()`, public parameterless constructor required.

**Sharp edge (verified in code, worth a runtime test):** `GtsTelemetryAdapter.DispatchMessage` passes `_telemetryListener.OnTelemetrySent` as the callback with **no null guard** — if no `ITelemetryListener` was registered, `Bootstrap` constructs `TelemetryController` with a null listener and the first event dispatch (the automatic install/sessionStart at SDK start) will throw a `NullReferenceException` creating that delegate. Treat registering an `ITelemetryListener` as effectively required (the sample registers `BasicTelemetryListener`).

Callbacks are not persisted: the delegate is `[NonSerialized]`, so events restored from disk after a relaunch (§5.3) complete without any listener callback.

## 3. Event catalog

| Event | `et` (payload) | `d.en` | `MessageType` | Trigger |
|---|---|---|---|---|
| Install | `install` | — | `Install` | First launch ever, once per install (§3.2) |
| Session start | `sessionStart` | — | `SessionStart` | Automatic, every foreground (§3.1) |
| Session end | `sessionEnd` | — | `SessionEnd` | Automatic, every background (§3.1) |
| Purchase | `purchase` | — | `PurchaseSuccess` | `BFGUnitySDK.SendPurchasingSuccessEvent` (§3.4) |
| Purchase error | `error` | `purchase-error` | `Error` | `BFGUnitySDK.SendPurchasingFailureEvent` (§3.4) |
| Policy error | `error` | `policyError` | `Error` | Consent subsystem, internal (§3.6) |
| Custom | `custom` | game-supplied | `CustomEvent` | `BFGUnitySDK.SendCustomEvent<T>` (§3.5) |

There is no other event; nothing else in the SDK dispatches to GTS. (Rewarded-video logging was removed in the 2026-08 cleanup — it never worked.)

Definitions for game telemetry payload keys can be found at
https://cdn-content.bigfishgames.com/gts/schemas/events/standard/common/2.2.0/payload.json.

### 3.1 Automatic session lifecycle

`TelemetryController` is driven by `UnityLifecycleDaemon`, which forwards Unity's `OnApplicationPause(bool)` — **no game code is involved**:

- **Foreground (`OnApplicationResume`)** — also fired synchronously at SDK start: a new **Session ID** is generated (32-hex GUID, `"N"` format) *every* foreground; a new **Play Session ID** is generated only when the app was backgrounded for more than **30 seconds** (`MIN_BACKGROUND_TIME_FOR_NEW_SESSION`) *or* the previous session never recorded an end time (kill/crash — the end-time key is reset to `0` on every resume, so a dead app always starts a fresh play session next launch). Then install-check + `sessionStart` fire (subject to the first-launch deferral, §3.3).
- **Background (`OnApplicationPause`)**: the pause timestamp is persisted (`BFG.Apollo.Telemetry.SessionEndTime`) and `sessionEnd` fires.

**Session-type semantics (testers ask about these):**

- `sessionStart` carries `sst` = `"launch"` for the first foreground of the process, `"resume"` for every later one. The `deep_link` / `push_notification` / `local_notification` constants exist in code but are **never produced** — no code path assigns them.
- `sessionEnd` carries `set` = `"FAS"` always (the `rate`/`notification`/`gamefinder` constants are likewise never produced), plus `ssts`/`sets` timestamps and `sd` (duration in seconds, computed from the persisted session-start time `BFG.Apollo.Telemetry.SessionStartTime`).
- Session Start also **refreshes the Android advertising info** (`RefreshAdInfo` → invalidates the native ad-info cache), so `adid`/`ade` are re-read from the OS once per session (launch and every resume) rather than once per process.

**Good to know:** both session ids live in PlayerPrefs, so *every* event between two foregrounds — including sessionEnd — carries the same `sid`/`psid` pair, and a `sid` is already present for events fired before the very first sessionStart of a launch dispatches (e.g. a held first-launch install, §3.3). A quick backgrounding (< 30 s) produces a full sessionEnd + sessionStart pair with a *new* `sid` but the *same* `psid` — that is the entire distinction between the two ids.

### 3.2 Install

Fired at most once per install: `CheckForInstall` reads PlayerPrefs `BFG.Apollo.Telemetry.InstallKey` (0/1) and, when 0, writes 1 and logs the event. The key is written **at dispatch time, inside the flush** — not when the first-launch deferral (§3.3) is armed — so a deferral that never flushes (process killed inside the 5-second window before any pause) leaves the key unset and the install fires on the next launch instead of being lost. Reinstalling the app clears PlayerPrefs, so a reinstall produces a new install event (this matches the field's meaning; `bfgudid` is what survives reinstalls, §4.3).

### 3.3 First-launch attribution deferral

The attribution id (`afid`) is game-supplied via `SetAttributionID`, and the game's attribution SDK (AppsFlyer) typically resolves *after* Apollo starts. To keep `afid` populated on the two highest-value events:

- On the **first launch only** (install key unset **and** no stored attribution id), install + sessionStart are **held**: `_startEventsPending` is set and a 5-second real-time fallback (`START_EVENT_ATTRIBUTION_WAIT_SECONDS`) is scheduled.
- The pending pair flushes on whichever comes first: `SetAttributionID(...)`, the 5-second timeout, an app **pause** (so a sessionEnd can never precede a still-pending install/sessionStart), or an app **resume** (so the pending events go out with the session state they were built for, before it is rewritten). The flush is idempotent — a flag guards double-fires.
- On every later launch the condition can't re-arm (install key set, and usually a stored `afid` too), so start events fire immediately.

**Good to know:**

- The deferral covers **only** install/sessionStart. Any *other* event fired before `SetAttributionID` — on first launch or any launch where the game sets a new id late — carries whatever `afid` is currently stored (empty string on a true first launch; the *previous* launch's value otherwise, since `afid` persists in PlayerPrefs).
- A custom event sent during the deferral window is **not** held — it can reach the server timestamped before that session's install/sessionStart.
- `SetAttributionID` is deliberately **not** gated on "SDK started" (unlike `SendCustomEvent`) so an attribution callback landing mid-initialization still flushes the pending pair early. It must still come after `BFGUnitySDK.Initialize()` — earlier and the controller doesn't exist yet (NRE).

### 3.4 Purchase events

Game-reported via `SendPurchasingSuccessEvent(PurchaseSuccessData)` / `SendPurchasingFailureEvent(PurchaseFailureData)` (both `_isStarted`-gated: a warning log + drop before StartSDK completes).

- **Success** → `et: "purchase"`. Payload (`d`): `rst` (restore 0/1), `pr` (price parsed to double; unparsable price string → `0.0`), `prstr` (the raw price string), `cur`, `pid`, `txid`, `txts`, and `rh` — a SHA-1 hash of `uniqueReceiptID` (never the raw receipt; a null receipt id hashes the literal `"unknown"`).
- **Failure** → `et: "error"`, `d.en: "purchase-error"`, `d.ed`: `code` (game's `errorCode`), `purchasePhase` (enum as int), `receiptProductId`. **`PurchaseErrorReason.UserCancelled` is suppressed** — a user-cancelled purchase logs "not sending a purchase error event to GTS" and nothing is dispatched (deliberate: cancellations are not errors; shipped with the `bfsv` 00030000 bump).
- Error-event payload keys are deliberately long-form (not abbreviated) — that is the wire contract for `error` events, matching `policyError`.

### 3.5 Custom events

`SendCustomEvent<T>(string eventName, T data)` where `T : CustomEventData` → `et: "custom"`, `d.en` = `eventName`, `d.ed` = the Newtonsoft-serialized subclass. Field names serialize as written unless the game adds its own `[JsonProperty]` attributes; the `CustomEventData` base class contributes a (usually null, therefore omitted) `eventName` field. The full standard envelope (§4) wraps every custom event — games only supply the `ed` payload and the name.

### 3.6 policyError (internal — consent subsystem)

`TelemetryController.LogPolicyError` is called by `ConsentController` when a consent policy-service check finally fails: `et: "error"`, `d.en: "policyError"` (legacy-verbatim camelCase — the server-side MTS→GTS reporting pipeline matches the exact string), `d.ed`: `phase` / `code` / `message` / `actualError`. Uniquely, it does **not** require the auth data provider (§2.2) and sends with an empty auth snapshot if needed. Which failures produce it, the `BFGConsentManagerError*` code table, the connectivity-code suppression filter, and the once-per-code-per-run gating all live in the consent design — see **`CONSENT_DESIGN.md` §5.4** (issue #58). From the GTS side it is just another `MessageType.Error` POST.

## 4. Payload assembly (`GtsInfoProvider`)

Every event shares one envelope: `{"p": {...}, "d": {...}}` — `p` (`Payload`) is the standard block below, `d` is the per-event data (§3). All property names come from `[JsonProperty]` attributes (Newtonsoft) — the C# names are readable, the wire keys are short.

### 4.1 Standard `p` block

| Key | Source | Notes |
|---|---|---|
| `apsid` | `BfgSettings.asset` → `GameStoreId` | Per-platform block (§6.1) |
| `aupid` / `aupn` / `aus` | Auth snapshot (`AuthTelemetryData`) | The game's auth adapter's `UserID`, provider name, and auth state at event time |
| `apn` | `Application.productName` | Also embedded in the endpoint URL (§2.3) |
| `apuid` | App User ID (§4.2) | |
| `et` | Event type string | §3 table |
| `tsc` | Client timestamp | Unix seconds, UTC |
| `bfgudid` | `BfgUdid.Get()` (§4.3) | |
| `plt` | Platform | `"ios"` / `"android"` / `"desktop"` (Editor) |
| `apv` / `apbv` | `Application.version` / native build number | Build number cached per process |
| `sid` / `psid` | Session / Play-Session ID (§3.1) | |
| `lc` | `CultureInfo.CurrentCulture.Name` | e.g. `en-US` |
| `bfsv` | `SDKVersion.APOLLO_CURRENT_VERSION` | Currently `"00030000"` (v0.3) — the SDK-version wire field |
| `ceid` | New GUID per event | Client event id — unique even across retries of *different* events; retries of the *same* queued message keep their `ceid` |
| `aps` | Store name | `"itunes"` / `"google"` / `"unknown"` (compile-time platform define) |
| `bid` | `Application.identifier` | |
| `dvi` | Device-info block (§4.4) | |

### 4.2 App User ID (`apuid`)

- Auto-generated as a GUID (with dashes) in `TelemetryController.Start()` when missing, persisted in PlayerPrefs `BFG.Apollo.Telemetry.AppUserId` — before the lifecycle daemon fires the first events (§2.2 ordering).
- Games may override it any time after start via `BFGUnitySDK.SetAppUserId` (persisted; all *subsequent* events carry it — events already sent or queued are not rewritten). `GetAppUserId` reads it back. Apollo also copies it to Crashlytics as the crash-report user id at startup (`FIREBASE_DESIGN.md` §4).
- Distinct from `aupid`: `apuid` is Apollo's per-install (or game-assigned) user id; `aupid` is whatever the game's **auth adapter** reports as the signed-in user. The consent-reporting subsystem's `raveId` field (not a GTS payload field) carries that same auth user id under the backend's historical field name — see `CONSENT_DESIGN.md` §3.4.

### 4.3 `bfgudid`

The SDK's stable per-device id (`Core/Utils/BfgUdid.cs`), shared with Firebase FCM token uploads. Resolution order: iOS Keychain `com.apollo.sdk.bfgudid.v2` (survives reinstalls; shared across Apollo apps carrying the shared-keychain entitlement) → PlayerPrefs `BFGUDID.v2` (Android/Editor; promoted to Keychain on iOS when found) → generated legacy-SDK-matching (Android `SHA1(ANDROID_ID + "BFGUDID")`, iOS `SHA1(IDFV)` unsalted — deterministic per device) with a random-GUID fallback. The `.v2` key names are deliberately different from earlier Apollo builds' keys, whose old-derivation values are abandoned (never read) rather than migrated. **Keys, salt, and derivation are load-bearing and must never change going forward** — existing installs would change identity.

### 4.4 Device block (`dvi`)

`dvattr` (all platforms): `pt` processor, `sr` screen resolution (`height x width`), `osi`/`osv` (parsed OS name/version — `iOS`/`iPadOS`/`android`/`mac`/`window`/`unknown`), `dvc` carrier, `dvm` model, `dvb` brand, `dvidm` idiom, and **`afid`** — the attribution id (AppsFlyer id) passed down from `TelemetryController`; empty string until `SetAttributionID` is called (§3.3).

Exactly one platform sub-block is attached at runtime (`Application.platform` switch — **neither** in the Editor, and `NullValueHandling.Ignore` removes the null one from the JSON):

**`ios`:** `gcid` (GameCenterId from config — the only iOS-only config consumer), `ifa`, `ifae`, `idfv`, `aptts`, plus the shared `pe`/`tpte`.

- **`aptts` is OS-seeded once per cold start:** the first event of a launch reads `ATTrackingManager.trackingAuthorizationStatus` natively and writes it through to PlayerPrefs `BFG.Apollo.Policy.ATT`; every later event just reads that key (a per-event native read + `SetInt` would flush PlayerPrefs to disk on every event — issue #25's fix was deliberately narrowed). Settings-app tracking flips always kill the app, so the cold-start read covers them; the **one** legitimate mid-session change — the user answering Apollo's own ATT prompt (`BFGUnitySDK.RequestTrackingAuthorization`) — is written to the same key by `AttAuthorization.HandleResult` and picked up by the next event. See `CONSENT_DESIGN.md` §8.
- **`ifa` is gated by that same cached value:** IDFA is read natively only when `aptts == Authorized (3)`; otherwise `ifa` is the zero UUID `00000000-0000-0000-0000-000000000000` and `ifae` is 0. Because both derive from one read, **`aptts` and `ifa` are always mutually consistent within an event** — testers should never see `aptts: 3` with a zero `ifa` or vice versa.
- `ATTStatus` values are iOS-native-mapped and persisted: `NotDetermined=0, Restricted=1, Denied=2, Authorized=3` — never renumber.

**`android`:** `aid` (ANDROID_ID), `adid` (advertising id), `ade` (advertising enabled), plus `pe`/`tpte`. `adid`/`ade` are re-queried from the OS **once per session start** (§3.1); `ade` comes from the OS limit-ad-tracking state plus a valid non-zero id — never inferred from string emptiness (devices with ads disabled report the zero UUID, which is non-empty; the old inference was the ade-always-1 bug).

### 4.5 `pe` and `tpte` (both platform blocks)

- **`pe` (push enabled) is read-only from the OS** per event — `_IsPushNotificationEnabled()` on iOS, `NotificationManager.areNotificationsEnabled()` via JNI on Android. There is no SDK API to override it; granting/denying the notification permission is what changes it.
- **`tpte` (third-party tracking enabled)** reads PlayerPrefs `BFG.Apollo.Telemetry.ThirdPartyTrackingStatus` (default 0). It is written by `BFGUnitySDK.ApplyThirdPartyTrackingConsentStatus(bool)` — which the consent subsystem calls automatically when the GDPR targeted-advertising policy is answered (dialog decision, `EnableTargetedAdvertising` override, or fail-open auto-opt-in). It is a pure reflection of the GDPR decision: 0 until answered, then 0/1 per the answer, persisted across launches.

**Good to know:** events fired *before* the consent flow resolves on a fresh install legitimately carry `tpte: 0` — including the install/sessionStart pair. That is correct behavior, not a bug.

## 5. Delivery guarantees (`NetworkingController` + `OutboundMessageQueue`)

### 5.1 Send timing

`PostMessage` **adds the message to the queue and attempts the POST immediately** — a healthy event goes out at once, not on a timer. The 60-second timer (`MESSAGE_QUEUE_PROCESSING_INTERVAL = 60000` ms, via `InvokeRepeating` with **zero initial delay**, so the first tick runs at SDK start) is the *retry/drain* mechanism: each tick pings `https://www.google.com` (plus a fast-fail on `Application.internetReachability`) and, only on success, re-sends every message still in `Queued` state — i.e. earlier failures and messages restored from disk. So: first attempt immediate; each retry waits for the next connectivity-gated tick.

### 5.2 Retry semantics

Each message allows **3 transmission attempts** (`MaxTransmissionAttempts`), 30-second HTTP timeout. Result classification (`UnityWebRequestProxy`):

| Outcome | `MessageResult` | Behavior |
|---|---|---|
| 2xx | `Success` | Callback(true), removed from queue |
| HTTP **400** or **301** | `DataError` | **Permanent discard immediately** (bad payload / permanent redirect) — callback(false), removed, no retry |
| 5xx | `ConnectionFailure` | Re-queued until attempts exhausted |
| Other non-2xx (401/403/404/…) | `ProtocolError` | Re-queued until attempts exhausted |
| Transport/connection error | `ConnectionFailure` | Re-queued until attempts exhausted |
| No routing entry for the MessageType | `ProtocolError` | Counted as an attempt (deliberately — an uncounted attempt once made the drain loop spin forever on such a message) and errored through the same path |

After the third failed attempt the message completes as a failure: callback(false), removed. **Nothing distinguishes "gave up" from "server rejected" in the listener callback** beyond `success=false`.

### 5.3 Disk persistence

The queue is persisted to `{Application.persistentDataPath}/BFGQueuedNetworkMessages.dat` via **BinaryFormatter**, saved on every add and every removal pass ("arguably too aggressive" per the code comment, but crash-safe). On SDK init the file is loaded and each restored message gets `ResetStats()` (attempt counter back to 0, result cleared) and `InProgress → Queued` — so events that were mid-flight or had burned retries when the app died get a full fresh retry budget next launch, at the first timer tick. Restored messages have **no callback** (delegates aren't serialized, §2.4). A corrupt/undeserializable file surfaces as an exception at init — there is no try/catch around the BinaryFormatter load.

### 5.4 Queue cap

Capacity is **1000 messages** — `ConfigData.NetworkQueueSize`, hardcoded in `ConfigDataMapper.FromDto` (not game-configurable). At capacity, `AddMessage` **silently evicts the oldest message** (index 0, regardless of its status) to admit the new one — no log, no callback. In practice reaching 1000 means an extended offline period; the trade is deliberate (newest events win).

### 5.5 Traffic inspection

`Resources/BFGAutomationConfiguration.json` (`CharlesEnabled`, `HostIp`, `HostPort`) routes SDK HTTP traffic through a Charles proxy for debugging. Precisely: the proxy address is applied to the `HttpClientAdapter` (the async path — used by consent-report POSTs on non-iOS; on iOS the async path falls back to the synchronous one). The GTS event path uses `UnityWebRequest`, which honors the device/system proxy — so for GTS specifically, device-level Wi-Fi proxy configuration is the reliable interception route, with the JSON config covering the HttpClient traffic. Every event is also logged in full locally (§7), which is usually faster than proxying.

## 6. Configuration

### 6.1 `BfgSettings.asset` (`GameInfos`)

Two blocks, `IosConfiguration` and `AndroidConfiguration`, each a `GameConfiguration` with **exactly three fields** (post-cleanup shape). The authoritative field reference (including which GTS payload field each one feeds) lives in
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → BfgSettings.asset](APOLLO_SDK_INTEGRATION_GUIDE.md#bfgsettingsasset--game-configuration).

`ConfigDataMapper.FromDto` selects the block by runtime platform; **in the Editor the `AndroidConfiguration` block is used**. An unsupported platform throws `ApplicationException` at init. Endpoint URL and version do **not** live here — they come from `ApolloNetworkConfig.json` (§2.3); the old `TelemetryUrl`/`TelemetryVersion` asset fields were dead and are gone.

### 6.2 Other files

- `ApolloNetworkConfig.json` — routing + environment (§2.3; [file reference](APOLLO_SDK_INTEGRATION_GUIDE.md#apollonetworkconfigjson--network-endpoints)).
- `BFGAutomationConfiguration.json` — Charles proxy (§5.5).
- `BfgConsent.asset` — consent-subsystem environment only; no effect on GTS events ([file reference](APOLLO_SDK_INTEGRATION_GUIDE.md#bfgconsentasset--consent-environment)).
- There is no `BfgDebugSettings.asset` anymore (class deleted in the 2026-08 cleanup).

## 7. Cross-cutting behaviors / good to know

- **Logging surface for testers:** every dispatched event logs its complete JSON (`"TELEMETRY JSON IS:"` prefix) via `Debug.Log`, plus per-message network results (`"MSG: OnNetworkMessageResult …"`), queue-removal warnings, and the drain-tick line (`"PROCESSING OUTBOUND QUEUE"`). This is the primary QA observation channel — payload verification rarely needs a proxy.
- **Editor behavior:** `plt: "desktop"`, `aps: "unknown"`, **no `ios`/`android` block at all** (so no `pe`/`tpte`/`aptts`/`ifa`/`adid` fields to inspect in Editor runs), `EditorNativeUtils` stub values elsewhere (push always false, etc.), and the Android config block supplies `apsid`/`TelemetryKey`. Events still POST to the configured endpoints from the Editor.
- **API guards:** `SendCustomEvent`, `SetAppUserId`, and both purchase calls are dropped with a warning before StartSDK completes (`_isStarted`); `SetAttributionID` and `GetAppUserId` are not gated (§3.3 explains why for the former) but require `Initialize()` to have been called at all.
- **Duplicate `afid`:** the attribution id is written into `dvattr.afid` twice during assembly (two code paths set the same property) — harmless, one wire field.
- **Session ids and consent events share lineage:** the consent subsystem stamps its tracking reports with `TelemetryController.GetSessionId()`, so GTS and consent-report traffic for the same session correlate by `sid`.
- **A `MessageResult.Unknown` network result** (unexpected UnityWebRequest state) logs an error and leaves the message `InProgress` — it is stranded for the rest of the process but restored to `Queued` (fresh retries) by the next launch's queue load.

## 8. Design decisions & rationale

| Decision | Choice / rationale |
|---|---|
| Adapter exposure | `ITelemetryAdapter` is internal; GTS assembly is not a game seam. Games get `SendCustomEvent` + purchase reporting + identity setters only. |
| Payload keys | Short `[JsonProperty]` keys on the envelope; **long-form keys inside `error`-event payloads** (`purchase-error`, `policyError`) — legacy wire parity. |
| First-launch start events | Deferred up to 5 s for `SetAttributionID` rather than always-empty or always-blocking — `afid` on install/sessionStart is the highest-value attribution join, and pause/resume flushes preserve event ordering. |
| User-cancelled purchases | Not reported as purchase errors (suppressed in `TelemetryController.LogPurchaseFailure`) — cancellation is user intent, not an error; shipped alongside the `bfsv` 00030000 bump. |
| `aptts` caching | One OS read per cold start + PlayerPrefs read per event, written through by the ATT prompt handler — per-event `SetInt` would flush PlayerPrefs to disk on every event (issue #25). |
| Queue overflow | Silent oldest-first eviction at 1000 — newest events are worth more than the oldest after a long offline stretch. |
| HTTP 400 | Permanent discard — a payload the server rejects as malformed will never succeed; retrying burns quota and reorders nothing. |
| Retry cadence | Immediate first attempt + connectivity-gated 60 s drain — no exponential backoff; the disk queue makes eventual delivery a relaunch concern, not an in-session one. |
| `MessageType` 5 | Enum member kept, routing entry removed — values 6–8 are persisted ints in config and the on-disk queue. |
| Environment | URL-root switching in `ApolloNetworkConfig.json` only; the unused `ENVIRONMENT` const is acknowledged tech debt (TODO in code). |

## 9. Reference

Setup (config files, listener registration, event-sending walkthrough): see **`GTS_INTEGRATION_GUIDE.md`**.

**Public API (`BFGUnitySDK`):**

| API | Notes |
|---|---|
| `SendCustomEvent<T>(string eventName, T customEventData)` | `T : CustomEventData`; started-gated (§3.5) |
| `SendPurchasingSuccessEvent(PurchaseSuccessData)` | §3.4 |
| `SendPurchasingFailureEvent(PurchaseFailureData)` | `UserCancelled` suppressed (§3.4) |
| `SetAppUserId(string)` / `GetAppUserId()` | Overrides/reads the persistent `apuid` (§4.2) |
| `SetAttributionID(string)` | Feeds `afid`; flushes deferred first-launch events; not started-gated (§3.3) |
| `ApplyThirdPartyTrackingConsentStatus(bool)` | Writes the `tpte` flag; normally called by the consent subsystem, not game code (§4.5) |
| `RegisterListener<T>()` | Registers `ITelemetryListener` before `Initialize()` — effectively required (§2.4) |

**PlayerPrefs keys:**

| Key | Meaning |
|---|---|
| `BFG.Apollo.Telemetry.InstallKey` | 1 = install event has dispatched on this install (§3.2) |
| `BFG.Apollo.Telemetry.SessionID` / `.PlaySessionID` | Current `sid` / `psid` (§3.1) |
| `BFG.Apollo.Telemetry.SessionEndTime` / `.SessionStartTime` | Pause timestamp (30 s rule) / session-start timestamp (duration calc) |
| `BFG.Apollo.Telemetry.AppUserId` | `apuid` (§4.2) |
| `BFG.Apollo.Telemetry.AttributionID` | `afid` (§3.3) |
| `BFG.Apollo.Telemetry.ThirdPartyTrackingStatus` | `tpte` flag (§4.5) |
| `BFG.Apollo.Policy.ATT` | Cached ATT status feeding `aptts`/IDFA gating (§4.4) |
| `BFGUDID.v2` | `bfgudid` (Android/Editor home; iOS uses the Keychain — §4.3) |

**Files on device:** `{persistentDataPath}/BFGQueuedNetworkMessages.dat` — the BinaryFormatter-serialized outbound queue (§5.3).

**Code map:** `Core/Telemetry/TelemetryController.cs` (event timing, sessions, identity, deferral), `Core/Telemetry/TelemetryAdapters/GtsTelemetryAdapter/GtsTelemetryAdapter.cs` (event names, MessageType selection), `Core/Telemetry/TelemetryAdapters/BaseSystemInfoProvider.cs` (native-util switch, caches, IDFA gating), `Core/Utils/Unity Utils/UnitySystemInfo/GtsInfoProvider.cs` (payload assembly), `Core/Telemetry/DataObjects/GTS/` (wire schema — `Payload`, `DeviceAttribute`, `Ios`, `Android`, per-event `d` payloads), `Core/Networking/NetworkingController.cs` (routing, retries, 60 s timer), `Core/Networking/OutboundMessageQueue.cs` + `IMessageQueueStore.cs` (queue + disk store), `Networking/UnityWebRequestAdapter/UnityWebRequestProxy.cs` (HTTP result classification), `Core/Utils/BfgUdid.cs`, `Core/SDKVersion.cs` (`bfsv`), `Public API/Listeners/ITelemetryListener.cs`, `Assets/Resources/ApolloNetworkConfig.json`, `Bootstrap/Bootstrap.cs` (construction, guards, App-User-ID → Crashlytics wiring).
