# Unity (Apollo) SDK GTS Integration Guide (Game Telemetry Service)

Step-by-step integration of the Unity (Apollo) SDK's GTS telemetry into a game consuming the prebuilt
`bfg.apollo` package. This guide covers **what you must do**; for how the pipeline behaves
(event payloads, queueing/retry rules, session semantics, identity fields, edge cases), see
`GTS_DESIGN.md`. For the full API surface, see the [API Reference](../Apollo_Documentation.md).

GTS is Apollo's core event pipeline — every install, session, purchase, and custom event flows
through it. It is always on: the telemetry subsystem is constructed on every `Initialize()`.
Your game's job is: fill in two config files, register the required adapter/listeners, call
`Initialize()`, and feed the identity fields at the right moments.

---

## 1. Fill in `Assets/Resources/BfgSettings.asset`

The `GameInfos` ScriptableObject the SDK loads from `Resources/BfgSettings` at startup — it is
**required** (initialization dereferences it). Create it via the Unity menu
**BFG → Apollo → Create Missing Settings Files**, then fill in its fields in the Inspector.

It contains two blocks — `IosConfiguration` and `AndroidConfiguration` — each with exactly three
fields. The field-by-field reference (including the Editor-uses-the-Android-block rule and notes
on pre-cleanup assets) lives in
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → BfgSettings.asset](APOLLO_SDK_INTEGRATION_GUIDE.md#bfgsettingsasset--game-configuration).

## 2. Create `Assets/Resources/ApolloNetworkConfig.json`

Routes each `MessageType` to an endpoint. The telemetry endpoint URL and version come from this
file — **not** from `BfgSettings.asset`. Without an entry for a message's type, that message is
never sent (an error is logged).

The full file reference (entry keys, sample content, `MessageType` values, URL construction, and
the test/production `UrlRoot`s) lives in
[`APOLLO_SDK_INTEGRATION_GUIDE.md` → ApolloNetworkConfig.json](APOLLO_SDK_INTEGRATION_GUIDE.md#apollonetworkconfigjson--network-endpoints).
**Make sure your build pipeline ships the production URLs.**

## 3. Code: register, then initialize

All adapters and listeners are registered **before** `BFGUnitySDK.Initialize()` and are
instantiated via reflection — **every registered class needs a public parameterless
constructor.**

```csharp
private void Start()
{
    // Authentication is required for a complete initialization: register a matched
    // adapter + listener pair. Use MockAuthenticationAdapter (shipped with the SDK)
    // until you have a real one.
    BFGUnitySDK.RegisterAdapter<MockAuthenticationAdapter>();
    BFGUnitySDK.RegisterListener<MyAuthListener>();          // IAuthenticationListener

    BFGUnitySDK.RegisterListener<MyTelemetryListener>();     // ITelemetryListener (register one — see below)
    BFGUnitySDK.RegisterListener<MyInitListener>();          // IInitializationListener (optional)

    BFGUnitySDK.Initialize();
}
```

- **Registering an `IAuthenticationListener` without an `IAuthenticationAdapter` prevents
  initialization from ever completing** — always register them as a pair.
- `ITelemetryListener.OnTelemetrySent(bool success, string message)` fires per send result —
  useful during bring-up. **Always register one:** the SDK currently dereferences the listener on
  every event dispatch with no null guard, so the automatic first events throw a
  `NullReferenceException` without it (see `GTS_DESIGN.md` §2.4).
- `IInitializationListener` receives `InitializationComplete()` / `InitializationFailed(reason)`;
  alternatively pass a callback to `BFGUnitySDK.OnInitializationComplete(Action)` (it fires
  immediately if the SDK is already started).
- The reference integration is `Assets/Sample/SDKTest.cs` (with `BasicAuthListener` /
  `BasicTelemetryListener` alongside it).

## 4. Feed the identity fields

These calls populate GTS fields on every event — the timing matters (rules in `GTS_DESIGN.md`):

| Call | When | Feeds |
|---|---|---|
| `BFGUnitySDK.SetAttributionID(id)` | **As early as possible** — from your attribution SDK's callback. Events built before it carry an empty `afid`. On the very first launch, the automatic `install`/`sessionStart` events wait up to 5 seconds for it | GTS `afid` |
| `BFGUnitySDK.SetAppUserId(id)` | After initialization completes (it is a no-op before start), whenever your game assigns its own user id. If never called, Apollo auto-generates a persistent GUID at first launch | GTS `apuid` |
| *(no call — adapter property)* `IAuthenticationAdapter.UserID` | Return your game's authenticated user id from your adapter; Apollo reads it at event-build time | GTS `aupid`; also the user id on consent-reporting events |

`SetAttributionID` is safe to call before initialization completes; the value persists across
launches, so re-set it only when it changes.

Notes on the App User ID (`apuid`): it is distinct from the authentication `UserID` — it
represents the player's identity within *your game* (e.g. an account id from your game server),
while `UserID` comes from an identity provider. Read it back any time with
`BFGUnitySDK.GetAppUserId()` (e.g. for a debug panel); the value persists in PlayerPrefs under
`BFG.Apollo.Telemetry.AppUserId` and survives restarts.

## 5. Send events

### Custom events

Subclass `CustomEventData` (public fields become the event's data payload — serialized with
Newtonsoft.Json) and send:

```csharp
using BFG.Apollo.Telemetry.DataObjects.CustomEvent;

class InventoryChangeEvent : CustomEventData
{
    public string Item;
    public string Status;
}

BFGUnitySDK.SendCustomEvent("InventoryChangeEvent",
    new InventoryChangeEvent { eventName = "InventoryChangeEvent", Item = "Sword", Status = "Drop" });
```

The SDK wraps your payload in the full GTS event envelope (device info, session ids, auth state,
timestamps, attribution id); your subclass's public fields become the event's data object.
`CustomEventData` provides one inherited field, `eventName` — set it on the instance or rely
entirely on the first argument to `SendCustomEvent`.

Only send after initialization completes — calls before start are dropped with a warning. To
send an event immediately at startup, use `BFGUnitySDK.OnInitializationComplete(Action)` (§3).

#### Testing your Custom Event with Swagger

You can test your custom event payload with this Swagger too:
https://mobile.bigfishgames.com/gts/swagger-ui/index.html#/Events/post-custom
(use version 2.2.0 to match the SDK's server version)

### Purchase events

Apollo does not manage the purchase flow — your purchasing library (e.g. Unity IAP) continues to
own it. Apollo's role is purely to report outcomes: call `SendPurchasingSuccessEvent` /
`SendPurchasingFailureEvent` from your purchasing library's callbacks.

If you register an `IPurchasingAdapter`, its entire contract is a single method —
`Initialize(PurchasingConfiguration, IPurchaseListener, IPurchasingInitializationListener)`. The
SDK never issues store commands (fetch product info, start purchase, restore) to the adapter; it
hands the adapter an `IPurchaseListener` at initialization, and the adapter reports purchase
outcomes through that listener's callbacks. The `PurchasingConfiguration` it receives is loaded
from `Resources/PurchasingProductIds.json` — a list of entries each carrying only a `ProductID`:

```json
{
  "ProductIds": [
    { "ProductID": "com.yourstudio.yourgame.gempack1" },
    { "ProductID": "com.yourstudio.yourgame.gempack2" }
  ]
}
```

Either way, the game owns the purchase flow itself.

Report results (fields listed are the complete post-cleanup set —
`receipt`/`signature`/`description`/`errorMessage` no longer exist):

```csharp
using BFG.Apollo.Purchasing;

BFGUnitySDK.SendPurchasingSuccessEvent(new PurchaseSuccessData
{
    productId = "com.yourgame.gems_100",
    price = "4.99",
    currency = "USD",
    transactionID = storeTransactionId,
    uniqueReceiptID = receiptId,
    transactionTimestamp = unixMillis,
    restore = false
});

BFGUnitySDK.SendPurchasingFailureEvent(new PurchaseFailureData
{
    productId = "com.yourgame.gems_100",
    errorCode = code,
    errorReason = PurchaseErrorReason.Canceled,   // your reporting vocabulary
    purchasePhase = PurchasePhase.StoreResponsePhase
});
```

**Restored purchases** use the same success call with `restore = true` — use the store's
localized price *string* rather than computing a decimal value, and pass `0` for
`transactionTimestamp` if the original transaction date is unavailable.

**Choosing `purchasePhase`** — it identifies where in the purchase pipeline the failure happened.
For Unity's built-in IAP library (`com.unity.purchasing`) the recommended mapping is below,
derived from where each `PurchaseFailureReason` is actually raised in Unity IAP's own source
(before any store call, as part of the store's response, or during receipt verification):

| Unity IAP `PurchaseFailureReason` | → `PurchasePhase` | Why |
|---|---|---|
| `PurchasingUnavailable` | `StartPhase` | Device/security-setting restriction, detected before any store contact |
| `StoreNotConnected` | `StartPhase` | Raised before initiating the store round-trip |
| `ExistingPurchasePending` | `PreBuyPhase` | Local pending-transaction check, before proceeding to buy |
| `ProductUnavailable` | `PreBuyPhase` | Raised from local product/cart validation, before any store call |
| `UserCancelled` | `StoreResponsePhase` | Outcome of the store's purchase dialog |
| `PaymentDeclined` | `StoreResponsePhase` | The store's own payment-processing response |
| `DuplicateTransaction` | `StoreResponsePhase` | The store reports the transaction was already processed |
| `PurchaseMissing` | `StoreResponsePhase` | Store billing client responded OK, just without purchase data |
| `SignatureInvalid` | `ClientVerificationPhase` | On-device receipt signature check |
| `ValidationFailure` | `ServerVerificationPhase` | A remote/cloud-hosted receipt-verification service round-trip |
| `Unknown` | `Unknown` | Genuine catch-all; no better phase available |

If you integrate a different purchasing library, its failure reasons may not map to the same
origins — check your library's own documentation before reusing this mapping, and fall back to
`PurchasePhase.Unknown` if it doesn't expose enough detail to distinguish phases.

### Session lifecycle — nothing to integrate

`install`, `sessionStart`, and `sessionEnd` are fired automatically on app
foreground/background. There is no session API to call.

## 6. Verify the integration

**Events are POSTed immediately; failures retry on a 60-second queue pass** — a healthy send
appears on the wire right away, but an event that failed (offline, transient error) waits for
the next queue-processing tick (device logs show `PROCESSING OUTBOUND QUEUE`), so give a
just-reconnected device up to a minute before concluding an event was lost.

1. **Inspect traffic with Charles Proxy** — edit
   `Assets/Resources/BFGAutomationConfiguration.json`:

   ```json
   { "CharlesEnabled": true, "HostIp": "<your Mac's LAN IP>", "HostPort": "8888" }
   ```

   This proxies the SDK's HTTP client on Android and in the Editor. On iOS devices, set the
   proxy in the device's Wi-Fi settings instead. **Ship with `CharlesEnabled: false`.**
2. **Healthy first launch (fresh install):** one `install` and one `sessionStart` POST to the
   GTS endpoint, dispatched as soon as `SetAttributionID` is called (or the 5-second wait
   elapses). Both should carry your `afid`.
3. **Payload spot-check:** correct `UrlRoot`, your `TelemetryKey` attached, `GameStoreId` and
   (iOS) `gcid` present, `afid`/`apuid`/`aupid` populated as expected. Field-by-field reference:
   `GTS_DESIGN.md`.
4. **Send a custom event** and confirm it arrives as `MessageType` 4 traffic;
   your `ITelemetryListener.OnTelemetrySent` logs the result.
5. **Background/foreground the app** and confirm `sessionEnd` / `sessionStart` fire without any
   game code — they fire on every pause/resume (a background longer than 30 s additionally
   rotates the play-session id; details in `GTS_DESIGN.md`).
6. **Device logs** (Logcat / NSLog) are the fastest diagnosis path — send results are logged as
   `MSG: OnNetworkMessageResult <result> <url>`.

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| No events on the wire at all | `ApolloNetworkConfig.json` missing/malformed, or wrong `UrlRoot`; or no network — failed sends wait for the 60-second retry pass, which pings first and skips while offline |
| Log: `network message type does not have a target URL` | The event's `MessageType` has no entry in `ApolloNetworkConfig.json` — add the routing row (§2) |
| Initialization never completes | `IAuthenticationListener` registered without a paired `IAuthenticationAdapter` (§3) — register `MockAuthenticationAdapter` as a stand-in |
| `InvalidOperationException: ... not an approved adapter/listener` at registration | The class doesn't implement a recognized Apollo interface; also ensure a public parameterless constructor |
| Log: `Authentication Required.` | No `IAuthenticationListener` registered at all — register the auth pair (§3) |
| `NullReferenceException` from the telemetry adapter at SDK start | No `ITelemetryListener` registered — register one (§3) |
| Events carry an empty `afid` | `SetAttributionID` called after those events were built — call it earlier (§4) |
| First-launch `install`/`sessionStart` seem delayed | Expected: they wait up to 5 s for `SetAttributionID` (§4, §6) |
| `SendCustomEvent`/`SetAppUserId` logs "Apollo SDK is not started" | Called before initialization completed — gate on `OnInitializationComplete` (§3) |
| Events not visible in Charles | `CharlesEnabled` false or wrong `HostIp`/`HostPort`; on iOS devices use the Wi-Fi proxy settings instead (§6); Charles SSL-proxying not enabled for the GTS host |
| Events reach the test backend in a release build | Build pipeline shipped the test `UrlRoot` — switch to production (§2) |
| Editor events report Android values | By design — the Editor uses the `AndroidConfiguration` block (§1) |
