import Foundation

public struct HookContext: Codable, Equatable, Sendable {
    public var ppid: Int32?
    /// The first ancestor of the hook that is not a shell: the Claude Code process.
    public var claudePID: Int32?
    public var termProgram: String?
    public var itermSessionID: String?
    public var bundleID: String?

    public init(
        ppid: Int32? = nil,
        claudePID: Int32? = nil,
        termProgram: String? = nil,
        itermSessionID: String? = nil,
        bundleID: String? = nil
    ) {
        self.ppid = ppid
        self.claudePID = claudePID
        self.termProgram = termProgram
        self.itermSessionID = itermSessionID
        self.bundleID = bundleID
    }

    enum CodingKeys: String, CodingKey {
        case ppid
        case claudePID = "claude_pid"
        case termProgram = "term_program"
        case itermSessionID = "iterm_session_id"
        case bundleID = "bundle_id"
    }
}

public struct HookPayload: Decodable, Equatable, Sendable {
    public var sessionID: String?
    public var hookEventName: String?
    public var cwd: String?
    public var notificationType: String?
    public var message: String?
    public var toolName: String?
    public var lastAssistantMessage: String?
    public var source: String?
    public var agentID: String?
    public var backgroundTaskCount: Int?

    public init(
        sessionID: String?,
        hookEventName: String?,
        cwd: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        toolName: String? = nil,
        lastAssistantMessage: String? = nil,
        source: String? = nil,
        agentID: String? = nil,
        backgroundTaskCount: Int? = nil
    ) {
        self.sessionID = sessionID
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.notificationType = notificationType
        self.message = message
        self.toolName = toolName
        self.lastAssistantMessage = lastAssistantMessage
        self.source = source
        self.agentID = agentID
        self.backgroundTaskCount = backgroundTaskCount
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case notificationType = "notification_type"
        case message
        case toolName = "tool_name"
        case lastAssistantMessage = "last_assistant_message"
        case source
        case agentID = "agent_id"
        case backgroundTasks = "background_tasks"
    }

    // Each field is decoded on its own, so that one field with an unexpected type
    // does not lose the whole event.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        sessionID = string(.sessionID)
        hookEventName = string(.hookEventName)
        cwd = string(.cwd)
        notificationType = string(.notificationType)
        message = string(.message)
        toolName = string(.toolName)
        lastAssistantMessage = string(.lastAssistantMessage)
        source = string(.source)
        agentID = string(.agentID)
        if let tasks = try? container.decodeIfPresent([AnyDecodable].self, forKey: .backgroundTasks) {
            backgroundTaskCount = tasks.count
        } else if let count = try? container.decodeIfPresent(Int.self, forKey: .backgroundTasks) {
            backgroundTaskCount = count
        } else {
            backgroundTaskCount = nil
        }
    }
}

private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

public struct Envelope: Decodable, Equatable, Sendable {
    public var version: Int
    public var tsMs: Int64
    public var payload: HookPayload
    public var context: HookContext?

    public init(version: Int = 1, tsMs: Int64, payload: HookPayload, context: HookContext? = nil) {
        self.version = version
        self.tsMs = tsMs
        self.payload = payload
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case tsMs = "ts_ms"
        case payload
        case context
    }

    public static func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }
}
