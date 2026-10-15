import Foundation

public struct WebhookHeader: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct WebhookError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

public struct WebhookConfig: Codable, Equatable, Sendable {
    public var url: URL
    public var headers: [WebhookHeader]

    public init(url: URL, headers: [WebhookHeader] = []) {
        self.url = url
        self.headers = headers
    }

    /// Reads the text of the settings fields: one `Name: Value` header on each line.
    public init(url text: String, headers headerText: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { throw WebhookError(description: "The URL must start with http:// or https:// and have a host.") }
        self.url = url
        headers = try Self.parseHeaders(headerText)
    }

    public static func parseHeaders(_ text: String) throws -> [WebhookHeader] {
        var headers: [WebhookHeader] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw WebhookError(description: "Header line \(index + 1) has no colon. Use \"Name: Value\".")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else {
                throw WebhookError(description: "Header line \(index + 1) has no valid name.")
            }
            headers.append(WebhookHeader(name: name, value: value))
        }
        return headers
    }

    public var headersText: String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }
}

public struct WebhookSession: Encodable, Equatable, Sendable {
    public var id: String
    public var project: String
    public var cwd: String?
    public var state: SessionState
    public var color: Light
    public var reason: String?

    public init(_ session: Session) {
        id = session.id
        project = session.project
        cwd = session.cwd
        state = session.state
        color = session.state.light
        reason = session.reason
    }
}

/// The `type` field of the JSON body tells the receiver which case it is.
public enum WebhookEvent: Equatable, Sendable {
    case lightChanged(previous: Light)
    case sessionChanged(WebhookSession, previous: SessionState?)
    case sessionEnded(WebhookSession)
    case test

    public var type: String {
        switch self {
        case .lightChanged: return "light.changed"
        case .sessionChanged: return "session.changed"
        case .sessionEnded: return "session.ended"
        case .test: return "test"
        }
    }

    /// Session events come first, so the last event of a batch carries the final light.
    public static func diff(
        from oldSessions: [String: Session],
        to newSessions: [String: Session],
        oldLight: Light,
        newLight: Light
    ) -> [WebhookEvent] {
        var events: [WebhookEvent] = []
        for id in Set(oldSessions.keys).union(newSessions.keys).sorted() {
            switch (oldSessions[id], newSessions[id]) {
            case let (old?, nil):
                events.append(.sessionEnded(WebhookSession(old)))
            case let (old, new?) where old?.state != new.state:
                events.append(.sessionChanged(WebhookSession(new), previous: old?.state))
            default:
                break
            }
        }
        if oldLight != newLight { events.append(.lightChanged(previous: oldLight)) }
        return events
    }
}

/// One POST body. Every event has the overall light, so a receiver that
/// mirrors the light can ignore `type`.
public struct WebhookMessage: Encodable, Equatable, Sendable {
    public var event: WebhookEvent
    public var timestamp: Date
    public var light: Light
    public var red: Int
    public var amber: Int

    public init(event: WebhookEvent, timestamp: Date, light: Light, red: Int, amber: Int) {
        self.event = event
        self.timestamp = timestamp
        self.light = light
        self.red = red
        self.amber = amber
    }

    private enum Keys: String, CodingKey {
        case type, timestamp, light, red, amber, previous, session
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(event.type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(light, forKey: .light)
        try container.encode(red, forKey: .red)
        try container.encode(amber, forKey: .amber)
        switch event {
        case let .lightChanged(previous):
            try container.encode(previous, forKey: .previous)
        case let .sessionChanged(session, previous):
            try container.encode(session, forKey: .session)
            try container.encode(previous, forKey: .previous)
        case let .sessionEnded(session):
            try container.encode(session, forKey: .session)
        case .test:
            break
        }
    }
}

public struct WebhookClient: Sendable {
    public var config: WebhookConfig
    public var session: URLSession

    public init(config: WebhookConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func makeRequest(_ message: WebhookMessage) throws -> URLRequest {
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Claude Top", forHTTPHeaderField: "User-Agent")
        for header in config.headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(message)
        return request
    }

    /// Returns the HTTP status code. Throws for a network error or a status outside 2xx.
    @discardableResult
    public func send(_ message: WebhookMessage) async throws -> Int {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: try makeRequest(message))
        } catch let error as URLError {
            throw Self.explain(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw WebhookError(description: "HTTP \(status): \(body)")
        }
        return status
    }

    /// macOS reports a Local Network privacy block as "offline", which sends people looking in the wrong place.
    public static func explain(_ error: URLError) -> WebhookError {
        if error.code == .notConnectedToInternet {
            return WebhookError(description: "No network, or macOS blocks local network access. Allow Claude Top in System Settings > Privacy & Security > Local Network.")
        }
        return WebhookError(description: error.localizedDescription)
    }
}
