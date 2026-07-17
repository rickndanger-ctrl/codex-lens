// TODO(meta): The glasses capture layer for Ray-Ban Meta glasses.
//
// This MUST be implemented against Meta's Wearables Device Access Toolkit (iOS).
// NO Meta SDK calls are written here on purpose: the toolkit's exact API is NOT
// yet confirmed in this repo. Every integration point below is a marker, not a
// call — filling them in requires resolving the questions in
// apps/ios/CodexLensApp/ONDEVICE.md → "MUST CONFIRM IN META DOCS" FIRST.
//
// The glasses provide: microphone (input), camera (visual context, explicit
// action only), and open-ear speakers (output). There is NO in-lens display.
//
// This file is on-device scaffold. It is NOT compiled by `swift test` and is NOT
// verified. It does not fake capture — the seams throw `notImplemented` so a
// device build fails loudly rather than pretending audio/video flows.

import Foundation
import CodexLensKit
// TODO(meta): import the Meta DAT SDK modules for the CAMERA path only —
//            MWDATCore (device/permissions) + MWDATCamera (frames), from
//            github.com/facebook/meta-wearables-dat-ios. MWDATMockDevice lets you
//            test without hardware. Delivery (SwiftPM vs xcframework) unconfirmed
//            — see ONDEVICE.md §3.
// Note: AUDIO does NOT use this SDK. The glasses are a Bluetooth audio device, so
//       mic/speaker ride AVFoundation's AVAudioSession (see docs/CAPTURE.md).

enum GlassesCaptureError: Error {
    case notImplemented(String)
    /// Raised deliberately until MUST CONFIRM #1 (continuous vs push-to-talk) is
    /// resolved, so no one wires audio on an unverified assumption.
    case audioModeUnconfirmed
}

/// The capture + output surface bound to the glasses. `WebRTCRealtimeTransport`
/// pulls its mic input and pushes assistant audio through this; the view model
/// triggers camera capture through it. Concrete implementation is device work.
final class MetaGlassesCapture: @unchecked Sendable {

    // MARK: - Connection lifecycle

    /// Discover and connect to the paired glasses via the toolkit.
    func connect() async throws {
        // TODO(meta): use the toolkit to find the paired Ray-Ban Meta glasses
        //            and open a session. Surface disconnect/out-of-range events
        //            so they can drive RealtimeSessionCoordinator.connectionLost.
        //            See ONDEVICE.md MUST CONFIRM #5 and test §7.1 / §7.3.
        throw GlassesCaptureError.notImplemented("MetaGlassesCapture.connect")
    }

    func disconnect() async {
        // TODO(meta): tear down the glasses session cleanly.
    }

    // MARK: - Audio input (MUST CONFIRM #1 gates everything here)

    /// Begin delivering microphone audio to the Realtime session. Per the
    /// reference (docs/CAPTURE.md), this is CONTINUOUS via the standard audio
    /// session — the glasses are a Bluetooth audio device — NOT the DAT SDK.
    func startMicrophone() async throws {
        // TODO(device): configure AVAudioSession (.playAndRecord, options
        //   .allowBluetooth/.allowBluetoothHFP, .defaultToSpeaker); tap the
        //   AVAudioEngine input node; resample to OpenAI Realtime's PCM format
        //   (CONFIRM: pcm16 rate — ONDEVICE.md MUST CONFIRM #2) and stream
        //   continuously into the WebRTC audio track. Verify on hardware that the
        //   glasses are actually the routed input.
        throw GlassesCaptureError.audioModeUnconfirmed
    }

    func stopMicrophone() async {
        // TODO(meta): stop the glasses microphone.
    }

    // MARK: - Audio output

    /// Play the assistant's audio through the glasses' open-ear speakers.
    func playAssistantAudio(_ pcm: Data) async throws {
        // TODO(meta): route playback to the glasses speakers via the toolkit.
        //            Confirm duplex capture+playback (MUST CONFIRM #2).
        _ = pcm
        throw GlassesCaptureError.notImplemented("MetaGlassesCapture.playAssistantAudio")
    }

    // MARK: - Camera (explicit action only — product rule)

    /// Capture visual context from the glasses camera. Called ONLY on an explicit
    /// user action; never continuously.
    func captureVisualContext() async throws -> Data {
        // TODO(meta): via MWDATCamera, take the current camera frame (often
        //            compressed HEVC/H.264 → decode with VideoToolbox → JPEG),
        //            throttled to ~1 fps, on explicit action ONLY — never
        //            continuous (product rule). Then CONFIRM how OpenAI Realtime
        //            accepts the frame (ONDEVICE.md MUST CONFIRM #3 / docs/CAPTURE.md).
        throw GlassesCaptureError.notImplemented("MetaGlassesCapture.captureVisualContext")
    }
}
