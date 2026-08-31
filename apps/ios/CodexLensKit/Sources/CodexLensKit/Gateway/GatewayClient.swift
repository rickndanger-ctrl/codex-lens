import Foundation

/// How to reach the Mac gateway. The token here is the GATEWAY bearer token —
/// it grants gateway access only. There is deliberately no field for an OpenAI
/// key: the phone never holds one, and this type makes that structural.
public struct GatewayConfiguration: Sendable {
    public let baseURL: URL
    /// Provides the current gateway bearer token. A closure so a rotated token
    /// is picked up without rebuilding the client.
    public let tokenProvider: @Sendable () -> String

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () -> String) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }
}

/// Calls the Codex Lens gateway: mints short-lived Realtime credentials, creates
/// and polls tasks, and pages the event stream. Foundation-only and fully
/// testable through an injected `Transport`.
public struct GatewayClient: Sendable {
    private let configuration: GatewayConfiguration
    private let transport: Transport
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(configuration: GatewayConfiguration, transport: Transport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Realtime credential

    /// Trades the gateway token for a short-lived OpenAI Realtime credential.
    /// The long-lived key stays on the Mac; this returns only the ephemeral one.
    public func realtimeCredential(model: String? = nil) async throws -> RealtimeCredential {
        var body: [String: String] = [:]
        if let model { body["model"] = model }
        let request = try makeRequest(method: "POST", path: "/v1/realtime/credentials", jsonBody: body)
        return try await perform(request, as: RealtimeCredential.self)
    }

    // MARK: - Live public web research

    public func researchWeb(question: String) async throws -> WebResearchResult {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/web/research",
            jsonBody: ["question": question]
        )
        return try await perform(request, as: WebResearchResult.self)
    }

    // MARK: - Tasks

    /// Loads only the repositories and policy flags allowlisted by the Mac.
    public func approvedProjects() async throws -> ApprovedProjectsResponse {
        let request = try makeRequest(method: "GET", path: "/v1/projects")
        return try await perform(request, as: ApprovedProjectsResponse.self)
    }

    /// Asks Codex to inspect one gateway-approved repository without editing it.
    public func inspectCodexProject(projectId: String, question: String) async throws -> CodexProjectInspection {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/codex/inspect",
            jsonBody: ["projectId": projectId, "question": question]
        )
        return try await perform(request, as: CodexProjectInspection.self)
    }

    public func createTask(
        projectId: String,
        idempotencyKey: String,
        requestedPath: String? = nil
    ) async throws -> CodexTask {
        var body: [String: String] = ["projectId": projectId, "idempotencyKey": idempotencyKey]
        if let requestedPath { body["requestedPath"] = requestedPath }
        let request = try makeRequest(method: "POST", path: "/v1/tasks", jsonBody: body)
        return try await perform(request, as: CodexTask.self)
    }

    public func task(id: String) async throws -> CodexTask {
        let request = try makeRequest(method: "GET", path: "/v1/tasks/\(escape(id))")
        return try await perform(request, as: CodexTask.self)
    }

    /// One page of the event stream. Pass the last `nextCursor` you saw as
    /// `after`; you receive only events with `seq > after`. Omit for the backlog.
    public func events(taskId: String, after: Int? = nil) async throws -> TaskEventsPage {
        var path = "/v1/tasks/\(escape(taskId))/events"
        if let after { path += "?after=\(after)" }
        let request = try makeRequest(method: "GET", path: path)
        return try await perform(request, as: TaskEventsPage.self)
    }

    // MARK: - Computer inspection

    /// Reads only the frontmost Mac application name through the sub-second
    /// macOS fast path. It does not capture the screen or start Computer Use.
    public func frontmostComputerApp() async throws -> FrontmostComputerApp {
        let request = try makeRequest(method: "GET", path: "/v1/computer/frontmost")
        return try await perform(request, as: FrontmostComputerApp.self)
    }

    /// Opens or activates one named Mac app through the deterministic gateway
    /// fast path, then returns only after macOS confirms it is frontmost.
    public func focusComputerApp(app: String) async throws -> FocusedComputerApp {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/computer/focus",
            jsonBody: ["app": app]
        )
        return try await perform(request, as: FocusedComputerApp.self)
    }

    /// Closes only the current main Mac window. The target app keeps ownership
    /// of any unsaved-changes prompt; the gateway never chooses a response.
    public func closeFrontmostComputerWindow() async throws -> ClosedComputerWindow {
        let request = try makeRequest(method: "POST", path: "/v1/computer/close-window")
        return try await perform(request, as: ClosedComputerWindow.self)
    }

    /// Minimizes or restores only the current main Mac window and returns only
    /// after the gateway verifies the resulting accessibility state.
    public func setFrontmostComputerWindowState(action: String) async throws -> ComputerWindowStateResult {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/computer/window-state",
            jsonBody: ["action": action]
        )
        return try await perform(request, as: ComputerWindowStateResult.self)
    }

    /// Asks the Mac gateway for one read-only accessibility inspection.
    public func inspectComputer(app: String, question: String) async throws -> ComputerInspection {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/computer/inspect",
            jsonBody: ["app": app, "question": question]
        )
        return try await perform(request, as: ComputerInspection.self)
    }

    /// Runs one ordinary, reversible voice-directed Mac or browser action.
    /// Consequential steps are refused by the gateway and must use the bound
    /// prepare/readback/confirm path below.
    public func useComputerAction(
        instruction: String,
        surface: String = "auto"
    ) async throws -> ComputerActionResult {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/computer/use",
            jsonBody: ["instruction": instruction, "surface": surface]
        )
        return try await perform(request, as: ComputerActionResult.self)
    }

    /// Binds one exact Mac/Chrome instruction without executing it.
    public func prepareComputerAction(
        instruction: String,
        surface: String = "auto"
    ) async throws -> PreparedComputerAction {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/computer/prepare",
            jsonBody: ["instruction": instruction, "surface": surface]
        )
        return try await perform(request, as: PreparedComputerAction.self)
    }

    /// Consumes one exact prepared action after the phone verifies a later
    /// spoken confirmation. Never retry automatically after an uncertain call.
    public func executePreparedComputerAction(
        confirmationId: String,
        digest: String
    ) async throws -> ComputerActionResult {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/computer/execute",
            jsonBody: ["confirmationId": confirmationId, "digest": digest]
        )
        return try await perform(request, as: ComputerActionResult.self)
    }

    // MARK: - Confirmation-gated Messages

    /// Resolves a contact and prepares an exact preview. This never sends.
    public func prepareTextMessage(
        recipient: String,
        message: String,
        serviceType: MessageServiceType
    ) async throws -> PreparedTextMessage {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/messages/prepare",
            jsonBody: [
                "recipient": recipient,
                "message": message,
                "serviceType": serviceType.rawValue,
            ]
        )
        return try await perform(request, as: PreparedTextMessage.self)
    }

    /// Sends only the exact, unexpired preview identified by this bound pair.
    public func sendPreparedText(confirmationId: String, digest: String) async throws -> SentTextMessage {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/messages/send",
            jsonBody: ["confirmationId": confirmationId, "digest": digest]
        )
        return try await perform(request, as: SentTextMessage.self)
    }

    /// Reads the durable, redacted outcome of one message intent. This never
    /// retries a send and never returns the message body.
    public func textMessageStatus(confirmationId: String) async throws -> MessageIntentStatus {
        let request = try makeRequest(
            method: "GET",
            path: "/v1/messages/\(escape(confirmationId))/status"
        )
        return try await perform(request, as: MessageIntentStatus.self)
    }

    /// Checks Contacts permission and enabled/connected Messages services.
    /// This is read-only and cannot send.
    public func textMessageReadiness() async throws -> MessageReadiness {
        let request = try makeRequest(method: "GET", path: "/v1/messages/readiness")
        return try await perform(request, as: MessageReadiness.self)
    }

    // MARK: - Internals

    private func makeRequest(
        method: String,
        path: String,
        jsonBody: [String: String]? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL) else {
            throw GatewayError.transport("Bad URL for path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // The ONLY credential the phone presents is the gateway token.
        request.setValue("Bearer \(configuration.tokenProvider())", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(jsonBody)
        }
        return request
    }

    private func perform<Value: Decodable>(_ request: URLRequest, as _: Value.Type) async throws -> Value {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch let error as GatewayError {
            throw error
        } catch {
            throw GatewayError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw mapError(status: response.statusCode, data: data)
        }

        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw GatewayError.decoding("Could not decode \(Value.self): \(error.localizedDescription)")
        }
    }

    private func mapError(status: Int, data: Data) -> GatewayError {
        let message = (try? decoder.decode(GatewayErrorBody.self, from: data))?.message
            ?? "Request failed with status \(status)"
        switch status {
        case 400: return .badRequest(message)
        case 401: return .unauthorized(message)
        case 404: return .notFound(message)
        case 422: return .unprocessable(message)
        case 503: return .realtimeUnavailable(message)
        default: return .unexpectedStatus(status, message)
        }
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }
}
