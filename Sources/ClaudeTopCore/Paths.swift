import Foundation

public enum Paths {
    public static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/ClaudeTop", isDirectory: true)
    }

    public static var logsDirectory: URL {
        home.appendingPathComponent("Library/Logs/ClaudeTop", isDirectory: true)
    }

    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_TOP_SOCKET"], !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("hook.sock").path
    }

    public static var sessionsFile: URL {
        supportDirectory.appendingPathComponent("sessions.json")
    }

    public static var claudeSettings: URL {
        home.appendingPathComponent(".claude/settings.json")
    }
}
