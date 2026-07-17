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
    private func makeClient(_ transport: StubTransport) -> GatewayClient {
        let config = GatewayConfiguration(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            tokenProvider: { "gateway-token-123" }
        )
        return GatewayClient(configuration: config, transport: transport)
    }

    func testRealtimeCredentialSendsGatewayTokenAndNeverAnOpenAIKey() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data("""
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
}
