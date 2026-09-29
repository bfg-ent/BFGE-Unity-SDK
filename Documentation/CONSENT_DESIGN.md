# Design: Consent (GDPR + ATT) for the Unity (Apollo) SDK

**Scope:** the SDK-owned GDPR/consent dialog and the iOS App Tracking Transparency (ATT) prompt
**Companion document:** `CONSENT_INTEGRATION_GUIDE.md` — the steps to get the feature working. This document describes *how the feature behaves* — for testers and developers who need the full picture, including edge cases. Setup instructions are deliberately absent here.

## Contents

- [1. Purpose & scope](#1-purpose--scope)
- [2. Overall design](#2-overall-design)
  - [2.1 Subsystem architecture](#21-subsystem-architecture)
  - [2.2 End-to-end flow](#22-end-to-end-flow)
  - [2.3 Configuration](#23-configuration)
  - [2.4 Public API surface](#24-public-api-surface)
- [3. Policy service network contract](#3-policy-service-network-contract)
  - [3.1 Policy check (GET)](#31-policy-check-get)
  - [3.2 Response schema](#32-response-schema)
  - [3.3 Client-side validation rules](#33-client-side-validation-rules)
  - [3.4 Tracking calls (POST)](#34-tracking-calls-post)
- [4. Dialog behavior](#4-dialog-behavior)
  - [4.1 Accept/decline gating](#41-acceptdecline-gating)
  - [4.2 Runtime-built uGUI dialog](#42-runtime-built-ugui-dialog)
  - [4.3 HTML rendering](#43-html-rendering)
- [5. Lifecycle & failure handling](#5-lifecycle--failure-handling)
  - [5.1 Bootstrap wiring & re-check on foreground](#51-bootstrap-wiring--re-check-on-foreground)
  - [5.2 First-launch network handling](#52-first-launch-network-handling)
  - [5.3 Fail-open behavior & auto-opt-in](#53-fail-open-behavior--auto-opt-in)
  - [5.4 Policy-error telemetry](#54-policy-error-telemetry)
- [6. Persistence](#6-persistence)
- [7. What the consent decision gates](#7-what-the-consent-decision-gates)
- [8. ATT (App Tracking Transparency)](#8-att-app-tracking-transparency)
- [9. Design decisions & rationale](#9-design-decisions--rationale)

## 1. Purpose & scope

The Unity (Apollo) SDK owns **GDPR and Apple compliance** end to end via the consent system. On launch (and on every subsequent foreground), the SDK asks the Bigfish policy service whether any legal policies — a GDPR-style opt-in/opt-out for third-party ad tracking, and/or a mandatory Terms of Use / Privacy Policy acceptance — need to be shown to this specific user, based on their country, language, and store. If so, it builds a modal dialog entirely from the server's response, gates the accept/decline decision behind comprehension checks (checkboxes, scroll-to-bottom, age verification), reports "shown" / "accepted" / "declined" back to the server for compliance record-keeping, and applies the decision to the SDK's own telemetry and Firebase Analytics automatically. Apollo also owns the iOS ATT prompt (§8): the game decides when it appears; Apollo displays it, records the selection, and reports it back to the game.

This matters because third-party ad-tracking consent is a **legal requirement** (EU GDPR), and Terms of Use / Privacy Policy acceptance is a near-universal requirement (most countries, not just the EU). Owning the flow in the SDK gives every game a consistent, compliant implementation instead of each building its own.

Behavioral guarantees the design provides: sequential multi-policy handling, a strict mandatory-vs-optional policy distinction, guaranteed-delivery consent tracking, resume-after-crash, and no double-prompting.

**Non-goals / exclusions:**

- The backend policy-service and consent-reporting contract (§3) is treated as a fixed interface — the SDK conforms to it, not the other way around.
- The consent dialog is not a general-purpose in-app dialog/notification system — it is scoped narrowly to this feature.
- No third-party CMP (consent-management-platform) integration — the consent flow is first-party, driven by the Bigfish policy service.

## 2. Overall design

### 2.1 Subsystem architecture

The subsystem lives in `Assets/SDK/Core/Consent/` (namespace `BFG.Apollo.Consent`), following Apollo's standard per-subsystem folder convention:

```
Core/Consent/
  ConsentController.cs            // IInitializable, ILifecycleHandler — orchestrator
  ConsentControlNames.cs          // e.g. THIRDPARTYTARGETEDADVERTISING, synthetic policy id constant
  Configuration/
    ConsentServiceConfig.cs        // JSON-loaded policy-service URL root (Resources/ApolloConsentConfig.json)
  Model/
    Policy.cs                     // response DTO, one policy
    PolicyConfig.cs                // nested "config" object
    PolicyAction.cs                 // enum { Shown, Accepted, Declined }
  Networking/
    PolicyFetchService.cs          // GET + deserialize + validate + fail-open/closed classification
    PolicyValidator.cs             // pure client-side validation (§3.3)
    PolicyHttpRunner.cs             // MonoBehaviour coroutine driving the raw GET (UnityWebRequest)
    ConsentReportingService.cs      // builds tracking payloads, sends via NetworkingController
    ConsentReportPayload.cs         // [JsonProperty] DTO for §3.4
  Persistence/
    PolicyStore.cs                  // wraps IRegistry — completed/accepted/declined/shown-unanswered state
  UI/
    ConsentDialogController.cs      // owns the runtime canvas; sequential multi-policy paging
    PolicyPageView.cs               // binds one Policy model to UI widgets
    PolicyHtmlRenderer.cs           // HTML subset -> TMP rich text
    OptInCheckboxItem.cs            // one dynamic checkbox
    AgeVerificationView.cs          // year picker + minimalAge gate
```

The game-facing pieces sit alongside the SDK's other public surfaces:

- `Public API/Listeners/IPolicyListener.cs` — `WillShowPolicies()` / `OnPoliciesCompleted()`.
- `Data/ScriptableObjects/ConsentSettings.cs` — the `BfgConsent.asset` settings asset (§2.3).

`ConsentController` is the only object `Bootstrap` knows about; everything else is internal to the subsystem. The controller participates in the standard component init sequence (`IInitializable`) and in the SDK's lifecycle events (`ILifecycleHandler`, the same mechanism `TelemetryController` uses for session start/end). All JSON goes through the SDK's `Encoding` facade (Newtonsoft, `[JsonProperty]` DTOs); all persistence goes through the `IRegistry` PlayerPrefs wrapper under the `BFG.Apollo.Policy.*` key convention (§6).

Two network paths, deliberately different:

- **Policy check** (GET, needs the response body parsed): a dedicated one-shot path — `PolicyFetchService` driving `PolicyHttpRunner`, a coroutine-based `UnityWebRequest` GET that completes on the main thread. It does not go through `NetworkingController`'s queue; the controller owns its own re-check timing (§5.1). Rationale for the transport choice is in §9.
- **Tracking calls** (POST, fire-and-forget): reuse `NetworkingController`/`OutboundMessageQueue` — the disk-persisted, retrying queue — via `MessageType.PolicyEvent`, with one routing entry in `ApolloNetworkConfig.json` pointing at the consent-reporting host (`AppendProductVersionSuffix: false` — this route has no `{productName}{version}` suffix). All three actions (`shown`/`accepted`/`declined`) share the one message type, distinguished by the payload's `action` field.

### 2.2 End-to-end flow

1. **Trigger.** At SDK start, and again on every app-foreground, the controller checks for outstanding policies.
2. **Fetch.** `GET` request, no body — country, language, app store, and bundle id are all path segments (§3.1).
3. **Response.** A JSON array of 0..N "policy" objects (§3.2). An empty array is a valid "nothing to show" response. Each policy is either **optional** (GDPR-style: user may accept or decline) or **mandatory** (Terms of Use / Privacy Policy style: accept-only, no decline path exists in the UI at all).
4. **Client-side validation.** Every policy object is validated against structural rules before being trusted (§3.3).
5. **Filter to "uncompleted."** Only policies whose `id` has not already been marked completed (accepted or declined in a prior session) are shown.
6. **Dialog.** If 1+ uncompleted policies remain, a modal is presented, built **entirely from server data** — title, HTML-rendered policy text, instruction text, accept/decline button labels, dynamic checkboxes, and an optional age-verification control. Multiple policies are presented **sequentially, one at a time**, in a single modal session — not stacked or shown all at once.
7. **User answers.** Accept is gated behind comprehension requirements (§4.1); Decline (only present for optional policies) has no gate beyond having seen the policy. The decision is a single boolean applied to *all* of that policy's named `controls` — there is no per-checkbox differential persistence.
8. **Tracking.** Two independent network calls, decoupled from the display flow: one fires the instant a policy is shown, another the instant the user answers it (§3.4).
9. **Persist.** The policy is marked "completed" so it never shows again; the answer is folded into an accepted-controls / declined-controls record queryable by the game and consumed internally to gate third-party tracking (§7).
10. **Repeat** for the next queued policy until the queue is empty, then dismiss and fire `OnPoliciesCompleted`.

Cross-cutting behaviors:

- **Resume after crash/kill.** If the app is killed mid-dialog, the "shown but not yet answered" state survives (§6), so on relaunch the SDK re-validates against the server and resumes rather than re-prompting from scratch or silently skipping.
- **No public "force re-show" API.** Re-display only happens because the *server* still considers a policy id uncompleted — this is intentional.
- **A game can own consent itself.** `EnableTargetedAdvertising(bool)` bypasses the SDK's dialog entirely while still recording the decision through the same persistence/reporting pipeline, under a synthetic all-zeros policy id (§2.4).

### 2.3 Configuration

Two files in `Assets/Resources/`, both created via **BFG → Apollo → Create Missing Settings Files**. The game-facing file reference (keys, values, defaults) lives in the main guide — this section is the design rationale:

- **`ApolloConsentConfig.json`** ([reference](APOLLO_SDK_INTEGRATION_GUIDE.md#apolloconsentconfigjson--policy-service-url)) — the policy-service URL root, loaded by `ConsentServiceConfig`. If the file is missing or invalid the consent system **self-disables** (logged warning, no fetch, no dialog) rather than pointing at a hardcoded host.
- **`BfgConsent.asset`** ([reference](APOLLO_SDK_INTEGRATION_GUIDE.md#bfgconsentasset--consent-environment)) — a `ConsentSettings` ScriptableObject carrying the `environment` value (`Prod`/`Test`) reported on every consent tracking event (§3.4's `environment` field). Loaded optionally in `BootstrapFactory.Init()` exactly like `BfgFirebaseSettings`; a game that hasn't created the asset gets a safe default (`Prod`), so an unconfigured build never silently mislabels real events as test data. The asset is deliberately shaped as a durable home for *more than just* the environment toggle — future consent-specific settings (e.g. a "disable the built-in consent dialog" switch for games that own their own consent UI) can be added without a new config file or breaking change.

### 2.4 Public API surface

On `BFGUnitySDK` (delegating to `Bootstrap` → `ConsentController`, matching the pattern of every other subsystem):

- `AddPolicyListener` / `RemovePolicyListener` — instance-registered `IPolicyListener` (`WillShowPolicies()` / `OnPoliciesCompleted()`). A listener registered after the state is already known is **immediately re-delivered** that state, so late registration never misses the outcome. **`WillShowPolicies` timing:** on the literal first-ever launch it fires when the initial policy check STARTS (before the fetch resolves, alongside the §5.2 loading overlay) so games can hold their intro flow, with `OnPoliciesCompleted` following at resolution regardless of outcome; on every subsequent check (foregrounds and later cold starts) it fires only when a dialog will actually display.
- `DidAcceptPolicyControl(string controlName)` — queries the accepted-controls record (§6); `BFGUnitySDK.ThirdPartyTargetedAdvertisingControl` is the named control games pass to read the GDPR ad-tracking decision.
- `EnableTargetedAdvertising(bool enabled)` — game-managed override: lets a game that implements its **own** consent UI tell Apollo the decision directly, bypassing the dialog entirely, recorded through the same persistence + reporting pipeline under a synthetic all-zeros policy id, and still driving §7's hooks.
- The ATT surface (`RequestTrackingAuthorization`, `AddAttListener`/`RemoveAttListener`) is covered in §8.

## 3. Policy service network contract

### 3.1 Policy check (GET)

```
GET {root}/consent-service/mobile/v2/appstore/{appStore}/bundleids/{bundleId}/languages/{languageCode}/countries/{countryCode}/policies
```

- `root` — from `ApolloConsentConfig.json` (§2.3); production is `https://policy.bigfishgames.com`.
- `appStore` — the platform's store identifier (e.g. `itunes` / `google` / `amazon`), matching the convention Apollo's telemetry uses for store identification.
- `bundleId` — the app's bundle/package identifier.
- `languageCode` / `countryCode` — 2-letter codes derived from device locale; **fall back to the literal string `"unknown"`** if the device can't supply one.
- No request body, no query string — all identifying info is in the path.
- No device id (`bfgudid`) is sent on this call — only the tracking calls (§3.4) carry it.

### 3.2 Response schema

A JSON array, 0..N entries:

```jsonc
[
  {
    "id": "27a2306f-c2c7-4f9c-980b-56e011a1bae5",  // policy UUID, unique within the payload
    "title": "Terms of Service",
    "languageCode": "en",
    "policyText": "<h1>...</h1>",        // HTML body — supports at least h1, a, strong, ul, ol, li, br
    "instructionText": "Choose wisely",   // instruction/warning banner shown above the action buttons
    "acceptButtonText": "Accept",
    "declineButtonText": "Decline",       // OMITTED/empty when config.optional == false — no decline path exists for mandatory policies
    "optInText": ["This is a checkbox"],  // 0..N granular checkbox labels — a comprehension gate, NOT separately persisted
    "controls": ["THIRDPARTYTARGETEDADVERTISING"], // named permission flag(s) this policy's answer applies to
    "minimalAgeVerificationText": "Choose your birth year.", // present only when config.ageVerification == true
    "config": {
      "placementEvent": "startup",   // informational, not currently acted on by the client
      "userGroup": "new",            // informational, server-side segmentation
      "ageVerification": false,
      "minimalAge": 13,               // required, > 0, when ageVerification == true
      "optional": true                // true = GDPR-style (accept/decline choice); false = mandatory ToS/Privacy-Policy style (accept-only)
    }
  }
]
```

An empty array `[]` is a valid, successful "nothing to show" response.

### 3.3 Client-side validation rules

`PolicyValidator` applies these rules to every response before it is trusted. **Rejection scope differs by rule — the distinction is deliberate, not uniform:**

- **Rules 1-4 reject only the individual offending policy** (drop it from the list; other, valid policies in the same response — including a mandatory ToS/Privacy Policy — are still shown):
  1. Any of `id`, `title`, `policyText`, `acceptButtonText`, `instructionText` is empty/missing.
  2. `config.optional == true` **and** (`declineButtonText` is empty **or** `controls` is empty) — an optional policy must offer a decline path and govern at least one control.
  3. `config.optional == false` **and** (`declineButtonText` is non-empty **or** `controls` is non-empty) — a mandatory policy must not offer decline or govern controls.
  4. `config.ageVerification == true` **and** (`config.minimalAge <= 0` **or** `minimalAgeVerificationText` is empty).
- **Rule 5 rejects the entire payload** — the one and only whole-payload-rejection case:
  5. **Any two policies in the same response share the same `id`** — the whole payload is treated as malformed.

This validation exists so a broken/misconfigured server response can never accidentally produce an inconsistent or exploitable UI state (e.g. a "mandatory" policy that silently offers a decline button) — and so that one unrelated malformed policy entry can never suppress an otherwise-valid mandatory policy elsewhere in the same response.

### 3.4 Tracking calls (POST)

```
POST {root}/consent-reporting/mobile/v1/{bundleId}
```

Fired twice per policy: once the instant it is displayed ("shown"), once the instant the user answers it ("accepted" or "declined"). Payload:

| Field | Type | Meaning |
|---|---|---|
| `clientEventId` | string (UUID) | Fresh per event — server-side de-duplication key. |
| `action` | string | `"shown"` \| `"accepted"` \| `"declined"`. |
| `bundleId` | string | App bundle/package id. |
| `bfgudid` | string | The SDK's own stable device id. |
| `policyId` | string | The policy's `id` (or the synthetic all-zeros id for game-managed overrides and the auto-opt-in path). |
| `environment` | string | `"prod"` \| `"test"` — sourced from `BfgConsent.asset` (§2.3), not hardcoded. |
| `raveId` | string | The current `UserID` exposed by the registered `IAuthenticationAdapter`, carried under the backend's historical field name. If no adapter/user id is set (null), the literal 32-character placeholder `"00000000000000000000000000000000"`. |
| `sessionId` | string | Shared with the SDK's telemetry session id, so consent events correlate with the rest of the user's session data. |
| `timestampClient` | number | Unix seconds, client clock. |

**Delivery guarantees** (a real, persisted queue — not a best-effort send), satisfied by `NetworkingController`/`OutboundMessageQueue` via `MessageType.PolicyEvent` (§2.1):

- The event is persisted to local storage **before** the network call is attempted, so it survives process death.
- On `HTTP 400`: the payload is permanently invalid — discarded, never retried.
- On any other failure (5xx, timeout, no connectivity): the event stays queued and is retried later (on the queue's timer / on reconnect).
- If a session id doesn't exist yet when an event is generated (consent can fire very early in app life), the event is held in a **separate, additional durable queue** until one exists, then flushed — `NetworkingController`'s guaranteed delivery only starts protecting an event once it is actually enqueued there. See §6's `PendingReports` for the queue that covers this gap.

## 4. Dialog behavior

### 4.1 Accept/decline gating

- **Accept** is enabled only once the user has: checked every rendered checkbox (if any `optInText` entries exist), passed age verification (if `config.ageVerification`), and scrolled the policy text to the bottom. The scroll gate applies uniformly on both platforms, so behavior is deterministic and doesn't silently diverge. The scroll gate is **sticky when earned**: once the user has scrolled *overflowing* content to the bottom, scrolling back up to re-read does not re-lock Accept, and that earned state survives rotation rebuilds of the same policy page (checkbox/age-verification input still resets with the rebuilt widgets, but reading progress is retained). Policies short enough to fit without scrolling pass the gate automatically — but that auto-pass is **not** sticky: it is re-evaluated against each layout, so a policy that fit in portrait re-locks Accept after rotating into a shorter landscape layout where the text now overflows, until the user scrolls it (review finding on PR #59: latching the auto-pass let unread below-the-fold text slip through a rotation).
- **Decline** is available (button rendered at all) only when `config.optional == true`; it has no comprehension gate beyond the policy having been shown.
- The accept/decline decision, once made, is applied as a single boolean to **every** control named in that policy's `controls` array — checkboxes are UX comprehension gates, not independently recorded outcomes.

### 4.2 Runtime-built uGUI dialog

A single Unity UI (uGUI) implementation shared across iOS and Android, built **entirely at runtime** via `UguiFactory` (`new GameObject()`/`AddComponent()`) — no pre-authored prefab (rationale in §9).

- `UguiFactory` builds all UI elements using **TextMeshPro** (`TextMeshProUGUI`/`TMP_InputField`), not classic `UnityEngine.UI.Text`/`InputField` — this is what enables real, clickable `<link>` tags (§4.3).
- `ConsentDialogController` (a `MonoBehaviour`, created via `new GameObject()` + `AddComponent`) builds a root Canvas/CanvasScaler/GraphicRaycaster, backdrop, panel, and content container in `Awake()`; a sibling child is the first-launch loading overlay (§5.2) — a semi-transparent backdrop + spinner, initially inactive. It owns the queue of uncompleted policies and presents them **sequentially**, one at a time, advancing on each accept/decline until the queue is empty, then dismissing and firing `OnPoliciesCompleted`.
- `PolicyPageView` is a plain C# class (not a `MonoBehaviour`) constructed fresh per policy and built via `Build(Transform parent)` — content is destroyed and rebuilt between policies. It binds one policy's model to: title, instruction text, HTML-rendered body, N dynamically-instantiated checkboxes, an optional age-verification control, and accept/decline buttons — **the decline button is only built at all when the policy is optional** (no button instantiated for a mandatory policy, not merely hidden).
- **Consuming-project dependency:** TextMeshPro (TMP Essential Resources imported, for `TMP_Settings.defaultFontAsset`) is required — a near-universal Unity dependency already, and stated explicitly as an integration prerequisite in the integration guide.
- Accept-gating logic (all checkboxes checked, age verified, scrolled to bottom) lives in `PolicyPageView`, reading directly off the bound `Policy`/`PolicyConfig` model — no separate "rules engine." Accept starts non-interactable (fail-closed) and the **first gate evaluation is deferred until after the build frame's canvas layout pass** (`ConsentDialogController.LateUpdate` ticks `PolicyPageView.TickInitialGateRefresh`, which waits out the build frame and any zero-height rects). A synchronous first check is not salvageable — even `LayoutRebuilder.ForceRebuildLayoutImmediate` does not reliably resolve this nested LayoutGroup + ContentSizeFitter + TMP hierarchy, and pre-layout rects report Unity's default 100x100 (nonzero garbage), which made the "content fits, nothing to scroll" branch enable Accept without any scrolling. The bottom decision is split into two pure helpers: `PolicyPageView.IsAtBottom` (gate currently passes — includes the fits-without-scrolling case, and treats unresolved zero-height layout as never-at-bottom) and `IsScrollEarnedBottom` (content overflows *and* was scrolled to the bottom — the only state that latches sticky and survives rotation rebuilds; the fits auto-pass deliberately never latches). The deferred first check is also **bounded**: if the rect heights never resolve above zero (degenerate layout, e.g. an empty policy body server-side), `TickInitialGateRefresh` gives up after ~1s (60 ticks), logs a warning, and fails open on the scroll gate for that build (checkbox/age gates still apply) rather than leaving Accept permanently locked on a mandatory dialog — mirroring the SDK's malformed-payload fail-open stance. The timeout state is per-build, so a later rebuild whose layout resolves normally re-evaluates honestly.

### 4.3 HTML rendering

The server sends real HTML; Unity's TextMeshPro supports only a constrained rich-text tag subset, not arbitrary HTML. `PolicyHtmlRenderer` maps the supported tag set (`h1`-`h6`, `strong`/`b`, `em`/`i`, `a href`, `ul`/`ol`/`li`, `br`/`p`) into TMP rich text and a real TMP `<link="...">` tag for `<a href>` (the href is captured and used as the link id), stripping/escaping anything outside that set so unrecognized markup never leaks into the UI (entity decoding happens *before* the tag-whitelist strip, not after, so entity-encoded markup can't smuggle a tag past the filter). TMP links are not automatically clickable — `TmpLinkClickHandler`, a small `IPointerClickHandler` component `PolicyPageView` attaches to the body text `GameObject`, uses `TMP_TextUtilities.FindIntersectingLink` to detect a tap on a `<link>` span and calls `Application.OpenURL` with the captured href.

**Good to know:** this is not full HTML rendering. Policy text using markup outside the supported set degrades to plain text rather than rendering as intended — richer formatting needs validation against real policy content, or a coordinated change server-side to emit simpler markup.

## 5. Lifecycle & failure handling

### 5.1 Bootstrap wiring & re-check on foreground

- `ConsentController` is constructed in `Bootstrap.ConstructComponents()` alongside `TelemetryController` and implements `IInitializable`, participating in the normal init gate. The actual policy-check fetch runs from `Start()` (after `TelemetryController.Start()` has produced a session id) and does **not block `StartSDK()`** — the dialog is a runtime overlay shown after the SDK has started, matching how Firebase's async, non-fatal init behaves.
- It implements `ILifecycleHandler` (the same interface `TelemetryController` uses), so a re-check is triggered on every app foreground.
- **Re-entrancy guard while the dialog is actively showing:** the foreground re-check does not fire a new fetch (and rebuild/replace the currently-displayed `PolicyPageView`) while a policy is on-screen and unanswered. A phone call, notification-shade pull, or app-switcher peek is a plausible trigger for a pause/resume cycle mid-dialog; without this guard, a new fetch response would wipe in-progress checkbox/scroll/age-verification input and could re-fire `WillShowPolicies()` without an intervening `OnPoliciesCompleted()`. The guard covers the entire display-and-answer phase, not just fetch-to-fetch overlap.

### 5.2 First-launch network handling

A persisted flag, `HasAttemptedInitialCheck`, is set the instant the very first-ever `CheckForPolicies()` fetch is kicked off (regardless of outcome), so the behavior below fires at most once per install:

- **On the literal first-ever check** (`HasAttemptedInitialCheck` was `false` when this fetch started): a lightweight, semi-transparent grey overlay with a spinner is shown, blocking interaction, while the fetch is in flight — the fetch races a **20-second bounded timeout**:
  - The fetch resolves (success or any failure) before 20s → the overlay hides. On success with uncompleted policies, the normal dialog flow proceeds (which remains its own expected blocking modal). On any failure (no connectivity, timeout, malformed response, anything) → the overlay hides and the user enters the game immediately; nothing is marked "completed," so a fresh fetch is attempted on the next warm/cold start.
  - The 20s timeout fires first (fetch still pending — slow connection) → the overlay hides and the user enters the game; the in-flight request's eventual result is discarded for blocking purposes — but a late-arriving FAILED result still goes through the policy-error telemetry (§5.4, reportable codes only, same per-code gate), so a slow-but-real service/parse error on first launch is not lost. Retry occurs on the next warm/cold start.
  - No distinct "no connection" vs. "slow connection" heuristic is needed — a fast connection error resolves well under 20s and the user is barely delayed; a hanging/slow request is simply bounded by the same cap.
- **On every subsequent check** (`HasAttemptedInitialCheck` already `true`): no overlay, no bounded wait, no blocking of any kind on failure. The fetch runs silently in the background; on success with uncompleted policies, the dialog still shows as normal; on any failure, nothing happens and the check retries on the next foreground/launch.
- **Net effect: network problems are never a barrier to entering the game, on any launch.** The consent dialog itself only ever blocks when it has real policy content to show, never as a side effect of a slow or failed network call. This is a deliberate design choice — it prioritizes never blocking app entry over guaranteeing the dialog is always shown before third-party tracking could occur.

### 5.3 Fail-open behavior & auto-opt-in

Fetch failures are classified as **fail-open** (behave as if the user accepted: `OnPoliciesCompleted` fires and the auto-opt-in below applies) or **fail-closed** (let the user through with no opt-in; re-check next foreground). Connectivity-class failures (no internet, timeout, connection-level errors) fail closed; service/parse failures (non-200, invalid JSON, validation rejection) fail open. Neither ever blocks the user (§5.2). The per-code classification table is in §5.4.

**Auto-opt-in when the response contains no GDPR policy:** a **successful** policy-check response that contains no GDPR-style policy — none with `config.optional: true` and `THIRDPARTYTARGETEDADVERTISING` in `controls` — means this user (per their store/country/language) is not required to make an explicit targeted-advertising choice, and the SDK immediately behaves as if they tapped Accept on one: the control is recorded accepted under the synthetic all-zeros policy id, an `accepted` tracking event is reported, and §7's two hooks fire (`tpte` → 1, Firebase Analytics enabled). This happens the moment the response is classified — **before** any mandatory ToU in the same response is shown or answered — so e.g. a `sessionEnd` GTS event fired by backgrounding while the ToU is still on screen already carries `tpte: 1`. It is checked against the full validated response, not the uncompleted subset (an already-answered GDPR policy still counts as present; the stored decision stands). Guards: skipped if the control was ever explicitly declined (same rule as fail-open), and skipped if already accepted — which also makes the auto-opt-in idempotent across the per-foreground re-checks (no repeated `accepted` reports). It never fires from a connectivity failure, the bounded-wait timeout, or any other path where no confirmed response exists — only from a fetched, parsed, validated response confirmed to lack the policy (plus the fail-open case above).

### 5.4 Policy-error telemetry

Every FINAL failed policy-check outcome (an attempt whose retry later succeeds reports nothing) sends a GTS `error`-type event — `d.en = "policyError"` (exact camelCase string; the server-side reporting pipeline matches it verbatim), `d.ed = {"phase": 1, "code": <code>, "message": "<BFGConsentManagerError...>", "actualError": "<raw transport/parser detail>"}` — through the same `MessageType.Error` route purchase errors use (issue #58). The codes and message strings match the error set the consent-reporting backend already understands:

| Code | Message | Trigger | Reported? |
|---|---|---|---|
| 100 | BFGConsentManagerErrorUnknown | connection-level failure that is neither timeout nor no-internet (DNS/TLS/reset/…) — fail-closed | **No — logged only** |
| 101 | BFGConsentManagerErrorService | service returned non-200 (4xx immediately, 5xx after retry exhaustion) — fail-open | Yes |
| 102 | BFGConsentManagerErrorNoInternet | request failed while the device reported no reachability — fail-closed | **No — logged only** |
| 103 | BFGConsentManagerErrorTimeout | request timed out — fail-closed | **No — logged only** |
| 104 | BFGConsentManagerErrorInvalidJSON | response body isn't parseable JSON — fail-open | Yes |
| 105 | BFGConsentManagerErrorInvalidJSONObject | valid JSON, unexpected shape for the policy list — fail-open | Yes |
| 106 | BFGConsentManagerErrorFailedPolicyRequirements | payload parsed but PolicyValidator rejected it (duplicate ids, …) — fail-open | Yes |

The connectivity-class codes (100/102/103) are classified and logged but **never sent to the server** — they are unactionable network noise, not service defects. Each reportable code sends **at most once per app run** (per-code gate): a still-broken payload re-reports only after the next cold start, a failure that first appears on a warm-start foreground still reports that run, and a different reportable code later in the same run gets its own event. Reporting never alters flow behavior: fail-closed still lets the user through with no opt-in and a re-check next foreground, and fail-open still fires `OnPoliciesCompleted` + auto-opt-in (`tpte`=1 + Firebase Analytics). The `PolicyFetchFailureKind` → `POLICY_ERROR_*` mapping lives in `ConsentController.GetPolicyErrorForFailureKind`; the suppression filter is `ConsentController.IsLogOnlyPolicyError`.

## 6. Persistence

`BFG.Apollo.Policy.*` PlayerPrefs keys (siblings of `BFG.Apollo.Policy.ATT`), via the `IRegistry` wrapper pattern. PlayerPrefs has no native list support, so lists are JSON-encoded via the `Encoding` facade:

| Key | Type | Meaning |
|---|---|---|
| `BFG.Apollo.Policy.CompletedIds` | JSON-encoded list of strings | Policy ids that are done (accepted OR declined) — the primary "don't show again" gate. |
| `BFG.Apollo.Policy.AcceptedControls` | JSON-encoded list of strings | Union of controls the user has accepted — queryable by the game via `DidAcceptPolicyControl`. |
| `BFG.Apollo.Policy.DeclinedControls` | JSON-encoded list of strings | Union of controls declined — also used to prevent auto-opt-in (§5.3) once explicitly declined. |
| `BFG.Apollo.Policy.ShownUnanswered` | string (policy id) | The policy currently shown but not yet answered — the crash/kill-mid-dialog resume marker, and the guard against double-firing the "shown" tracking event. |
| `BFG.Apollo.Policy.PendingReports` | JSON-encoded list of `ConsentReportPayload` | Tracking events (shown/accepted/declined) generated before a session id was available — held here, `SessionId` unset, until one exists (§3.4's "hold until session id exists" requirement). Reuses the wire DTO directly rather than a separate model. |

**Pending-reports flush:** `ConsentReportingService.Report(...)` captures the full payload (`clientEventId`, `timestampClient`, `bundleId`, `bfgudid`, `raveId`, `policyId`, `action`) at the moment the event actually occurs. If a session id is available, it sends immediately via `NetworkingController.PostMessageAsync` (§3.4's reliable path); if not, it appends to `PolicyStore.PendingReports` instead. `ConsentReportingService.FlushPendingIfPossible()` drains that queue — filling in the now-known `SessionId` and sending each entry the same way, removing it from `PendingReports` only once handed off to `NetworkingController` (whose own disk-persisted retry owns delivery from that point on). It is called at the top of every `Report(...)` call and from `ConsentController.OnApplicationResume()`. Because the queue is PlayerPrefs-backed, it also survives a process kill and drains on the next app start via the same hooks.

## 7. What the consent decision gates

The GDPR-optional policy governs the `THIRDPARTYTARGETEDADVERTISING` control — the signal for third-party ad/attribution tracking. Inside the SDK, a decision on that control drives two existing public hooks, **by actually calling those two methods** — never by re-implementing their internals (e.g. writing the same PlayerPrefs key directly with a second hardcoded copy of the string, which would silently stop tracking the methods if they ever change):

- `BFGUnitySDK.ApplyThirdPartyTrackingConsentStatus(bool)` — the persisted flag read by the GTS telemetry payload builder (the `tpte` field on every event).
- `BFGUnitySDK.SetFirebaseDataCollectionConsent(bool)` — gates Firebase Analytics collection (see `FIREBASE_DESIGN.md` §2.5).

There is a single call site in `ConsentController` used whenever that control's state changes, regardless of whether the decision came from the dialog, the fail-open path, the no-GDPR-policy auto-opt-in (§5.3), or the game-managed override.

**Everything the game integrates directly is the game's responsibility** — Apollo applies the decision to its own telemetry and Firebase only. The game reads the decision (`DidAcceptPolicyControl(BFGUnitySDK.ThirdPartyTargetedAdvertisingControl)`) and feeds its own ad/attribution SDKs; see the integration guide.

## 8. ATT (App Tracking Transparency)

Apollo owns the iOS ATT prompt end to end, mirroring the ownership model of the consent dialog:
the game decides **when** the prompt appears; Apollo displays it, records the selection for its
own telemetry, and reports the outcome back to the game.

**Public API** (on `BFGUnitySDK`):
- `RequestTrackingAuthorization()` — shows the native iOS prompt, or resolves immediately with
  the current status when iOS has already determined it (prior answer, or a Settings-level
  restriction). On Android and in the Editor this is a **logged no-op** and no listener callback
  ever fires — games keep their own platform split.
- `AddAttListener(IAttListener)` / `RemoveAttListener(IAttListener)` — instance-registered
  (same pattern as `IPolicyListener`, not `RegisterListener<T>()`). Duplicate registrations are
  de-duplicated. `IAttListener.OnAttAuthorizationCompleted(ATTStatus)` delivers the selection.
- There is deliberately **no game-facing setter** — a game cannot write an ATT status, because a
  written status could be inconsistent with what iOS actually reports.

**Internals** (`Core/Policy/AttAuthorization.cs` + `_Apollo_RequestTrackingAuthorization` in
`Assets/Plugins/iOS/Apollo/ApolloUtil.mm`): a static class, deliberately *not* a Bootstrap
component — ATT has no init sequence, and the request must work whenever the game deems the
moment right, independent of SDK init state. The native completion handler returns via
`UnitySendMessage` to a hidden, scene-persistent runner GameObject (`BFGAttPromptRunner`).
On iOS 14+ the real prompt is requested; pre-iOS-14 devices resolve immediately with the mapped
tracking status.

**Persist-before-notify (load-bearing ordering):** when the prompt resolves, `HandleResult`
writes the status to PlayerPrefs (`BFG.Apollo.Policy.ATT`, int-cast `ATTStatus`) **before**
notifying listeners. GTS `aptts` and IDFA gating read that key, so any event a listener callback
triggers already carries the new status, and `aptts`/`ifa` stay mutually consistent within an
event (the IDFA is only read while the stored status is `Authorized`).

**Behavior details / edge cases:**
- **Register the listener before requesting.** An already-determined status resolves immediately
  — potentially the same frame as the request — so a listener registered after the request can
  miss the result entirely.
- `ATTStatus` values are iOS-native-mapped (`NotDetermined=0, Restricted=1, Denied=2,
  Authorized=3`), persisted as ints — never renumbered.
- The stored status is **OS-seeded once per cold start** (`GtsInfoProvider.GetAttStatusCached()`
  reads the native status on the first iOS event of a launch). Settings-app tracking changes
  always kill the app, so the cold-start read covers them; the Apollo-owned prompt is the only
  possible mid-session change and is written by `HandleResult`.
- A malformed status value from the native callback is logged and dropped — listeners are not
  notified with garbage.
- **Timing is the game's responsibility** — Apple requires that users understand why tracking is
  requested, so games typically call `RequestTrackingAuthorization()` from
  `IPolicyListener.OnPoliciesCompleted` (after the GDPR flow resolves). The
  `NSUserTrackingUsageDescription` Info.plist entry is likewise the game's responsibility.
- Because `OnPoliciesCompleted` re-fires on every foreground re-check and a determined ATT status
  is re-delivered immediately, anything a game chains after ATT (e.g. an OS push-permission
  request) must be gated once-per-install by the game.

## 9. Design decisions & rationale

- **Single shared uGUI implementation for iOS and Android**, not native per-platform dialogs. Apollo has no other native full-screen UI; native would mean maintaining two platform-specific UI codebases plus a Unity-side bridge for one feature.
- **Fully code-built UI, no prefab.** A prefab-based hybrid (shipped static chrome + code-built dynamic content) was implemented and reverted after establishing that TMP's clickable `<link>` support does not require a prefab — `TMP_TextUtilities.FindIntersectingLink` works identically for a component added via `AddComponent` at runtime. Staying code-built avoids a manual Unity-Editor prefab-authoring step, a new packaging requirement in `copy-apollo-dlls.sh`, and the serialized-`[SerializeField]`-reference-breakage risk a prefab carries across SDK versions. The TMP Essential Resources dependency for consuming projects is unaffected by this choice either way.
- **TextMeshPro over classic `UnityEngine.UI.Text`** — TMP's rich-text `<link>` tags plus click detection are what make policy hyperlinks actually clickable; classic Text has no equivalent.
- **Policy fetch on `UnityWebRequest`, not Mono `HttpClient`.** An earlier revision used `HttpClient` with the `BFGAutomationConfiguration.json`/`WebProxy` mechanism so QA could see the call in Charles. Field experience reversed that: on device, Charles inspection works through the phone's Wi-Fi proxy setting, which NSURLSession (and therefore `UnityWebRequest`) honors automatically, so the in-app proxy config bought nothing there; and Mono's managed HTTP stack is flaky on iOS around cold start and app suspension (the same reason `NetworkingController.SendMessageAsync` falls back to `UnityWebRequest` under `UNITY_IOS`), producing spurious first-attempt failures the native stack does not. One transport also means one TLS stack and one class of failure modes. For Editor/desktop Charles capture, use a system-level proxy or launch the Editor with `HTTP_PROXY`/`HTTPS_PROXY` environment variables.
- **The policy fetch bypasses `OutboundMessageQueue`** — a session-gating GET whose response body must be parsed has different semantics from a fire-and-forget telemetry POST; the controller owns its own retry/re-check timing (§5.1). The tracking POSTs, by contrast, are exactly the queue's shape and reuse it wholesale (§3.4).
- **Bounded first-launch wait (§5.2) instead of hard fail-open or fail-closed.** The design prioritizes never blocking app entry: a user can, in the worst case, enter the game without having seen a policy (retried next launch) — accepted as the better trade-off against indefinitely blocking launch on bad connectivity.
- **No public "force re-show" API** — re-display is driven solely by the server still returning an uncompleted policy id, so compliance state has one source of truth.
- **Environment lives in a ScriptableObject settings asset (`BfgConsent.asset`)**, modeled on `BfgFirebaseSettings.asset`: Inspector-editable, optional, safe default (`Prod`) so an unconfigured build never mislabels production events as test data, and a durable home for future consent-specific toggles without a new config file. (The GTS-side `BaseSystemInfoProvider.ENVIRONMENT` constant is a separate, pre-existing gap not covered by this asset.)
