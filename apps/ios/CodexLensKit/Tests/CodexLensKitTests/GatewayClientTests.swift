import XCTest
@testable import CodexLensKit

/// A deterministic transport that records the request it was given and returns
/// a canned response — no network under test.
final class StubTransport: Transport, @unchecked Sendable {
    struct Response { let status: Int; let body: Data }
    private let handler: @Sendable (URLRequest) -> Response
    private(set) var lastRequest: URLRequest?

    init(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil
        )!
        return (response.body, http)
    }
}

final class GatewayClientTests: XCTestCase {
    func testResearchWebUsesReadOnlyGatewayEndpoint() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data("""
            {"answer":"A current answer.","sources":[{"title":"Official source","url":"https://example.com/source"}],"searched":true}
            """.utf8))
        }
        let client = GatewayClient(
            configuration: GatewayConfiguration(
                baseURL: URL(string: "https://gateway.test")!,
                tokenProvider: { "gateway-token" }
            ),
            transport: transport
        )

        let result = try await client.researchWeb(question: "What happened today?")
        XCTAssertEqual(result.answer, "A current answer.")
        XCTAssertEqual(result.sources.first?.title, "Official source")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/web/research")
        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
    }
    func testApprovedProjectsUsesProtectedReadOnlyRoute() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/projects")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            return .init(status: 200, body: Data("""
            {
              "projects": [{
                "id": "sample-project",
                "displayName": "Sample Project",
                "path": "/tmp/sample-project",
                "allowedCommands": ["npm test"],
                "allowWorkspaceWrite": true,
                "allowDependencyInstall": false,
                "allowCommit": false,
                "allowPush": false,
                "allowDeploy": false
              }]
            }
            """.utf8))
        }
        let client = GatewayClient(
            configuration: GatewayConfiguration(
                baseURL: URL(string: "http://127.0.0.1:8787")!,
                tokenProvider: { "t" }
            ),
            transport: transport
        )

        let response = try await client.approvedProjects()
        XCTAssertEqual(response.projects.map(\.id), ["sample-project"])
        XCTAssertTrue(response.projects[0].allowWorkspaceWrite)
        XCTAssertFalse(response.projects[0].allowDeploy)
    }

    func testInspectCodexProjectBindsSelectedProjectAndQuestion() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/codex/inspect")
            let body = try! JSONDecoder().decode([String: String].self, from: request.httpBody!)
            XCTAssertEqual(body, ["projectId": "sample-project", "question": "What is unfinished?"])
            return .init(status: 200, body: Data("""
            {
              "projectId": "sample-project",
              "projectName": "Sample Project",
              "summary": "One verified item remains.",
              "files": ["src/calculator.js"],
              "readOnly": true
            }
            """.utf8))
        }
        let client = GatewayClient(
            configuration: GatewayConfiguration(
                baseURL: URL(string: "http://127.0.0.1:8787")!,
                tokenProvider: { "t" }
            ),
            transport: transport
        )
        let result = try await client.inspectCodexProject(
            projectId: "sample-project",
            question: "What is unfinished?"
        )
        XCTAssertTrue(result.readOnly)
        XCTAssertEqual(result.files, ["src/calculator.js"])
    }

    private func makeClient(_ transport: StubTransport) -> GatewayClient {
        let config = GatewayConfiguration(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            tokenProvider: { "gateway-token-123" }
        )
        return GatewayClient(configuration: config, transport: transport)
    }

    func testRealtimeCredentialSendsGatewayTokenAndNeverAnOpenAIKey() async throws {
        let transport = StubTransport { _ in
            return .init(status: 200, body: Data("""
            { "value": "ek_1", "expiresAt": "2026-07-16T12:00:00.000Z", "model": "gpt-realtime" }
            """.utf8))
        }
        let client = makeClient(transport)

        let credential = try await client.realtimeCredential(model: "gpt-realtime")

        XCTAssertEqual(credential.value, "ek_1")
        let auth = transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer gateway-token-123")
        // The request body carries only the model — never a key.
        let body = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("gpt-realtime"))
        XCTAssertFalse(body.lowercased().contains("apikey"))
        XCTAssertFalse(body.lowercased().contains("sk-"))
    }

    func testCredentialUnavailableMapsTo503Retryable() async throws {
        let transport = StubTransport { _ in
            .init(status: 503, body: Data("""
            { "statusCode": 503, "error": "Service Unavailable", "message": "not configured" }
            """.utf8))
        }
        let client = makeClient(transport)

        do {
            _ = try await client.realtimeCredential()
            XCTFail("expected an error")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .realtimeUnavailable("not configured"))
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testUnauthorizedMaps() async throws {
        let transport = StubTransport { _ in
            .init(status: 401, body: Data("""
            { "statusCode": 401, "error": "Unauthorized", "message": "bad token" }
            """.utf8))
        }
        do {
            _ = try await makeClient(transport).task(id: "task_1")
            XCTFail("expected an error")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .unauthorized("bad token"))
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testEventsSendsCursorInQuery() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data(#"{ "events": [], "nextCursor": 4 }"#.utf8))
        }
        let client = makeClient(transport)

        let page = try await client.events(taskId: "task 1", after: 4)

        XCTAssertEqual(page.nextCursor, 4)
        let url = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/v1/tasks/task%201/events"), "task id is percent-encoded: \(url)")
        XCTAssertTrue(url.contains("after=4"))
    }

    func testEventsWithoutCursorOmitsQuery() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data(#"{ "events": [], "nextCursor": -1 }"#.utf8))
        }
        _ = try await makeClient(transport).events(taskId: "task_1")
        XCTAssertFalse((transport.lastRequest?.url?.absoluteString ?? "").contains("after="))
    }

    func testCreateTaskPostsIdempotencyKey() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data("""
            { "id": "task_1", "projectId": "p", "state": "queued", "idempotencyKey": "k1",
              "createdAt": "2026-07-16T00:00:00.000Z", "updatedAt": "2026-07-16T00:00:00.000Z" }
            """.utf8))
        }
        let client = makeClient(transport)
        let task = try await client.createTask(projectId: "p", idempotencyKey: "k1")
        XCTAssertEqual(task.state, .queued)
        let body = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("k1"))
    }

    func testPrepareTextMessageUsesNonSendingEndpoint() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data("""
            { "confirmationId": "confirm-1", "digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "recipientDisplay": "Alex Example", "maskedDestination": "••••0123",
              "message": "I am on my way.", "serviceType": "iMessage",
              "expiresAt": "2026-08-26T19:05:00.000Z",
              "requiresExplicitConfirmation": true }
            """.utf8))
        }
        let prepared = try await makeClient(transport).prepareTextMessage(
            recipient: "Alex Example",
            message: "I am on my way.",
            serviceType: .iMessage
        )
        XCTAssertEqual(prepared.recipientDisplay, "Alex Example")
        XCTAssertEqual(prepared.serviceType, .iMessage)
        XCTAssertTrue(prepared.requiresExplicitConfirmation)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/messages/prepare")
        let body = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"serviceType\":\"iMessage\""))
    }

    func testPrepareAndExecuteComputerActionUseBoundEndpoints() async throws {
        let transport = StubTransport { request in
            if request.url?.path == "/v1/computer/prepare" {
                return .init(status: 200, body: Data("""
                { "confirmationId": "computer-1",
                  "digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "instruction": "Open the current project page in Chrome.",
                  "surface": "chrome", "expiresAt": "2026-08-26T19:05:00.000Z",
                  "requiresExplicitConfirmation": true }
                """.utf8))
            }
            return .init(status: 200, body: Data("""
            { "completed": true, "confirmationRequired": false,
              "summary": "Opened the requested page.", "surface": "chrome" }
            """.utf8))
        }
        let client = makeClient(transport)
        let prepared = try await client.prepareComputerAction(
            instruction: "Open the current project page in Chrome.",
            surface: "chrome"
        )
        XCTAssertTrue(prepared.requiresExplicitConfirmation)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/computer/prepare")

        let result = try await client.executePreparedComputerAction(
            confirmationId: prepared.confirmationId,
            digest: prepared.digest
        )
        XCTAssertTrue(result.completed)
        XCTAssertFalse(result.confirmationRequired)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/computer/execute")
        let body = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("computer-1"))
        XCTAssertFalse(body.contains("Open the current project page"))
    }

    func testUseComputerActionUsesDirectOrdinaryEndpoint() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data("""
            { "completed": true, "confirmationRequired": false,
              "summary": "Brought Xcode to the front.", "surface": "computer" }
            """.utf8))
        }
        let result = try await makeClient(transport).useComputerAction(
            instruction: "Bring Xcode to the front.",
            surface: "computer"
        )
        XCTAssertTrue(result.completed)
        XCTAssertFalse(result.confirmationRequired)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/computer/use")
        let body = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("Bring Xcode to the front."))
        XCTAssertTrue(body.contains("computer"))
    }

    func testFrontmostComputerAppUsesReadOnlyFastEndpoint() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data(#"{ "app": "Visual Studio Code", "windowTitle": "Welcome — KitchenCapture", "readOnly": true }"#.utf8))
        }
        let result = try await makeClient(transport).frontmostComputerApp()
        XCTAssertEqual(result.app, "Visual Studio Code")
        XCTAssertEqual(result.windowTitle, "Welcome — KitchenCapture")
        XCTAssertTrue(result.readOnly)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/computer/frontmost")
        XCTAssertNil(transport.lastRequest?.httpBody)
    }

    func testFocusComputerAppUsesDeterministicFastEndpoint() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data(#"{ "app": "Visual Studio Code", "frontmost": true }"#.utf8))
        }
        let result = try await makeClient(transport).focusComputerApp(app: "VS Code")
        XCTAssertEqual(result.app, "Visual Studio Code")
        XCTAssertTrue(result.frontmost)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/computer/focus")
        let body = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("VS Code"))
    }

    func testCloseFrontmostComputerWindowNeverIncludesAConfirmationChoice() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data(#"{ "app": "Xcode", "windowTitle": "CodexLensApp", "closed": true, "needsUserDecision": false }"#.utf8))
        }
        let result = try await makeClient(transport).closeFrontmostComputerWindow()
        XCTAssertTrue(result.closed)
        XCTAssertFalse(result.needsUserDecision)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/computer/close-window")
        XCTAssertNil(transport.lastRequest?.httpBody)
    }

    func testSendPreparedTextUsesBoundConfirmationOnly() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data("""
            { "sent": true, "recipientDisplay": "Alex Example", "serviceType": "iMessage",
              "sentAt": "2026-08-26T19:01:00.000Z" }
            """.utf8))
        }
        let sent = try await makeClient(transport).sendPreparedText(
            confirmationId: "confirm-1",
            digest: String(repeating: "a", count: 64)
        )
        XCTAssertTrue(sent.sent)
        XCTAssertEqual(sent.serviceType, .iMessage)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/messages/send")
        let body = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("confirm-1"))
        XCTAssertFalse(body.contains("I am on my way"), "the send endpoint cannot alter the prepared body")
    }
}
