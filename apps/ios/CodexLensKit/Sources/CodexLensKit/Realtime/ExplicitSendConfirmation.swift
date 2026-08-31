import Foundation

/// Accepts only a consequence-specific text confirmation. Ordinary phrases
/// such as "yes" or "send it" are unsafe in an ambient conversation.
public enum ExplicitSendConfirmation {
    public static func accepts(_ transcript: String) -> Bool {
        let normalized = normalize(transcript)
        return normalized == "confirm text"
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

public enum TextConfirmationTurnDecision: Equatable, Sendable {
    case authorize
    case invalidate
}

/// Phone-owned state for one prepared text. A model prompt is not authority:
/// confirmation is valid only after a later completed spoken readback, before
/// the bound gateway expiry, and within a short transcript freshness window.
public struct TextConfirmationAuthorization: Equatable, Sendable {
    public let preparedAt: Date
    public let expiresAt: Date
    public private(set) var readbackCompletedAt: Date?

    public init(preparedAt: Date, expiresAt: Date) {
        self.preparedAt = preparedAt
        self.expiresAt = expiresAt
    }

    public mutating func noteReadbackCompleted(at date: Date) {
        guard date >= preparedAt, date < expiresAt else { return }
        readbackCompletedAt = date
    }

    public func decision(
        transcript: String,
        transcribedAt: Date,
        now: Date,
        maximumTranscriptAge: TimeInterval = 30
    ) -> TextConfirmationTurnDecision {
        guard
            now < expiresAt,
            let readbackCompletedAt,
            transcribedAt >= readbackCompletedAt,
            transcribedAt <= now,
            now.timeIntervalSince(transcribedAt) <= maximumTranscriptAge,
            ExplicitSendConfirmation.accepts(transcript)
        else { return .invalidate }
        return .authorize
    }
}
