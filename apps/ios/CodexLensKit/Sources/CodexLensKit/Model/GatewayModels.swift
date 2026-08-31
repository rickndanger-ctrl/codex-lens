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

/// A Codex run against an allowlisted project. Named `CodexTask` (not `Task`)
/// so it never shadows Swift concurrency's `Task`.
public struct CodexTask: Codable, Equatable, Sendable {
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

/// One Mac-gateway allowlisted repository. The gateway remains the authority
/// for path and mutation policy; the phone can only select from this list.
public struct ApprovedProject: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let path: String
    public let allowedCommands: [String]
    public let allowWorkspaceWrite: Bool
    public let allowDependencyInstall: Bool
    public let allowCommit: Bool
    public let allowPush: Bool
    public let allowDeploy: Bool
}

public struct ApprovedProjectsResponse: Codable, Equatable, Sendable {
    public let projects: [ApprovedProject]
}

/// A direct Codex answer grounded in one allowlisted repository. This endpoint
/// is always read-only and never returns a path outside that repository.
public struct CodexProjectInspection: Codable, Equatable, Sendable {
    public let projectId: String
    public let projectName: String
    public let summary: String
    public let files: [String]
    public let readOnly: Bool
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

/// A read-only description of what is visible in one Mac app.
public struct ComputerInspection: Codable, Equatable, Sendable {
    public let app: String
    public let summary: String

    public init(app: String, summary: String) {
        self.app = app
        self.summary = summary
    }
}

/// The active Mac application name from a direct read-only macOS query.
public struct FrontmostComputerApp: Codable, Equatable, Sendable {
    public let app: String
    public let windowTitle: String?
    public let readOnly: Bool

    public init(app: String, windowTitle: String? = nil, readOnly: Bool = true) {
        self.app = app
        self.windowTitle = windowTitle
        self.readOnly = readOnly
    }
}

/// A named Mac application that the gateway opened or activated and then
/// verified as the actual frontmost process.
public struct FocusedComputerApp: Codable, Equatable, Sendable {
    public let app: String
    public let frontmost: Bool

    public init(app: String, frontmost: Bool = true) {
        self.app = app
        self.frontmost = frontmost
    }
}

public struct ClosedComputerWindow: Codable, Equatable, Sendable {
    public let app: String
    public let windowTitle: String?
    public let closed: Bool
    public let needsUserDecision: Bool
}

public struct WebResearchSource: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
}

public struct WebResearchResult: Codable, Equatable, Sendable {
    public let answer: String
    public let sources: [WebResearchSource]
    public let searched: Bool
}

/// An immutable, non-executing Mac action preview that must be confirmed in a
/// later spoken turn before the gateway will consume and run it.
public struct PreparedComputerAction: Codable, Equatable, Sendable {
    public let confirmationId: String
    public let digest: String
    public let instruction: String
    public let surface: String
    public let expiresAt: String
    public let requiresExplicitConfirmation: Bool
}

/// Result of one confirmed user-directed Mac or Chrome operation.
public struct ComputerActionResult: Codable, Equatable, Sendable {
    public let completed: Bool
    public let confirmationRequired: Bool
    public let summary: String
    public let surface: String

    public init(
        completed: Bool,
        confirmationRequired: Bool,
        summary: String,
        surface: String
    ) {
        self.completed = completed
        self.confirmationRequired = confirmationRequired
        self.summary = summary
        self.surface = surface
    }
}

/// A non-sending Messages preview. The gateway binds the opaque digest to the
/// exact destination, Messages service, account, and body for a short time.
public enum MessageServiceType: String, Codable, CaseIterable, Equatable, Sendable {
    case iMessage
    case sms = "SMS"
    case rcs = "RCS"
}

public struct PreparedTextMessage: Codable, Equatable, Sendable {
    public let confirmationId: String
    public let digest: String
    public let recipientDisplay: String
    public let maskedDestination: String
    public let message: String
    public let serviceType: MessageServiceType
    public let expiresAt: String
    public let requiresExplicitConfirmation: Bool

    public var expiresAtDate: Date? {
        RealtimeCredential.isoFormatter.date(from: expiresAt)
    }
}

/// Confirmation that the Mac Messages app accepted one prepared send.
public struct SentTextMessage: Codable, Equatable, Sendable {
    public let sent: Bool
    public let recipientDisplay: String
    public let serviceType: MessageServiceType
    public let sentAt: String
}

public enum MessageIntentState: String, Codable, Equatable, Sendable {
    case prepared
    case sending
    case accepted
    case uncertain
    case expired
    case rejected
}

/// Redacted, durable state for reconciling one prepared message without ever
/// retrying an accepted or uncertain external send.
public struct MessageIntentStatus: Codable, Equatable, Sendable {
    public let confirmationId: String
    public let recipientDisplay: String
    public let maskedDestination: String
    public let serviceType: MessageServiceType
    public let state: MessageIntentState
    public let preparedAt: String
    public let expiresAt: String
    public let updatedAt: String
    public let acceptedAt: String?
    public let failureCode: String?
}

public struct MessageServiceReadiness: Codable, Equatable, Sendable {
    public let serviceType: MessageServiceType
    public let available: Bool
    public let accountCount: Int
}

/// Read-only Mac Contacts/Messages permission and account readiness. Inspecting
/// this never sends a message.
public struct MessageReadiness: Codable, Equatable, Sendable {
    public let contactsAccessible: Bool
    public let services: [MessageServiceReadiness]
    public let ready: Bool
}
