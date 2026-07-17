import Foundation

// Wire types. Field names and shapes mirror packages/gateway exactly
// (src/tasks/task.ts, src/events/event.ts, src/realtime/credentials.ts).
// Dates are kept as ISO-8601 strings, matching the gateway, so nothing is lost
// to date-format drift; parse to Date at the edge with `ISO8601DateFormatter`.

public enum TaskState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case complete
    case failed

    public var isTerminal: Bool { self == .complete || self == .failed }
}

public struct Task: Codable, Equatable, Sendable {
    public let id: String
    public let projectId: String
    public let state: TaskState
    public let idempotencyKey: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        projectId: String,
        state: TaskState,
        idempotencyKey: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.projectId = projectId
        self.state = state
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TaskEventType: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case log
    case complete
    case failed

    /// A terminal event ends the stream; the client stops polling.
    public var isTerminal: Bool { self == .complete || self == .failed }
}

public struct TaskEvent: Codable, Equatable, Sendable {
    public let id: String
    public let taskId: String
    public let seq: Int
    public let type: TaskEventType
    public let payload: JSONValue
    public let createdAt: String

    public init(
        id: String,
        taskId: String,
        seq: Int,
        type: TaskEventType,
        payload: JSONValue,
        createdAt: String
    ) {
        self.id = id
        self.taskId = taskId
        self.seq = seq
        self.type = type
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// The 200 body of `GET /v1/tasks/:taskId/events`.
public struct TaskEventsPage: Codable, Equatable, Sendable {
    public let events: [TaskEvent]
    public let nextCursor: Int

    public init(events: [TaskEvent], nextCursor: Int) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

/// The 200 body of `POST /v1/realtime/credentials` — the SHORT-LIVED credential.
/// It carries no long-lived key; that never leaves the gateway.
public struct RealtimeCredential: Codable, Equatable, Sendable {
    public let value: String
    public let expiresAt: String
    public let model: String
    public let sessionId: String?

    public init(value: String, expiresAt: String, model: String, sessionId: String? = nil) {
        self.value = value
        self.expiresAt = expiresAt
        self.model = model
        self.sessionId = sessionId
    }

    /// Parsed expiry, or nil if the gateway sent an unparseable date.
    public var expiresAtDate: Date? {
        RealtimeCredential.isoFormatter.date(from: expiresAt)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// The shape every gateway error body shares (400/401/404/422/503).
public struct GatewayErrorBody: Codable, Equatable, Sendable {
    public let statusCode: Int
    public let error: String
    public let message: String
}
