import XCTest
@testable import CodexLensKit

/// Decodes the exact JSON the gateway emits (see docs/M4.md) into the wire
/// types, so a drift between gateway and phone fails here.
final class ModelTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodesRealtimeCredential() throws {
        let json = Data("""
        {
          "value": "ek_abc",
          "expiresAt": "2026-07-16T12:00:00.000Z",
          "model": "gpt-realtime",
          "sessionId": "sess_1"
        }
        """.utf8)

        let credential = try decoder.decode(RealtimeCredential.self, from: json)
        XCTAssertEqual(credential.value, "ek_abc")
        XCTAssertEqual(credential.model, "gpt-realtime")
        XCTAssertEqual(credential.sessionId, "sess_1")
        XCTAssertNotNil(credential.expiresAtDate)
    }

    func testDecodesRealtimeCredentialWithoutSessionId() throws {
        let json = Data("""
        { "value": "ek_x", "expiresAt": "2026-07-16T12:00:00.000Z", "model": "gpt-realtime" }
        """.utf8)
        let credential = try decoder.decode(RealtimeCredential.self, from: json)
        XCTAssertNil(credential.sessionId)
    }

    func testDecodesTaskEventsPageWithNestedPayload() throws {
        let json = Data("""
        {
          "events": [
            {
              "id": "evt_0",
              "taskId": "task_1",
              "seq": 0,
              "type": "queued",
              "payload": {},
              "createdAt": "2026-07-16T00:00:00.000Z"
            },
            {
              "id": "evt_1",
              "taskId": "task_1",
              "seq": 1,
              "type": "log",
              "payload": { "line": "running tests", "count": 2 },
              "createdAt": "2026-07-16T00:00:01.000Z"
            }
          ],
          "nextCursor": 1
        }
        """.utf8)

        let page = try decoder.decode(TaskEventsPage.self, from: json)
        XCTAssertEqual(page.nextCursor, 1)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events[0].type, .queued)
        XCTAssertEqual(page.events[1].payload.string("line"), "running tests")
        XCTAssertFalse(page.events[0].type.isTerminal)
    }

    func testTaskTerminalStates() {
        XCTAssertTrue(TaskState.complete.isTerminal)
        XCTAssertTrue(TaskState.failed.isTerminal)
        XCTAssertFalse(TaskState.running.isTerminal)
        XCTAssertTrue(TaskEventType.complete.isTerminal)
        XCTAssertFalse(TaskEventType.running.isTerminal)
    }

    func testJSONValueRoundTrips() throws {
        let value: JSONValue = .object([
            "s": .string("x"),
            "n": .number(3),
            "b": .bool(true),
            "z": .null,
            "arr": .array([.number(1), .string("two")]),
        ])
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, back)
    }

    func testOutboundMessageRoundTrips() throws {
        let messages: [RealtimeOutboundMessage] = [
            .userText("approved"),
            .toolResult(callId: "call_1", output: .object(["ok": .bool(true)])),
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            let back = try JSONDecoder().decode(RealtimeOutboundMessage.self, from: data)
            XCTAssertEqual(message, back)
        }
    }

    func testToolDefinitionsEncodeAsFunctions() throws {
        let data = try JSONEncoder().encode(CodexLensTools.startTask)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "function")
        XCTAssertEqual(object?["name"] as? String, "start_task")
        XCTAssertEqual(CodexLensTools.all.count, 2)
    }
}
