# Codex Lens — On-Device Build & Test Walkthrough (Ray-Ban Meta glasses)

A click-by-click guide to building the iPhone app and testing it with **Ray-Ban
Meta glasses**. No prior iOS experience assumed. Everything here is the part that
**cannot** be verified without hardware; the logic it uses (`CodexLensKit`) is
already tested (`swift test`, 27 tests green).

## The device model

- The **iPhone** runs the app and holds the gateway session (credential flow +
  Realtime session logic — **unchanged** from the phone design).
- The **glasses** are the capture + output surface, reached through **Meta's
  Wearables Device Access Toolkit (iOS)**:
  - **Microphone** — voice input (instead of the phone mic).
  - **Camera** — visual context, on explicit action only.
  - **Open-ear speakers** — the assistant's spoken output.
- **There is NO in-lens display and no Neural Band UI.** Skip anything about
  screens, overlays, or wristband input — the entire interface is voice + audio,
  with the phone screen as a fallback control panel.

Whenever you see **`TODO(meta)`** or **`TODO(device)`** in the code, this
document is the checklist for filling it in and confirming it on hardware.

---

## ⚠️ MUST CONFIRM IN META DOCS (do this FIRST, before writing any capture code)

The Wearables Device Access Toolkit API is **not yet confirmed** in this repo. No
Meta SDK calls are written in the Swift — only marked integration points. Confirm
each of these against Meta's **official** toolkit documentation before building
the capture layer. The answers change the architecture, so resolve them first.

1. **[TOP PRIORITY] Continuous audio, or clips/push-to-talk?**
   Does the toolkit expose a **continuous, low-latency microphone stream**
   suitable for a live OpenAI Realtime session (always-listening, with barge-in)?
   Or does it only provide **short clips / push-to-talk / recorded snippets**?
   - **Continuous low-latency →** always-listening voice, like the phone-mic
     design; feed the stream straight into the Realtime session.
   - **Only clips / PTT →** the UX becomes **push-to-talk**: the user taps to
     speak, releases to send; no barge-in; the Realtime session receives buffered
     turns, not a live stream. **This is a major product/UX fork** — do not build
     the audio path until this is answered.

2. **Audio output** — can the app route the assistant's audio to the glasses'
   open-ear speakers? Is capture + playback **duplex** (simultaneous) or
   half-duplex? (Half-duplex pushes you further toward push-to-talk.)

3. **Camera** — still frames or video? On-demand (user gesture) only? Confirm it
   supports capturing **only on explicit action** — never continuous recording
   (product rule).

4. **Audio format/latency** — sample rate, encoding, and buffer sizes the
   toolkit delivers, and whether they meet OpenAI Realtime's audio input
   requirements or need resampling.

5. **Pairing & session lifecycle** — how the app discovers/connects to the
   glasses, and what events fire on out-of-range / disconnect / battery-dead.
   (These drive `RealtimeSessionCoordinator.connectionLost(_:)`.)

6. **Permissions & entitlements** — which `Info.plist` keys, app entitlements,
   and developer-preview approvals the toolkit requires.

7. **Background behavior** — whether the glasses audio session can continue while
   the phone is **locked or backgrounded**.

> Until #1 is answered, treat the audio path as **UNKNOWN**. Do not assume
> always-listening, and do not write the capture code.

---

## 0. Prerequisites

- A **Mac with Xcode** installed. Open it once and let it install components.
- An **iPhone** and its USB cable, plus a free **Apple ID** (for signing).
- **Ray-Ban Meta glasses**, paired to the iPhone via the **Meta AI app**, with
  up-to-date firmware.
- **Enrollment in Meta's developer preview for the Wearables Device Access
  Toolkit.** Access is gated — you must be approved before the SDK and its
  entitlements work. *(Confirm the exact enrollment path and current program name
  in Meta's official developer docs — see "MUST CONFIRM" above.)*
- The **gateway running on the Mac** (`npm run start` in `~/Foundry/codex-lens`)
  with a real `OPENAI_API_KEY` in its environment and a `CODEX_LENS_GATEWAY_TOKEN`
  set. Note the token — the phone needs it (never the OpenAI key).
- **Tailscale** on Mac + iPhone (same tailnet). Test from iPhone Safari:
  `http://<mac-tailscale-ip>:8787/v1/health` → `{"status":"ok",...}`.

> If the gateway isn't running, the token is missing, or you're not enrolled in
> Meta's preview, STOP — resolve those first. The OpenAI key never goes on the
> phone or glasses; the phone only holds the gateway token.

---

## 1. Create the app project

1. **Xcode ▸ File ▸ New ▸ Project…**
2. **iOS ▸ App**, **Next**.
3. **Product Name:** `CodexLensApp`; **Interface:** SwiftUI; **Language:** Swift.
   Leave Core Data / Tests unchecked.
4. **Next**, save it **inside `~/Foundry/codex-lens/apps/ios/`**.
5. Select the **CodexLensApp** target ▸ **Signing & Capabilities** ▸ set **Team**
   to your Apple ID (Xcode auto-manages signing).

## 2. Add CodexLensKit as a local package

1. **File ▸ Add Package Dependencies… ▸ Add Local…**
2. Select **`apps/ios/CodexLensKit`** ▸ **Add Package** ▸ add to **CodexLensApp**.
3. Confirm `import CodexLensKit` compiles.

## 3. Add the Meta Wearables Device Access Toolkit + WebRTC

1. **Meta toolkit:** follow **Meta's official integration guide** to add the
   Wearables Device Access Toolkit to the app.
   *(Confirm the delivery mechanism — SwiftPM URL, `.xcframework`, required
   entitlement — in Meta's docs. Do not guess it here.)*
2. **WebRTC:** **File ▸ Add Package Dependencies…**, paste
   `https://github.com/stasel/WebRTC`, add to **CodexLensApp**. This carries the
   Realtime audio connection.

## 4. Bring in the shell files

The files in `apps/ios/CodexLensApp/` already exist. Drag these into the Xcode
project (add to target **CodexLensApp**, "Copy items if needed" OFF):
`WebRTCRealtimeTransport.swift`, `MetaGlassesCapture.swift`, `SessionViewModel.swift`.

## 5. Permissions & entitlements

1. Target ▸ **Info** ▸ add:
   - **Privacy - Microphone Usage Description** →
     `Codex Lens uses the glasses microphone for voice conversation.`
   - **Privacy - Camera Usage Description** →
     `Codex Lens captures visual context from the glasses only when you choose to.`
2. Target ▸ **Signing & Capabilities** ▸ **+ Capability** ▸ **Background Modes**
   ▸ check **Audio, AirPlay, and Picture in Picture**.
3. **Add whatever entitlement / Info.plist keys the Meta toolkit requires**
   *(confirm in Meta docs — MUST CONFIRM #6). Likely Bluetooth/companion-device
   related, but do not invent the keys.*

## 6. Wire the two configuration values (gateway flow — unchanged)

```swift
let config = GatewayConfiguration(
    baseURL: URL(string: "http://<mac-tailscale-ip>:8787")!,
    tokenProvider: { KeychainStore.gatewayToken() }   // never the OpenAI key
)
let gateway = GatewayClient(configuration: config)
let transport = WebRTCRealtimeTransport()             // audio I/O bridges to glasses
let coordinator = RealtimeSessionCoordinator(gateway: gateway, transport: transport)
```

The credential flow and Realtime session logic are identical to the phone design.
Only the **capture layer** (mic/camera/speaker) changes: it binds to the glasses
via `MetaGlassesCapture` instead of the phone hardware. Fill in every `TODO(meta)`
/ `TODO(device)` after resolving "MUST CONFIRM", then run §7 in order.

---

## 7. On-device tests — run each, in order (glasses attached)

Attach the iPhone, select it as the run destination, press **▶︎ Run**. For each:
the **action** you take and the **pass criteria**. (No display test — the glasses
have no screen.)

### 7.1 Glasses connection + audio input via the toolkit
- **Fill in (`MetaGlassesCapture`):** discover and connect to the paired glasses
  through the toolkit; open the microphone input per MUST CONFIRM #1.
- **Action:** launch the app; tap "Start conversation".
- **Pass:** the app reports the glasses connected; the mic-permission prompt
  appears once; no audio errors in the Xcode console; the session reaches
  `RealtimeState.connecting`.

### 7.2 Realtime connection using the glasses mic + short-lived credential
- **Fill in (`WebRTCRealtimeTransport.connect`):** fetch a credential via
  `gateway.realtimeCredential()`, open the WebRTC peer connection with
  `credential.value`, and feed it the **glasses** mic stream from
  `MetaGlassesCapture` (not the phone mic).
- **Action:** speak a short sentence.
- **Pass:** you **hear the assistant reply through the glasses' open-ear
  speakers**; console shows the peer connection `connected`;
  `coordinator.state == .connected`. Confirm the **OpenAI key never appears** on
  phone or glasses (only `credential.value` does).

### 7.3 Reconnect on glasses/network drop
- **Fill in:** map toolkit disconnect events and WebRTC ICE changes to
  `await coordinator.connectionLost(reason:)`.
- **Action:** step out of Bluetooth range of the glasses for a few seconds (or
  toggle Wi-Fi), then return.
- **Pass:** state shows `reconnecting`, then `connected`; audio resumes without
  restarting the app; a renewed credential is fetched if the old one expired.

### 7.4 Tool-call fulfillment
- **Fill in:** when the model calls `start_task` / `report_progress`
  (`CodexLensTools`), call the matching `GatewayClient` method and return the
  result via `transport.send(.toolResult(...))`.
- **Action:** talk through a change, approve the plan, say "go".
- **Pass:** a task is created on the gateway (check gateway logs /
  `GET /v1/tasks/<id>`); the assistant confirms it started.

### 7.5 Speaking progress through the glasses (the cursor in action)
- **Fill in:** poll `SessionViewModel.pollOnce(taskId:)` on a timer; speak each
  fresh `TaskEvent` through the glasses speakers. Stop when `isTaskComplete`.
- **Pass:** concise spoken updates in order, **no repeats** (proving the cursor
  only returns new events), stopping on the terminal event.

### 7.6 Camera visual context (glasses camera, explicit action only)
- **Fill in (`MetaGlassesCapture`):** capture a still/short clip from the glasses
  camera **only** on an explicit user action; never continuous.
- **Action:** trigger a "look at this" capture, then a "stop camera" control.
- **Pass:** a frame is captured and attached to the conversation only on the
  explicit action; no capture happens otherwise; the stop control works.

### 7.7 Background / out-of-range survival
- **Action:** with a task running, lock the phone (and/or step out of glasses
  range) for ~30 seconds, then return.
- **Pass:** the Mac task keeps running; on return the session reconnects and
  resumes speaking progress from where it left off (the cursor persists), losing
  no events. *(Confirm background audio behavior against MUST CONFIRM #7.)*

### 7.8 Emergency stop
- **Fill in:** a prominent "Stop" control calls `await viewModel.emergencyStop()`,
  which tears down the glasses capture and calls `coordinator.stop()`.
- **Action:** during an active session, tap **Stop** (on the phone).
- **Pass:** glasses mic/camera capture and audio playback cease **immediately**;
  `coordinator.state == .disconnected`.

---

## 8. When all eight pass

You have the Milestone 4 prototype on Ray-Ban Meta glasses: talk through a
project hands-free, approve the plan, start Codex, and hear the verified result
through the open-ear speakers — with the long-lived key never leaving the Mac,
and no in-lens display required. Record any device-specific findings (audio
latency, continuous-vs-PTT reality, background limits) in `docs/BUILD_LOG.md`.
