// TODO(device): On-device scaffold, NOT compiled or verified by `swift test`.
// Needs Xcode + SwiftUI + the live WebRTC transport. The orchestration logic it
// leans on (GatewayClient, RealtimeSessionCoordinator, TaskEventStreamCursor)
// is already verified in CodexLensKit; the device work is wiring this to real
// UI, audio, and the WebRTC transport.

import Foundation
import CodexLensKit
// TODO(device): import SwiftUI, AVFoundation

/// Drives one conversation+task session for the UI. The pieces it composes are
/// tested in CodexLensKit; what remains is on-device wiring (audio, camera, and
/// publishing `SessionEvent`s into SwiftUI @Published state).
@MainActor
final class SessionViewModel {
    private let gateway: GatewayClient
    private let coordinator: RealtimeSessionCoordinator
    private var cursor = TaskEventStreamCursor()

    // TODO(device): @Published var events: [SessionEvent] = []  (needs SwiftUI)
    // TODO(device): @Published var connectionState: RealtimeState = .idle

    init(gateway: GatewayClient, coordinator: RealtimeSessionCoordinator) {
        self.gateway = gateway
        self.coordinator = coordinator
    }

    /// Start talking: open the Realtime session with a short-lived credential.
    func startConversation() async {
        _ = await coordinator.start()
        // TODO(device): publish coordinator.state; begin audio capture/playback.
    }

    /// After the user approves the plan, kick off the Codex task and stream its
    /// verified progress. The polling/cursor logic is tested; the device work is
    /// scheduling the poll loop and speaking each update.
    func runApprovedTask(projectId: String, idempotencyKey: String) async throws {
        let task = try await gateway.createTask(projectId: projectId, idempotencyKey: idempotencyKey)
        // TODO(device): schedule a poll loop that calls pollOnce(taskId:) until
        // the cursor reports isComplete, speaking each fresh progress event.
        _ = task
    }

    /// One tested-shape poll step: fetch only-new events and advance the cursor.
    /// Exposed so a device poll loop reuses the verified cursor contract.
    func pollOnce(taskId: String) async throws -> [TaskEvent] {
        let page = try await gateway.events(taskId: taskId, after: cursor.nextAfter)
        return cursor.ingest(page)
    }

    var isTaskComplete: Bool { cursor.isComplete }

    func emergencyStop() async {
        await coordinator.stop()
        // TODO(device): hard-stop audio capture/playback and camera immediately.
    }
}
