import XCTest
@testable import CodexLensKit

final class RealtimeSessionMachineTests: XCTestCase {
    func testConnectThenEstablished() {
        var machine = RealtimeSessionMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.connect), .connecting)
        XCTAssertEqual(machine.handle(.connectionEstablished), .connected)
    }

    func testConnectionLossSchedulesBackoffThenReconnects() {
        var machine = RealtimeSessionMachine(policy: ReconnectPolicy(base: 1, maximum: 30, maxAttempts: 6))
        machine.handle(.connect)
        machine.handle(.connectionEstablished)

        XCTAssertEqual(machine.handle(.connectionLost(reason: "drop")), .reconnecting(attempt: 1, retryAfter: 1))
        // Still down → attempt 2, delay doubles.
        XCTAssertEqual(machine.handle(.connectionLost(reason: "drop")), .reconnecting(attempt: 2, retryAfter: 2))
        // A success clears the attempt counter.
        XCTAssertEqual(machine.handle(.connectionEstablished), .connected)
        XCTAssertEqual(machine.handle(.connectionLost(reason: "drop")), .reconnecting(attempt: 1, retryAfter: 1))
    }

    func testBackoffIsCappedAndGivesUp() {
        let policy = ReconnectPolicy(base: 1, maximum: 4, maxAttempts: 3)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 4, "capped at maximum")

        var machine = RealtimeSessionMachine(policy: policy)
        machine.handle(.connect)
        machine.handle(.connectionEstablished)
        machine.handle(.connectionLost(reason: "1"))
        machine.handle(.connectionLost(reason: "2"))
        machine.handle(.connectionLost(reason: "3"))
        // 4th loss exceeds maxAttempts → failed.
        if case .failed = machine.handle(.connectionLost(reason: "4")) {
            // expected
        } else {
            XCTFail("expected .failed after exhausting attempts")
        }
    }

    func testDisconnectAndFail() {
        var machine = RealtimeSessionMachine()
        machine.handle(.connect)
        machine.handle(.connectionEstablished)
        XCTAssertEqual(machine.handle(.disconnect), .disconnected)
        XCTAssertEqual(machine.handle(.fail(reason: "fatal")), .failed(reason: "fatal"))
    }

    func testCredentialRenewalTiming() {
        let credential = RealtimeCredential(
            value: "ek", expiresAt: "2026-07-16T12:00:00.000Z", model: "gpt-realtime"
        )
        let expiry = credential.expiresAtDate!
        // 5 minutes before expiry, with a 60s lead → not yet.
        XCTAssertFalse(RealtimeCredentialClock.needsRenewal(credential, now: expiry.addingTimeInterval(-300), lead: 60))
        // 30s before expiry, with a 60s lead → renew now.
        XCTAssertTrue(RealtimeCredentialClock.needsRenewal(credential, now: expiry.addingTimeInterval(-30), lead: 60))
    }

    func testUnparseableExpiryIsTreatedAsStale() {
        let credential = RealtimeCredential(value: "ek", expiresAt: "not-a-date", model: "m")
        XCTAssertTrue(RealtimeCredentialClock.needsRenewal(credential, now: Date(), lead: 60))
    }
}

// MARK: - Coordinator (gateway + machine + transport tied together)

/// A transport double that fails its first `failuresBeforeSuccess` connects,
/// then succeeds — to exercise the reconnect loop deterministically.
final class FakeRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private(set) var connectCount = 0
    private(set) var disconnected = false

    init(failuresBeforeSuccess: Int = 0) {
        self.remainingFailures = failuresBeforeSuccess
    }

    func connect(using credential: RealtimeCredential) async throws {
        lock.lock(); defer { lock.unlock() }
        connectCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw GatewayError.transport("connect failed")
        }
    }

    func disconnect() async {
        lock.lock(); defer { lock.unlock() }
        disconnected = true
    }

    func send(_ message: RealtimeOutboundMessage) async throws {}
}

final class RealtimeSessionCoordinatorTests: XCTestCase {
    private func makeGateway() -> GatewayClient {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data("""
            { "value": "ek_1", "expiresAt": "2999-01-01T00:00:00.000Z", "model": "gpt-realtime" }
            """.utf8))
        }
        let config = GatewayConfiguration(
            baseURL: URL(string: "http://127.0.0.1:8787")!, tokenProvider: { "t" }
        )
        return GatewayClient(configuration: config, transport: transport)
    }

    func testStartMintsCredentialAndConnects() async {
        let transport = FakeRealtimeTransport()
        let coordinator = RealtimeSessionCoordinator(
            gateway: makeGateway(), transport: transport, sleeper: { _ in }
        )
        let state = await coordinator.start()
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(transport.connectCount, 1)
    }

    func testReconnectLoopRecoversAfterTransientFailures() async {
        let transport = FakeRealtimeTransport(failuresBeforeSuccess: 2)
        let coordinator = RealtimeSessionCoordinator(
            gateway: makeGateway(),
            transport: transport,
            policy: ReconnectPolicy(base: 1, maximum: 5, maxAttempts: 6),
            sleeper: { _ in }  // no real delay
        )
        // The connection drops; the loop retries with backoff until it reconnects.
        let state = await coordinator.connectionLost(reason: "network blip")
        XCTAssertEqual(state, .connected)
        // 2 failed attempts + 1 success.
        XCTAssertEqual(transport.connectCount, 3)
    }

    func testStopDisconnects() async {
        let transport = FakeRealtimeTransport()
        let coordinator = RealtimeSessionCoordinator(
            gateway: makeGateway(), transport: transport, sleeper: { _ in }
        )
        await coordinator.start()
        await coordinator.stop()
        let state = await coordinator.state
        XCTAssertEqual(state, .disconnected)
        XCTAssertTrue(transport.disconnected)
    }
}
