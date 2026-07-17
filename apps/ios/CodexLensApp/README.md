# CodexLensApp — on-device shell (Xcode required)

This directory is the **on-device** half of Milestone 4. Nothing here is built
or verified by `swift test` — it needs Xcode, a real iPhone, live OpenAI
Realtime audio, and microphone/camera hardware. The headlessly-verified logic it
builds on lives in `../CodexLensKit` (green under `swift test`).

The files here are **scaffold with `TODO(device)` markers**, not working audio.
No fake pretends to carry audio or connect live — that would be worse than an
honest gap.

## One-time setup (in Xcode, on the Mac with the device attached)

1. Create a new **iOS App** target (SwiftUI lifecycle), e.g. `CodexLensApp`.
2. Add `../CodexLensKit` as a **local Swift package dependency**
   (File → Add Package Dependencies → Add Local → select `apps/ios/CodexLensKit`).
3. Add a WebRTC dependency (e.g. `stasel/WebRTC` SwiftPM, or Google's binary) —
   this is the piece `swift test` cannot pull in headlessly.
4. Add the files in this directory to the app target.
5. Set Info.plist usage strings: `NSMicrophoneUsageDescription`,
   `NSCameraUsageDescription`; enable Background Modes → Audio if the session
   must survive the phone locking.

## The on-device checklist (what must be wired AND tested on a device)

Each item is a `TODO(device)` in the code here. None can be verified off-device.

- [ ] **Audio session** — configure `AVAudioSession` (`.playAndRecord`,
      `.voiceChat`), request mic permission, route to speaker.
- [ ] **WebRTC peer connection** — in `WebRTCRealtimeTransport.connect(using:)`,
      open the peer connection to OpenAI Realtime using the **short-lived
      credential** from `GatewayClient.realtimeCredential()` (never a long-lived
      key). Attach the mic track; handle the remote audio track for playback.
- [ ] **Interruption/barge-in** — let the user talk over the assistant; wire
      `AVAudioSession` interruption notifications into
      `RealtimeSessionMachine`/`RealtimeSessionCoordinator`.
- [ ] **Reconnect on device** — drive `coordinator.connectionLost(_:)` from real
      ICE/connection-state changes and verify audio resumes after a network drop
      and after a Realtime-session credential renewal.
- [ ] **Tool calls** — when the model calls `start_task` / `report_progress`
      (`CodexLensTools`), fulfill them against `GatewayClient` and stream the
      `TaskEvent`s (via `TaskEventStreamCursor`) back as spoken progress.
- [ ] **Camera visual context** — capture a still/short clip only on explicit
      user action; never continuous recording (product rule). Confirm the
      preview and the "stop camera" control.
- [ ] **Speak progress** — turn `SessionEvent.progress(TaskEvent)` into concise
      spoken updates through the glasses/phone speaker.
- [ ] **Background / phone-lock** — verify the Mac task survives the phone
      disconnecting and the session recovers on reconnect (Milestone 6 territory,
      but test the phone-lock path here).
- [ ] **Emergency stop** — a control that tears down audio and calls
      `coordinator.stop()` immediately.

## What is already done and verified (in CodexLensKit)

- Gateway client: credential request, task create/get, event paging — with the
  gateway token as the only credential the phone holds.
- Cursor consumer: streams only-new events, never rewinds, detects terminal.
- Session state machine + reconnect backoff + credential-renewal timing.
- Wire types + tool/message schemas matching the gateway.
