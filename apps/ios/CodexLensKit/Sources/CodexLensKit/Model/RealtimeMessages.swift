import Foundation

// The message/event types the phone exchanges with the Realtime model. These
// are consistent with what the gateway returns: the task tools below map
// directly onto the gateway endpoints in docs/M4.md, and progress relayed to
// the user is driven by `TaskEvent`s from the gateway stream.

/// A tool the reasoning voice can call. Encodes to the function-tool JSON the
/// Realtime API expects (`type: "function"`).
public struct RealtimeToolDefinition: Codable, Equatable, Sendable {
    public let type: String
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// The concrete tools this app exposes, each backed by a gateway call.
public enum CodexLensTools {
    /// Kick off a Codex run on the approved project (→ POST /v1/tasks).
    public static let startTask = RealtimeToolDefinition(
        name: "start_task",
        description: "Start a Codex task on the approved project after the user approves the plan.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "projectId": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("projectId")]),
        ])
    )

    /// Report the latest verified progress to the user (← gateway event stream).
    public static let reportProgress = RealtimeToolDefinition(
        name: "report_progress",
        description: "Speak the latest verified progress for the running task to the user.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "taskId": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("taskId")]),
        ])
    )

    public static let all: [RealtimeToolDefinition] = [startTask, reportProgress]
}

/// A message the phone sends up to the model (a tool result or a spoken turn).
public enum RealtimeOutboundMessage: Codable, Equatable, Sendable {
    case toolResult(callId: String, output: JSONValue)
    case userText(String)

    private enum CodingKeys: String, CodingKey {
        case kind, callId, output, text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toolResult(let callId, let output):
            try container.encode("tool_result", forKey: .kind)
            try container.encode(callId, forKey: .callId)
            try container.encode(output, forKey: .output)
        case .userText(let text):
            try container.encode("user_text", forKey: .kind)
            try container.encode(text, forKey: .text)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "tool_result":
            self = .toolResult(
                callId: try container.decode(String.self, forKey: .callId),
                output: try container.decode(JSONValue.self, forKey: .output)
            )
        case "user_text":
            self = .userText(try container.decode(String.self, forKey: .text))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "Unknown outbound message kind \(other)"
            )
        }
    }
}

/// An app-facing event surfaced to the UI as the session runs. This is what a
/// SwiftUI view model observes.
public enum SessionEvent: Equatable, Sendable {
    /// The connection state changed.
    case state(RealtimeState)
    /// The model produced spoken/text output for the user.
    case assistantText(String)
    /// The model asked to call a tool; the app fulfills it against the gateway.
    case toolCall(callId: String, name: String, arguments: JSONValue)
    /// Verified task progress arrived from the gateway stream.
    case progress(TaskEvent)
    /// A recoverable or fatal error to show the user.
    case error(String)
}
