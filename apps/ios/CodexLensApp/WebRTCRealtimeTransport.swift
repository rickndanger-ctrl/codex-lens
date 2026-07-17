// TODO(device): This file is on-device scaffold. It is NOT compiled by
// `swift test` and is NOT verified. It needs Xcode, the WebRTC package, and a
// real iPhone. Do not treat it as working until it is built and exercised on a
// device with live audio.
//
// It intentionally does NOT fake a live connection. Every place that must touch
// real WebRTC/audio throws `notImplemented` so a device build fails loudly
// rather than silently pretending audio flows.

import Foundation
import CodexLensKit
// TODO(device): import WebRTC  // add the WebRTC SwiftPM/binary dependency
// Audio I/O is the GLASSES, not the phone — see MetaGlassesCapture and
// ONDEVICE.md. AVFoundation is only for the WebRTC audio-unit plumbing, NOT for
// the phone's own mic/speaker.

enum DeviceNotImplemented: Error {
    case notImplemented(String)
}

/// The live transport. Conforms to CodexLensKit's `RealtimeTransport`, so the
/// tested `RealtimeSessionCoordinator` drives it unchanged — only the body here
/// is device work.
final class WebRTCRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    func connect(using credential: RealtimeCredential) async throws {
        // TODO(device): create the RTCPeerConnection and complete the SDP
        // offer/answer to OpenAI Realtime using `credential.value` (the
        // SHORT-LIVED secret — never a long-lived key). Wire ICE/connection-state
        // changes to RealtimeSessionCoordinator.connectionLost(_:).
        //
        // TODO(meta): the local audio track is the GLASSES microphone, sourced
        // from MetaGlassesCapture.startMicrophone(), NOT the phone mic. Audio is
        // continuous (glasses = Bluetooth audio device). The remote (assistant)
        // track plays through the glasses' open-ear speakers via
        // MetaGlassesCapture.playAssistantAudio. The one open detail is the exact
        // PCM sample rate/format — pull it from OpenAI's Realtime WebRTC doc
        // (docs/CAPTURE.md, ONDEVICE.md "Remaining wiring TODO #1").
        _ = credential
        throw DeviceNotImplemented.notImplemented("WebRTCRealtimeTransport.connect")
    }

    func disconnect() async {
        // TODO(device): close the peer connection and stop tracks.
        // TODO(meta): stop the glasses mic/playback via MetaGlassesCapture.
    }

    func send(_ message: RealtimeOutboundMessage) async throws {
        // TODO(device): serialize `message` and send it over the Realtime data
        // channel (tool results / user turns).
        _ = message
        throw DeviceNotImplemented.notImplemented("WebRTCRealtimeTransport.send")
    }
}
