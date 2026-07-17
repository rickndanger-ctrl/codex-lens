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

Some of this was **de-risked** by studying the VisionClaw reference (a
Gemini-based build of the same idea) — see `docs/CAPTURE.md`. No Meta SDK calls
are written in our Swift; the points below are marked, not called. Confirm the
**still-open** items against Meta's and OpenAI's **official** docs before writing
the capture layer.

1. **Audio: continuous — LARGELY DE-RISKED (was our top question).**
   The reference shows the glasses pair as a **Bluetooth audio device**, so their
   mic/speakers ride the standard iOS `AVAudioSession` (`.playAndRecord`,
   `.allowBluetooth`/`.allowBluetoothHFP`). It streams **continuously** (~100 ms
   PCM chunks) — **no special DAT audio API and no push-to-talk required.** So the
   default is always-listening; PTT is only a fallback. *Still verify on your
   hardware that the glasses actually route as the audio input/output.*

2. **Audio format — CONFIRM (OpenAI-specific).** The reference used **16 kHz in /
   24 kHz out** for Gemini. OpenAI Realtime uses `pcm16`; confirm its exact
   expected sample rate (commonly **24 kHz pcm16**) and resample to that.

3. **Image/vision input — CONFIRM (the biggest OpenAI-specific unknown).** Gemini
   Live natively accepts inline ~1 fps JPEG frames. OpenAI Realtime handles images
   differently — confirm **whether/how** it accepts camera frames, or whether
   visual context needs a separate vision call. See `docs/CAPTURE.md` §"differ".

4. **Camera via DAT — CONFIRM API details.** Frames come from the DAT SDK
   (`MWDATCamera`), often **compressed (HEVC/H.264)** needing VideoToolbox decode,
   throttled to **~1 fps**, encoded JPEG. Confirm capture is **explicit-action
   only**, never continuous (product rule).

5. **Pairing & session lifecycle** — how `MWDATCore` discovers/connects the
   glasses and what fires on out-of-range / disconnect / battery-dead (drives
   `RealtimeSessionCoordinator.connectionLost(_:)`).

6. **Permissions & entitlements** — which `Info.plist` keys and entitlements the
   toolkit requires, and the developer-preview / Developer-Mode enablement (§0).

7. **Background behavior** — whether the audio session continues while the phone
   is **locked or backgrounded**.

> Items 2 and 3 (OpenAI audio format + image input) are the real remaining
> unknowns; item 1 (continuous audio) is de-risked. See `docs/CAPTURE.md`.

---

## 0. Prerequisites

- A **Mac with Xcode** installed. Open it once and let it install components.
- An **iPhone** and its USB cable, plus a free **Apple ID** (for signing).
- **Ray-Ban Meta glasses**, paired to the iPhone via the **Meta AI app**, with
  up-to-date firmware.
- **Developer Mode enabled in the Meta AI app** (required before the glasses will
  expose the camera to the DAT SDK):
  1. Open the **Meta AI** app on the iPhone.
  2. **Settings** (gear icon, bottom-left).
  3. Tap **App Info**.
  4. Tap the **App version** number **5 times** — this unlocks Developer Mode.
  5. Go back to Settings → turn on the **Developer Mode** toggle.
- **Enrollment in Meta's developer preview for the Wearables Device Access
  Toolkit** may also be required for SDK/entitlement access. *(Confirm the current
  enrollment path and program name in Meta's official developer docs.)*
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

## 3. Add the Meta Wearables Device Access Toolkit (DAT SDK) + WebRTC

1. **Meta DAT SDK (iOS):** add **`github.com/facebook/meta-wearables-dat-ios`**
   to the app, following **Meta's official integration guide**. The modules you
   use:
   - **`MWDATCore`** — device discovery, connection, permissions.
   - **`MWDATCamera`** — the glasses camera stream (video → JPEG frames).
   - **`MWDATMockDevice`** — *MockDeviceKit*, to exercise the flow **without
     physical glasses** (useful for early wiring on the simulator/phone).
   *(Confirm the exact delivery — SwiftPM vs `.xcframework` — and any required
   entitlement in Meta's docs; don't guess it here.)*
   > Audio does **not** need this SDK — the glasses are a Bluetooth audio device,
   > so mic/speaker ride the standard `AVAudioSession` (see `docs/CAPTURE.md`).
   > The DAT SDK is for the **camera**.
2. **WebRTC:** **File ▸ Add Package Dependencies…**, paste
   `https://github.com/stasel/WebRTC`, add to **CodexLensApp**. This carries the
   OpenAI Realtime audio connection.

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
