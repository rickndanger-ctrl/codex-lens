# Codex Lens — On-Device Build & Test Walkthrough

A click-by-click guide to building the iPhone app in Xcode and testing it on a
real device. No prior iOS experience assumed. Everything here is the part that
**cannot** be verified without a phone; the logic it uses (`CodexLensKit`) is
already tested (`swift test`, 27 tests green).

Whenever you see **`TODO(device)`** in the code, this document is the checklist
for filling it in and confirming it on hardware.

---

## 0. Before you start — what you need

- A **Mac with Xcode** installed (App Store → Xcode). Open it once and let it
  install components.
- An **iPhone** and its USB cable.
- A free **Apple ID** (for signing; no paid developer account needed for
  on-device testing).
- The **gateway running on the Mac** (`npm run start` in `~/Foundry/codex-lens`)
  with a real `OPENAI_API_KEY` in its environment, and a `CODEX_LENS_GATEWAY_TOKEN`
  set. Note the token — the phone needs it.
- **Tailscale** on both Mac and iPhone (same tailnet) so the phone can reach the
  Mac's gateway at `http://<mac-tailscale-ip>:8787`. Test it: in the iPhone's
  Safari, open `http://<mac-tailscale-ip>:8787/v1/health` — you should get
  `{"status":"ok",...}`.

> If the gateway isn't running or the token is missing, STOP — you need those
> first. Never paste the OpenAI key into the phone; the phone only ever holds the
> gateway token.

---

## 1. Create the app project

1. Open **Xcode** → **File ▸ New ▸ Project…**
2. Choose **iOS** ▸ **App**, click **Next**.
3. Fill in:
   - **Product Name:** `CodexLensApp`
   - **Interface:** **SwiftUI**
   - **Language:** **Swift**
   - Leave "Use Core Data" and "Include Tests" unchecked.
4. Click **Next**, and save the project **inside `~/Foundry/codex-lens/apps/ios/`**
   (so it sits next to `CodexLensApp/` and `CodexLensKit/`).
5. In the project, select the top-level **CodexLensApp** target ▸ **Signing &
   Capabilities** ▸ set **Team** to your Apple ID (add it with "Add an Account…"
   if needed). Xcode will auto-manage signing.

## 2. Add CodexLensKit as a local package

1. **File ▸ Add Package Dependencies…**
2. Bottom-left, click **Add Local…**
3. Select the folder **`apps/ios/CodexLensKit`** and click **Add Package**.
4. When asked which target to add it to, choose **CodexLensApp**. Click **Add
   Package**.
5. Confirm: in the file navigator you should see **CodexLensKit** under
   "Package Dependencies", and `import CodexLensKit` should compile.

## 3. Add the WebRTC dependency

This is the piece the headless tests can't include.

1. **File ▸ Add Package Dependencies…**
2. In the search box paste: `https://github.com/stasel/WebRTC`
3. Choose the latest version, click **Add Package**, add it to **CodexLensApp**.
   (Alternative: Google's official WebRTC binary framework — heavier setup.)

## 4. Bring in the shell files

1. In Finder, the files `WebRTCRealtimeTransport.swift` and
   `SessionViewModel.swift` already exist in `apps/ios/CodexLensApp/`.
2. Drag them into the Xcode project navigator, under the app group. When
   prompted, check **"Copy items if needed" OFF** (they should stay in place)
   and **add to target CodexLensApp**.

## 5. Info.plist permissions & background audio

1. Select the **CodexLensApp** target ▸ **Info** tab.
2. Add these keys (click the **+**):
   - **Privacy - Microphone Usage Description** →
     `Codex Lens uses the microphone for voice conversation.`
   - **Privacy - Camera Usage Description** →
     `Codex Lens captures visual context only when you choose to.`
3. Target ▸ **Signing & Capabilities** ▸ **+ Capability** ▸ **Background Modes**
   ▸ check **Audio, AirPlay, and Picture in Picture** (so the session survives
   the phone locking).

## 6. Wire the two configuration values

In your app's entry (or a small config file), construct the client with the
Mac's Tailscale address and the gateway token (store the token in the Keychain,
not in source):

```swift
let config = GatewayConfiguration(
    baseURL: URL(string: "http://<mac-tailscale-ip>:8787")!,
    tokenProvider: { KeychainStore.gatewayToken() }   // never the OpenAI key
)
let gateway = GatewayClient(configuration: config)
let transport = WebRTCRealtimeTransport()
let coordinator = RealtimeSessionCoordinator(gateway: gateway, transport: transport)
```

Now fill in each `TODO(device)` in `WebRTCRealtimeTransport.swift` and
`SessionViewModel.swift`, then run the tests in §7 in order.

---

## 7. On-device tests — run each, in order

Attach the iPhone, select it as the run destination (top bar), press **▶︎ Run**.
For each test below: the **action** you take, and the **pass criteria**.

### 7.1 Audio session
- **Fill in:** in `WebRTCRealtimeTransport.connect`, configure `AVAudioSession`
  (`.playAndRecord`, mode `.voiceChat`), request mic permission, route to speaker.
- **Action:** launch the app; tap "Start conversation".
- **Pass:** the iOS mic-permission prompt appears once; after granting, no audio
  errors in the Xcode console; the app reaches `RealtimeState.connecting`.

### 7.2 WebRTC connection using the short-lived credential
- **Fill in:** `connect` fetches a credential via
  `gateway.realtimeCredential()`, opens the `RTCPeerConnection` with
  `credential.value`, completes SDP offer/answer, attaches mic + remote audio.
- **Action:** start a conversation and speak a short sentence.
- **Pass:** you **hear the assistant reply** through the speaker; console shows
  the peer connection reaching `connected`; `coordinator.state == .connected`.
  Confirm the **OpenAI key never appears** on the device (it shouldn't — the
  phone only receives `credential.value`).

### 7.3 Reconnect on ICE change
- **Fill in:** subscribe to `RTCPeerConnection` ICE/connection-state changes;
  on a drop, call `await coordinator.connectionLost(reason:)`.
- **Action:** mid-conversation, toggle the iPhone's Wi-Fi off for ~3 seconds,
  then back on (or walk out of range and back).
- **Pass:** the session shows `reconnecting`, then returns to `connected` and
  audio resumes **without restarting the app**. If it renews the credential
  first, confirm the new one is fetched from the gateway.

### 7.4 Tool-call fulfillment
- **Fill in:** when the model calls `start_task` or `report_progress`
  (`CodexLensTools`), call the matching `GatewayClient` method and send the
  result back via `transport.send(.toolResult(...))`.
- **Action:** talk through a change, approve the plan, and say "go".
- **Pass:** a task is created on the gateway (check the gateway logs / a
  `GET /v1/tasks/<id>`); the assistant confirms it started.

### 7.5 Speaking progress (the cursor in action)
- **Fill in:** after the task starts, poll `SessionViewModel.pollOnce(taskId:)`
  on a timer; speak each fresh `TaskEvent`. Stop when `isTaskComplete`.
- **Pass:** you hear concise spoken updates ("running tests", "the build
  passed") in order, with **no repeats** — proving the cursor only returns new
  events — and it stops on the terminal event.

### 7.6 Background / phone-lock survival
- **Action:** with a task running, **lock the phone** for ~30 seconds, then
  unlock.
- **Pass:** the Mac task keeps running (it's independent of the phone); on
  unlock, the phone reconnects and resumes speaking progress from where it left
  off (the cursor persists), losing no events.

### 7.7 Emergency stop
- **Fill in:** a prominent "Stop" control calls
  `await viewModel.emergencyStop()`, which tears down audio/camera and calls
  `coordinator.stop()`.
- **Action:** during an active session, tap **Stop**.
- **Pass:** audio and any camera capture cease **immediately**; the mic
  indicator turns off; `coordinator.state == .disconnected`.

---

## 8. When all seven pass

You have the Milestone 4 "iPhone Realtime prototype": talk through a project on
the phone, approve the plan, start Codex, and hear the verified result — with
the long-lived key never leaving the Mac. Record any device-specific quirks
(latency, audio routing, background limits) in `docs/BUILD_LOG.md`.
