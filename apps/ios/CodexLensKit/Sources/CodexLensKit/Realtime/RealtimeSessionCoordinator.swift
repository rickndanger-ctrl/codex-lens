import Foundation

/// Ties the pieces together: fetches a short-lived credential from the gateway,
/// drives the connection state machine, and runs the reconnect-with-backoff
/// loop against an injected `RealtimeTransport`. The sleeper is injected so the
/// backoff is exercised in tests without real delay. No audio here — the
/// transport owns that.
public actor RealtimeSessionCoordinator {
    private let gateway: GatewayClient
    private let transport: RealtimeTransport
    private let policy: ReconnectPolicy
    private let model: String?
    private let sleeper: @Sendable (TimeInterval) async -> Void

    private var machine: RealtimeSessionMachine
    private var credential: RealtimeCredential?

    public init(
        gateway: GatewayClient,
        transport: RealtimeTransport,
        policy: ReconnectPolicy = ReconnectPolicy(),
        model: String? = nil,
        // `_Concurrency.Task` — our `Task` model type shadows the bare name here.
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.gateway = gateway
        self.transport = transport
        self.policy = policy
        self.model = model
        self.sleeper = sleeper
        self.machine = RealtimeSessionMachine(policy: policy)
    }

    public var state: RealtimeState { machine.state }

    /// Establish the session: mint a credential and open the transport.
    @discardableResult
    public func start() async -> RealtimeState {
        machine.handle(.connect)
        do {
            let credential = try await mintCredential()
            try await transport.connect(using: credential)
            machine.handle(.connectionEstablished)
        } catch {
            machine.handle(.fail(reason: reason(from: error)))
        }
        return machine.state
    }

    /// Run the full reconnect sequence after a drop: back off, refresh the
    /// credential when needed, and retry until connected or the policy gives up.
    @discardableResult
    public func connectionLost(reason: String) async -> RealtimeState {
        machine.handle(.connectionLost(reason: reason))
        while case .reconnecting(_, let retryAfter) = machine.state {
            await sleeper(retryAfter)
            do {
                let credential = try await mintCredential(forceRefresh: false)
                try await transport.connect(using: credential)
                machine.handle(.connectionEstablished)
            } catch {
                machine.handle(.connectionLost(reason: self.reason(from: error)))
            }
        }
        return machine.state
    }

    public func stop() async {
        await transport.disconnect()
        machine.handle(.disconnect)
    }

    // MARK: - Internals

    private func mintCredential(forceRefresh: Bool = true) async throws -> RealtimeCredential {
        if !forceRefresh,
           let existing = credential,
           !RealtimeCredentialClock.needsRenewal(existing, now: Date()) {
            return existing
        }
        let fresh = try await gateway.realtimeCredential(model: model)
        credential = fresh
        return fresh
    }

    private func reason(from error: Error) -> String {
        if let gatewayError = error as? GatewayError {
            return String(describing: gatewayError)
        }
        return error.localizedDescription
    }
}
