import Foundation

public enum SessionState: String, Codable, Sendable {
    case working, idle, review, attention

    var rank: Int {
        switch self {
        case .attention: return 0
        case .review: return 1
        case .working, .idle: return 2
        }
    }

    public var light: Light {
        switch self {
        case .attention: return .red
        case .review: return .amber
        case .working, .idle: return .green
        }
    }
}

public enum Light: String, Codable, Sendable {
    case off, green, amber, red
}

public struct Session: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var cwd: String?
    public var state: SessionState
    public var reason: String?
    public var lastEventMs: Int64
    public var stateSinceMs: Int64
    public var context: HookContext?
    /// The `Stop` that waits for the classifier. Any state change cancels it.
    public var pendingStopMs: Int64?
    /// Found by a process scan, with no hook event yet.
    public var discovered = false

    public init(id: String, state: SessionState = .idle, lastEventMs: Int64 = 0) {
        self.id = id
        self.state = state
        self.lastEventMs = lastEventMs
        self.stateSinceMs = lastEventMs
    }

    public var classifying: Bool { pendingStopMs != nil }

    public var project: String {
        guard let cwd, !cwd.isEmpty else { return String(id.prefix(8)) }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var livenessPID: Int32? {
        context?.claudePID ?? context?.ppid
    }
}

public struct ClassifyRequest: Equatable, Sendable {
    public var sessionID: String
    public var stopTsMs: Int64
    public var input: StopInput
}

public struct SessionStore: Sendable {
    public private(set) var sessions: [String: Session] = [:]

    public init() {}

    /// A classification does not survive a restart, so pending ones are dropped.
    public init(restoring saved: [Session]) {
        for var session in saved where !session.discovered {
            session.pendingStopMs = nil
            sessions[session.id] = session
        }
    }

    /// Rows for Claude processes that sent no hook event yet: sessions that
    /// started before the hooks were installed, or that wait for input while
    /// the app was not running.
    public func placeholders(for processes: [ClaudeProcess]) -> [Session] {
        let knownPIDs = Set(sessions.values.compactMap(\.context?.claudePID))
        return processes
            .filter { !knownPIDs.contains($0.pid) }
            .sorted { $0.pid < $1.pid }
            .map { process in
                var session = Session(id: "pid-\(process.pid)")
                session.cwd = process.cwd
                session.context = HookContext(claudePID: process.pid, itermSessionID: process.itermSessionID)
                session.reason = "No events yet"
                session.discovered = true
                return session
            }
    }

    /// Returns a request when the event is a `Stop` that needs the classifier.
    @discardableResult
    public mutating func apply(_ envelope: Envelope) -> ClassifyRequest? {
        let payload = envelope.payload
        guard let sessionID = payload.sessionID, let event = payload.hookEventName else { return nil }

        if event == "SessionEnd" {
            sessions[sessionID] = nil
            return nil
        }

        var session = sessions[sessionID] ?? Session(id: sessionID, lastEventMs: envelope.tsMs)
        // Hooks run async, so an older event can arrive after a newer one.
        guard envelope.tsMs >= session.lastEventMs else { return nil }
        session.lastEventMs = envelope.tsMs
        if let cwd = payload.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let context = envelope.context { session.context = context }

        var request: ClassifyRequest?
        // Subagents run in parallel with the main agent, and background subagents
        // run after it stops. Their activity must not clear a red or amber state.
        let isMainAgent = payload.agentID == nil

        switch event {
        case "SessionStart":
            if payload.source != "compact" {
                set(&session, .idle, nil, at: envelope.tsMs)
            }
        case "UserPromptSubmit":
            set(&session, .working, nil, at: envelope.tsMs)
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            if isMainAgent {
                set(&session, .working, nil, at: envelope.tsMs)
            }
        case "PermissionRequest":
            let tool = payload.toolName.map { "Permission: \($0)" } ?? "Permission request"
            set(&session, .attention, tool, at: envelope.tsMs)
        case "Notification":
            switch payload.notificationType {
            case "permission_prompt":
                // PermissionRequest also fires and has the better reason text.
                if session.state != .attention {
                    set(&session, .attention, "Permission request", at: envelope.tsMs)
                }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                set(&session, .attention, "Needs input", at: envelope.tsMs)
            default:
                break
            }
        case "StopFailure":
            set(&session, .attention, "Turn failed with an error", at: envelope.tsMs)
        case "Stop":
            if isMainAgent {
                session.pendingStopMs = envelope.tsMs
                request = ClassifyRequest(
                    sessionID: sessionID,
                    stopTsMs: envelope.tsMs,
                    input: StopInput(
                        message: payload.lastAssistantMessage ?? "",
                        project: session.project,
                        backgroundTaskCount: payload.backgroundTaskCount ?? 0
                    )
                )
            }
        default:
            break
        }

        sessions[sessionID] = session
        return request
    }

    /// Ignored when the state changed after the `Stop`, for example when you
    /// replied before the classifier answered.
    @discardableResult
    public mutating func applyClassification(_ request: ClassifyRequest, _ result: Classification) -> Bool {
        guard var session = sessions[request.sessionID],
              session.pendingStopMs == request.stopTsMs
        else { return false }
        set(&session, result.state, result.reason, at: request.stopTsMs)
        sessions[request.sessionID] = session
        return true
    }

    public mutating func dismiss(_ sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        set(&session, .idle, nil, at: session.lastEventMs)
        sessions[sessionID] = session
    }

    public mutating func remove(_ sessionID: String) {
        sessions[sessionID] = nil
    }

    /// Removes sessions that ended without a `SessionEnd` event, for example after a crash.
    @discardableResult
    public mutating func prune(nowMs: Int64, maxIdleMs: Int64, isAlive: (Int32) -> Bool) -> [String] {
        let dead = sessions.values.filter { session in
            if let pid = session.livenessPID { return !isAlive(pid) }
            return nowMs - session.lastEventMs > maxIdleMs
        }.map(\.id)
        for id in dead { sessions[id] = nil }
        return dead
    }

    public var light: Light {
        if sessions.isEmpty { return .off }
        if sessions.values.contains(where: { $0.state == .attention }) { return .red }
        if sessions.values.contains(where: { $0.state == .review }) { return .amber }
        return .green
    }

    public func count(_ state: SessionState) -> Int {
        sessions.values.filter { $0.state == state }.count
    }

    /// Red, then amber, with the longest wait first. Then all other sessions,
    /// with the most recent activity first.
    public var sorted: [Session] {
        sessions.values.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            if a.state.rank < 2 {
                if a.stateSinceMs != b.stateSinceMs { return a.stateSinceMs < b.stateSinceMs }
            } else if a.lastEventMs != b.lastEventMs {
                return a.lastEventMs > b.lastEventMs
            }
            return a.id < b.id
        }
    }

    private func set(_ session: inout Session, _ state: SessionState, _ reason: String?, at tsMs: Int64) {
        if session.state != state { session.stateSinceMs = tsMs }
        session.pendingStopMs = nil
        session.state = state
        session.reason = reason
    }
}
