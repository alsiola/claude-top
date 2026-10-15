import Foundation

public enum HookInstaller {
    public static let helperName = "claude-top-hook"

    public static let events = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "Stop",
        "StopFailure",
    ]

    public enum Status: Equatable {
        case notInstalled
        case installed
        /// Some entries exist, but they do not match this app (old path, or events missing).
        case outdated
    }

    public struct InstallError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func command(helperPath: String) -> String {
        "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func handler(helperPath: String) -> JSON {
        .object([
            .init("type", .string("command")),
            .init("command", .string(command(helperPath: helperPath))),
            .init("async", .bool(true)),
            .init("timeout", .number("5")),
        ])
    }

    static func isOurs(_ handler: JSON) -> Bool {
        handler["command"]?.stringValue?.contains(helperName) ?? false
    }

    public static func status(of root: JSON, helperPath: String) -> Status {
        guard let hooks = root["hooks"], hooks.isObject else { return .notInstalled }
        let expected = command(helperPath: helperPath)
        var anyOurs = false
        var allMatch = true
        for event in events {
            let ours = (hooks[event]?.arrayValue ?? [])
                .flatMap { $0["hooks"]?.arrayValue ?? [] }
                .filter(isOurs)
            if !ours.isEmpty { anyOurs = true }
            if ours.count != 1 || ours[0]["command"]?.stringValue != expected { allMatch = false }
        }
        guard anyOurs else { return .notInstalled }
        return allMatch ? .installed : .outdated
    }

    /// Removes only the entries that run `claude-top-hook`. Other hooks stay unchanged.
    public static func removing(from root: JSON) throws -> JSON {
        guard root.isObject else { throw InstallError(description: "The settings file is not a JSON object.") }
        guard let hooks = root["hooks"] else { return root }
        guard case .object(let eventMembers) = hooks else {
            throw InstallError(description: "The \"hooks\" value is not a JSON object.")
        }
        var newEvents: [JSON.Member] = []
        for member in eventMembers {
            guard case .array(let groups) = member.value else {
                newEvents.append(member)
                continue
            }
            var newGroups: [JSON] = []
            for var group in groups {
                guard case .array(let handlers)? = group["hooks"] else {
                    newGroups.append(group)
                    continue
                }
                let kept = handlers.filter { !isOurs($0) }
                if kept.count == handlers.count {
                    newGroups.append(group)
                } else if !kept.isEmpty {
                    group["hooks"] = .array(kept)
                    newGroups.append(group)
                }
            }
            if !newGroups.isEmpty || groups.isEmpty {
                newEvents.append(JSON.Member(member.key, .array(newGroups)))
            }
        }
        var result = root
        result["hooks"] = newEvents.isEmpty ? nil : .object(newEvents)
        return result
    }

    public static func installing(into root: JSON, helperPath: String) throws -> JSON {
        var result = try removing(from: root)
        var hooks = result["hooks"] ?? .object([])
        for event in events {
            var groups = hooks[event]?.arrayValue ?? []
            groups.append(.object([.init("hooks", .array([handler(helperPath: helperPath)]))]))
            hooks[event] = .array(groups)
        }
        result["hooks"] = hooks
        return result
    }
}

/// Reads and writes `~/.claude/settings.json` safely.
public struct SettingsFile {
    public var url: URL

    public init(url: URL = Paths.claudeSettings) {
        self.url = url
    }

    /// Many people keep this file in a dotfiles repository and link to it.
    /// The write must replace the target, not the link.
    public var resolvedURL: URL {
        url.resolvingSymlinksInPath()
    }

    public func read() throws -> JSON {
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return .object([]) }
        let data = try Data(contentsOf: resolvedURL)
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .object([]) }
        return try JSON.parse(data)
    }

    /// Returns the backup location, or nil when there was no file to back up.
    @discardableResult
    public func write(_ json: JSON, now: Date = Date()) throws -> URL? {
        let target = resolvedURL
        let fileManager = FileManager.default
        var backup: URL?
        var permissions: NSNumber?
        if fileManager.fileExists(atPath: target.path) {
            permissions = try fileManager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = target.deletingLastPathComponent()
                .appendingPathComponent(target.lastPathComponent + ".claude-top-backup-" + formatter.string(from: now))
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: target, to: backupURL)
            backup = backupURL
        } else {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(json.serialized().utf8).write(to: target, options: .atomic)
        // An atomic write makes a new file, so the old mode must be set again.
        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return backup
    }
}
