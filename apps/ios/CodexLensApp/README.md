# CodexLensApp — on-device shell (Xcode + Ray-Ban Meta glasses)

This directory is the **on-device** half of Milestone 4. Nothing here is built or
verified by `swift test` — it needs Xcode, a real iPhone, **Ray-Ban Meta glasses**
via Meta's Wearables Device Access Toolkit, and live OpenAI Realtime audio. The
headlessly-verified logic it builds on lives in `../CodexLensKit` (green under
`swift test`).

**Device model:** the phone runs the app and holds the gateway/Realtime session
(unchanged); the **glasses** are capture + output — microphone (input), camera
(visual context, explicit action only), open-ear speakers (output). **No in-lens
display, no Neural Band UI** — the interface is voice + audio, phone screen as
fallback controls.

The files here are **scaffold with `TODO(device)` / `TODO(meta)` markers**, not
working audio. No fake pretends to carry audio or connect live.

> **Read `ONDEVICE.md` first** — its "MUST CONFIRM IN META DOCS" section lists
> what has to be verified against Meta's official toolkit docs before writing any
> capture code. Top question: does the toolkit give a **continuous low-latency
> audio stream** (always-listening) or only **clips / push-to-talk**? That
> decides the whole voice UX. No Meta SDK calls are written until it's answered.

## One-time setup (in Xcode, on the Mac with the device attached)

1. Create a new **iOS App** target (SwiftUI lifecycle), e.g. `CodexLensApp`.
2. Add `../CodexLensKit` as a **local Swift package dependency**
   (File → Add Package Dependencies → Add Local → select `apps/ios/CodexLensKit`).
3. Add the **Meta Wearables Device Access Toolkit** (per Meta's official guide —
   delivery mechanism unconfirmed) and a **WebRTC** dependency
   (`stasel/WebRTC` SwiftPM). Neither can be pulled in by `swift test`.
4. Add the files in this directory to the app target.
5. Set Info.plist usage strings + any Meta-required entitlements; enable
   Background Modes → Audio. (See `ONDEVICE.md` §5 — confirm the Meta keys.)

`ONDEVICE.md` is the full click-by-click walkthrough with the eight ordered
on-device tests. The checklist below is the short form; each item is a
`TODO(device)`/`TODO(meta)` in the code and none can be verified off-device.

- [ ] **Glasses connection + mic** (`MetaGlassesCapture`) — connect via the Meta
      toolkit; open the mic per MUST CONFIRM #1 (continuous vs push-to-talk).
- [ ] **WebRTC peer connection** — in `WebRTCRealtimeTransport.connect(using:)`,
      open the connection to OpenAI Realtime using the **short-lived credential**
      from `GatewayClient.realtimeCredential()` (never a long-lived key). The
      local audio track is the **glasses** mic; the remote track plays through
      the **glasses** open-ear speakers.
- [ ] **Interruption/barge-in** — only if MUST CONFIRM #1 says continuous audio;
      otherwise this becomes push-to-talk.
- [ ] **Reconnect** — drive `coordinator.connectionLost(_:)` from glasses
      disconnect events and WebRTC ICE changes.
- [ ] **Tool calls** — when the model calls `start_task` / `report_progress`
      (`CodexLensTools`), fulfill them against `GatewayClient` and stream
      `TaskEvent`s (via `TaskEventStreamCursor`) back as spoken progress.
- [ ] **Camera visual context** — capture from the glasses camera only on
      explicit user action; never continuous (product rule).
- [ ] **Speak progress** — turn `SessionEvent.progress(TaskEvent)` into concise
      spoken updates through the glasses speakers.
- [ ] **Background / out-of-range** — Mac task survives; session recovers on
      reconnect.
- [ ] **Emergency stop** — tears down glasses capture and calls
      `coordinator.stop()` immediately.

## What is already done and verified (in CodexLensKit)

- Gateway client: credential request, task create/get, event paging — with the
  gateway token as the only credential the phone holds.
- Cursor consumer: streams only-new events, never rewinds, detects terminal.
- Session state machine + reconnect backoff + credential-renewal timing.
- Wire types + tool/message schemas matching the gateway.
