import Foundation

/// Accepts only short action-specific phrases in a later turn. Generic assent
/// is unsafe because the glasses microphone carries undiarized conversation.
public enum ExplicitComputerConfirmation {
    public static func accepts(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")

        return [
            "run it",
            "do it now",
            "yes run it",
            "please run it",
            "go ahead and run it",
            "proceed with that action",
        ].contains(normalized)
    }
}
