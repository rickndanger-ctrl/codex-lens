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
// TODO(device): import WebRTC        // add the WebRTC SwiftPM/binary dependency
// TODO(device): import AVFoundation  // for AVAudioSession + mic/speaker routing

enum DeviceNotImplemented: Error {
    case notImplemented(String)
}

/// The live transport. Conforms to CodexLensKit's `RealtimeTransport`, so the
/// tested `RealtimeSessionCoordinator` drives it unchanged — only the body here
/// is device work.
final class WebRTCRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    func connect(using credential: RealtimeCredential) async throws {
        // TODO(device): configure AVAudioSession (.playAndRecord, .voiceChat),
        // request mic permission, create the RTCPeerConnection, add the local
        // mic track, and complete the SDP offer/answer to OpenAI Realtime using
        // `credential.value` (the SHORT-LIVED secret — never a long-lived key).
        // Attach the remote audio track for playback. Wire ICE/connection-state
        // changes to RealtimeSessionCoordinator.connectionLost(_:).
        _ = credential
        throw DeviceNotImplemented.notImplemented("WebRTCRealtimeTransport.connect")
    }

    func disconnect() async {
        // TODO(device): close the peer connection, stop tracks, deactivate the
        // audio session.
    }

    func send(_ message: RealtimeOutboundMessage) async throws {
        // TODO(device): serialize `message` and send it over the Realtime data
        // channel (tool results / user turns).
        _ = message
        throw DeviceNotImplemented.notImplemented("WebRTCRealtimeTransport.send")
    }
}
