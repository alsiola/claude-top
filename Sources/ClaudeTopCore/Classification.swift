import Foundation

public enum StopOutcome: String, CaseIterable, Sendable {
    case question, blocked, review, done

    public var reasonText: String {
        switch self {
        case .question: return "Asks a question"
        case .blocked: return "Blocked"
        case .review: return "Ready for review"
        case .done: return "Done"
        }
    }
}

public struct StopInput: Equatable, Sendable {
    public var message: String
    public var project: String
    public var backgroundTaskCount: Int

    public init(message: String, project: String, backgroundTaskCount: Int) {
        self.message = message
        self.project = project
        self.backgroundTaskCount = backgroundTaskCount
    }

    public static let messageLimit = 4_000

    /// The end of a long message is kept, because a question for the user is
    /// almost always at the end.
    public var truncatedMessage: String {
        message.count > Self.messageLimit ? String(message.suffix(Self.messageLimit)) : message
    }
}

public struct Classification: Equatable, Sendable {
    public var state: SessionState
    public var reason: String
    public var offline: Bool
    public var cost: Double?

    public init(state: SessionState, reason: String, offline: Bool = false, cost: Double? = nil) {
        self.state = state
        self.reason = reason
        self.offline = offline
        self.cost = cost
    }
}

public struct Thresholds: Equatable, Sendable {
    public var red: Double
    public var amber: Double

    public init(red: Double = 0.5, amber: Double = 0.5) {
        self.red = red
        self.amber = amber
    }
}

public enum StopDecision {
    /// Amber includes the red probability, so that an uncertain message goes to
    /// amber and not to green.
    public static func decide(probabilities: [String: Double], thresholds: Thresholds) -> Classification {
        func p(_ outcome: StopOutcome) -> Double { probabilities[outcome.rawValue] ?? 0 }
        let pRed = p(.question) + p(.blocked)
        if pRed >= thresholds.red {
            let top: StopOutcome = p(.question) >= p(.blocked) ? .question : .blocked
            return Classification(state: .attention, reason: top.reasonText)
        }
        if pRed + p(.review) >= thresholds.amber {
            return Classification(state: .review, reason: StopOutcome.review.reasonText)
        }
        return Classification(state: .idle, reason: StopOutcome.done.reasonText)
    }
}

public enum OfflineRule {
    public static func classify(_ message: String) -> Classification {
        if message.suffix(300).contains("?") {
            return Classification(state: .attention, reason: "Asks a question (offline rule)", offline: true)
        }
        return Classification(state: .review, reason: "Ready for review (offline rule)", offline: true)
    }
}

public protocol StopClassifier: Sendable {
    func classify(_ input: StopInput) async throws -> Classification
}

public struct TimeoutError: Error {}

public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TimeoutError() }
        return result
    }
}

/// Uses the model when one is set, and the offline rule in all other cases.
public struct StopClassifierChain: Sendable {
    public var primary: StopClassifier?
    public var timeoutSeconds: Double

    public init(primary: StopClassifier?, timeoutSeconds: Double = 5) {
        self.primary = primary
        self.timeoutSeconds = timeoutSeconds
    }

    public func classify(_ input: StopInput) async -> (Classification, Error?) {
        guard let primary else { return (OfflineRule.classify(input.message), nil) }
        do {
            let result = try await withTimeout(seconds: timeoutSeconds) {
                try await primary.classify(input)
            }
            return (result, nil)
        } catch {
            return (OfflineRule.classify(input.message), error)
        }
    }
}
