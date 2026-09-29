# Unity (Apollo) SDK Consent Integration Guide (GDPR + ATT)

Step-by-step integration of the Unity (Apollo) SDK's compliance features into a mobile game: the built-in
GDPR/consent dialog and the iOS App Tracking Transparency (ATT) prompt. This guide covers **what
you must do**; for how the features behave (flow rules, failure handling, edge cases), see
[`CONSENT_DESIGN.md`](CONSENT_DESIGN.md). For the full API surface, see
[API Reference → Consent & Policy](../Apollo_Documentation.md#consent--policy).

Apollo owns both flows end to end — it fetches and displays the consent policies, displays the ATT
prompt, records every decision, and applies the results to its own telemetry automatically. Your
game's job is: provide two config files, register two listeners, and make one call to trigger ATT.

**Prerequisite:** the consent dialog is built at runtime with TextMeshPro, so the project must
have **TMP Essential Resources** imported (**Window → TextMeshPro → Import TMP Essential
Resources**) — most Unity projects already do; without it the dialog cannot render text.

---

## 1. Create `Assets/Resources/ApolloConsentConfig.json`

The policy-service URL root. **Without this file the entire consent system silently disables
itself** (a log warning is emitted) — this is the on/off switch for the built-in dialog.

The Unity menu **BFG → Apollo → Create Missing Settings Files** creates it (and every other
missing Apollo settings file) with the production URL.

The file reference (key + test/production URLs) lives in
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → ApolloConsentConfig.json](APOLLO_SDK_INTEGRATION_GUIDE.md#apolloconsentconfigjson--policy-service-url).
Make sure your build pipeline ships the production URL.

## 2. Create `Assets/Resources/BfgConsent.asset`

Created by the same **BFG → Apollo → Create Missing Settings Files** menu as step 1. The asset
must be named `BfgConsent` and live under `Resources/`.

The field reference lives in
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → BfgConsent.asset](APOLLO_SDK_INTEGRATION_GUIDE.md#bfgconsentasset--consent-environment)
— one field (`environment`); use `Test` during development and **set it to `Prod` before
shipping**.

## 3. Register an `IPolicyListener` (before `Initialize()`)

Apollo checks for outstanding policies at init and on every foreground, and shows its own dialog
when any are outstanding. Your game hooks the flow through `IPolicyListener` — registered **by
instance** (not via `RegisterListener<T>()` like other Apollo listeners):

```csharp
using BFG.Apollo.Consent;

public class MyPolicyListener : IPolicyListener
{
    // A policy dialog is about to appear — pause gameplay/intro flow, mute audio, etc.
    public void WillShowPolicies() { }

    // The consent flow is fully resolved for this check (nothing outstanding, or the user
    // answered everything). Continue your startup sequence from here — this is also the
    // right moment to trigger ATT (step 4).
    public void OnPoliciesCompleted() { }
}

// BEFORE BFGUnitySDK.Initialize():
BFGUnitySDK.AddPolicyListener(new MyPolicyListener());
BFGUnitySDK.Initialize();
```

Two contract points you must design around (details in [`CONSENT_DESIGN.md`](CONSENT_DESIGN.md)):

- **`OnPoliciesCompleted` re-fires** after every foreground policy re-check, not just once at
  launch. Gate any one-time action you trigger from it (e.g. an OS permission request) yourself.
- A listener registered after the state is already known is immediately re-delivered that state,
  so late registration is safe — but register before `Initialize()` anyway so you never miss the
  first launch's `WillShowPolicies`.

## 4. ATT (iOS only)

Apollo displays the ATT prompt and consumes the result itself (GTS `aptts` field + IDFA gating
update automatically — there is no reporting call for you to make). You decide *when*, and you
listen for the outcome.

**4a. Register an `IAttListener` — before requesting.** If iOS has already determined the status
(previous answer, or Settings-level restriction), the result is delivered immediately with no
prompt, so a listener registered after the request can miss it.

```csharp
using BFG.Apollo.Policy;

public class MyAttListener : IAttListener
{
    // Apollo has already recorded the status for telemetry when this fires — use it purely
    // to react (continue your startup sequence, configure your own third-party SDKs).
    public void OnAttAuthorizationCompleted(ATTStatus status)
    {
        Debug.Log($"ATT resolved: {status}");
    }
}

BFGUnitySDK.AddAttListener(new MyAttListener());   // RemoveAttListener to unregister
```

**4b. Request the prompt** once the consent flow has resolved — Apple requires that users
understand why tracking is requested before the prompt appears, so call it from
`OnPoliciesCompleted`:

```csharp
BFGUnitySDK.RequestTrackingAuthorization();
```

On Android and in the Editor this is a logged no-op and the listener never fires — keep a platform
split (`#if UNITY_IOS && !UNITY_EDITOR` in *game* code) and continue your startup sequence
directly on non-iOS platforms.

**4c. Add `NSUserTrackingUsageDescription` to Info.plist** — required by Apple; the prompt will
not function without it, and App Review rejects builds that omit it. Add it in Xcode or via a
post-process build script:

```csharp
#if UNITY_IOS
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEditor.iOS.Xcode;

public static class iOSPostProcess
{
    [PostProcessBuild]
    public static void OnPostProcessBuild(BuildTarget target, string pathToBuiltProject)
    {
        if (target != BuildTarget.iOS) return;
        string plistPath = pathToBuiltProject + "/Info.plist";
        var plist = new PlistDocument();
        plist.ReadFromFile(plistPath);
        plist.root.SetString("NSUserTrackingUsageDescription",
            "Your data will be used to deliver personalized ads to you.");
        plist.WriteToFile(plistPath);
    }
}
#endif
```

> **Note:** make sure to provide translations of this usage-description string for every language
> your game supports — the ATT prompt displays it verbatim, and only the prompt's title/buttons
> are localized by iOS. Localize it via `InfoPlist.strings` files (one per supported language) in
> the exported Xcode project.

## 5. Feed the GDPR decision to your own third-party SDKs

Apollo applies the user's GDPR decision to everything *it* owns automatically. Anything **your
game** integrates directly — attribution/ad SDKs (AppsFlyer, ad mediation, ad networks), analytics
you added outside Apollo — is your responsibility. Read the current decision at any time:

```csharp
bool accepted = BFGUnitySDK.DidAcceptPolicyControl(
    BFGUnitySDK.ThirdPartyTargetedAdvertisingControl);
```

`false` means declined, not-yet-answered, or not-applicable — always the safe value to feed into a
third-party SDK's consent flag.

### If GDPR is declined: disable tracking on your advertising third parties

> ⚠️ **Critical:** this step is highly important for GDPR compliance. Apollo gates only its own
> telemetry — your game is responsible for honoring the user's decision across every third-party
> advertising service it integrates.

When the user declines (or has not accepted) the targeted-advertising policy, you must **disable
tracking / personalized advertising on every third-party service your app uses for advertising**
— e.g. set your ad SDK's personalized-ads/consent flag to denied, disable your attribution SDK's
data sharing, and do not pass device identifiers to ad networks. Apply this:

- in `OnPoliciesCompleted` (the decision, if any, is final at that point), and
- at every app launch (the stored decision persists; your third-party SDKs generally don't read it
  themselves).

Consult each third-party SDK's own documentation for its consent API — Apollo cannot configure
external SDKs for you.

## 6. What you must NOT do (the Unity (Apollo) SDK handles it)

- **Don't show your own ATT prompt** or ship an ATT native shim — `RequestTrackingAuthorization()`
  is the only supported path; Apollo records the result the instant it resolves. (The old
  `ApplyAttConsentStatus` API no longer exists.)
- **Don't call `ApplyThirdPartyTrackingConsentStatus` from the dialog outcome** — Apollo's dialog
  already calls it on accept/decline (it is what sets the GTS `tpte` flag).
- **Don't set the Firebase Analytics consent from the dialog outcome**, unless you implement
  Firebase Analytics separately from the Unity (Apollo) SDK's implementation.
- **Don't build any GDPR/consent UI** — the built-in dialog covers GDPR opt-in/out and mandatory
  ToU/Privacy-Policy acceptance, including localization and link handling.

## 7. Verify the integration

On a fresh install (device, not Editor):

1. Consent dialog appears at first launch (with `Test` environment + test URL if you're pointed at
   the test service); `WillShowPolicies` then `OnPoliciesCompleted` fire on your listener.
2. iOS: the ATT system prompt appears after the dialog is dismissed; your `IAttListener` logs the
   selection.
3. GTS events after the flow carry the expected `tpte` and `aptts` values (see
   [`CONSENT_DESIGN.md` §7](CONSENT_DESIGN.md#7-what-the-consent-decision-gates) for the mapping).
4. Decline path: your third-party ad SDKs are configured to non-personalized/tracking-off.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No consent dialog, no log activity | `ApolloConsentConfig.json` missing/invalid (consent self-disables — check for the log warning) |
| Dialog never appears but `OnPoliciesCompleted` fires | No outstanding policies for this store/country/language, or a fetch failure — see [`CONSENT_DESIGN.md` §5](CONSENT_DESIGN.md#5-lifecycle--failure-handling) |
| ATT prompt never appears | Listener/request called on Android or in Editor (no-op); `NSUserTrackingUsageDescription` missing; or iOS already has a determined status (result is re-delivered to the listener instead) |
| Consent events reported with wrong environment | `BfgConsent.asset` `environment` still set to `Test` (or asset missing → defaults to `Prod`) |
