# Glasses Capture Layer — Codex Lens (OpenAI Realtime)

How the on-device glasses capture layer should work for **us**, in plain terms.
De-risked by studying the **VisionClaw** reference (a Gemini-based version of the
same idea) **read-only** — see `apps/ios/CodexLensApp/README.md` for the reference
location and license. We learned the approach; **all Codex Lens code is our own**,
and none of theirs is in this repo.

The one-line difference: VisionClaw embeds a Gemini API key in the app and talks
to Gemini directly. **We keep the OpenAI key on the Mac** and hand the phone a
short-lived credential from our gateway. Everything below flows from that.

---

## The reference pipeline (VisionClaw / Gemini)

```
Ray-Ban Meta glasses
  |  mic audio (continuous)          camera frames (~1 fps)
  v
iPhone app
  |  PCM 16 kHz mono  +  JPEG frames
  v
Gemini Live API  (WebSocket, key embedded in the app)
  |-- audio reply (PCM 24 kHz) --> phone --> glasses speakers
  |-- tool calls --------------> OpenClaw tool gateway
```

## Our pipeline (Codex Lens / OpenAI Realtime)

Same capture; different brain, different **security**, and different transport:

```
Ray-Ban Meta glasses
  |  mic audio (continuous)          camera frames (~1 fps, explicit action only)
  v
iPhone app  ── POST /v1/realtime/credentials ──> OUR GATEWAY (holds the OpenAI key)
  |                                    <── short-lived credential ──
  |  audio (PCM)  +  optional frames
  v
OpenAI Realtime  (WebRTC, opened with the SHORT-LIVED credential)
  |-- audio reply --> phone --> glasses open-ear speakers
  |-- tool calls (start_task / report_progress) --> OUR GATEWAY --> Codex task
```

The OpenAI key **never leaves the Mac**. That is the whole reason the gateway
credential endpoint exists (`docs/M4.md`).

---

## How capture actually works — two SEPARATE channels

This is the key thing the reference taught us: **audio and video come from
different places.**

### Audio — standard iOS audio session (continuous works)

- The glasses pair to the iPhone as a **Bluetooth audio device**. Their
  microphone becomes the normal iOS audio input; their speakers the output.
- So audio uses plain **`AVAudioSession` + `AVAudioEngine`** — category
  `.playAndRecord`, options `.allowBluetooth` / `.allowBluetoothHFP` and
  `.defaultToSpeaker`. **No special DAT audio API is needed.**
- **Continuous, low-latency streaming is viable** — the reference taps the input
  node, resamples, and sends ~100 ms PCM chunks the whole time. This largely
  **answers our earlier top question** ("continuous stream vs push-to-talk"):
  continuous is the default path; push-to-talk is only a fallback.
- Assistant audio plays back through the same session, routing to the glasses'
  open-ear speakers.

### Video — the Meta Wearables DAT SDK (this is what needs the SDK)

- Camera frames come from the **DAT SDK** (`MWDATCamera` / `MWDATCore`), **not**
  the iOS camera APIs.
- Frames arrive as `CMSampleBuffer`, often **compressed (HEVC/H.264)** → decode
  with **VideoToolbox** → pixel buffer → JPEG.
- **Throttle to ~1 fps** — this is visual *context*, not a video feed.
- **Product rule:** capture frames **only on explicit user action** ("what am I
  looking at?"), never continuously.

---

## What our on-device layer MUST implement

- **Audio in:** `AVAudioSession .playAndRecord` + Bluetooth; tap the input node;
  resample to OpenAI Realtime's PCM format; stream continuously.
- **Audio out:** play the model's audio through the session → glasses speakers.
- **Video in:** connect via the DAT SDK; subscribe to camera frames; decode →
  JPEG; throttle ~1 fps; send **only** on explicit action.
- **Session start:** get a short-lived credential from the gateway →  open the
  OpenAI Realtime connection (WebRTC) with it → attach audio → (optionally) send
  frames.
- **Session stop / emergency:** stop the audio tap, stop the DAT camera, close
  the Realtime connection, disconnect the glasses.

The pure logic for the session lifecycle, reconnect, credential renewal, and the
event-stream cursor is **already built and tested** in `CodexLensKit`. What
remains is wiring the two capture channels above into it, on-device.

---

## Where WE differ from the reference — read these before coding

1. **Key server-side (the core difference).** We fetch a short-lived credential
   from the gateway; the phone never holds the OpenAI key. VisionClaw embeds the
   Gemini key in the app.

2. **Audio format — CONFIRM against OpenAI Realtime docs.** The reference used
   **16 kHz in / 24 kHz out** for Gemini. OpenAI Realtime uses `pcm16`; confirm
   the exact sample rate it expects (commonly **24 kHz pcm16** both directions)
   and resample to *that*, not 16 kHz.

3. **Image/vision input — the biggest OpenAI-specific unknown, CONFIRM.** Gemini
   Live natively accepts inline video frames in its realtime input. OpenAI
   Realtime's image handling is different — confirm **whether and how** it accepts
   ~1 fps JPEG frames (e.g. as image content on a conversation item), or whether
   visual context must go through a separate vision call. The ~1 fps camera
   pipeline may need adapting for OpenAI.

4. **Transport.** We use **WebRTC** (recommended for client audio); the reference
   used a WebSocket to Gemini. OpenAI Realtime supports both.

5. **Tools.** Our tool calls hit **our gateway** (`start_task`, `report_progress`
   → a Codex task, per `CodexLensTools`), not OpenClaw's general-purpose skills.

---

## Meta DAT SDK — the facts we confirmed from the reference

- **iOS SDK:** `github.com/facebook/meta-wearables-dat-ios`.
- **Modules:** `MWDATCore` (device discovery, permissions), `MWDATCamera`
  (camera stream), `MWDATMockDevice` (**MockDeviceKit** — lets you exercise the
  flow without physical glasses).
- **Developer mode** is required (see `ONDEVICE.md`): Meta AI app → Settings →
  App Info → tap the **App version 5×** → enable **Developer Mode**.

Everything here is our own design based on the reference's *approach* and on
public SDK facts — no VisionClaw source is copied or vendored.
