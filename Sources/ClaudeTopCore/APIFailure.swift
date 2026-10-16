import Foundation

/// Text for a turn that ended with an API error.
public enum APIFailure {
    /// Claude Code writes these messages itself. They are not model output.
    static let messagePrefixes = [
        "API Error:",
        "Not logged in",
        "Login expired",
        "You've hit your",
        "Credit balance is too low",
        "Claude AI usage limit reached",
    ]

    /// Some API errors can end the turn with `Stop` and not `StopFailure`.
    public static func isErrorMessage(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return messagePrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// The exact message is the most useful, because it often tells you what to do ("Please run /login").
    public static func reason(error: String?, details: String?, message: String?) -> String {
        if let message, isErrorMessage(message) { return firstLine(message) }
        if let details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return firstLine(details) }
        switch error {
        case "authentication_failed", "oauth_org_not_allowed", "account_on_hold",
             "verification_required", "cloud_credential_error":
            return "Login or account problem"
        case "billing_error": return "Billing problem: no credits"
        case "rate_limit": return "Usage limit reached"
        case "overloaded": return "API is overloaded"
        case "server_error": return "API server error"
        case "invalid_request", "model_not_found": return "Invalid API request"
        case "max_output_tokens": return "Output token limit reached"
        default: return "Turn failed with an error"
        }
    }

    public static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
