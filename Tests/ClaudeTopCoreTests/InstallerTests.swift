import Foundation
import Testing
@testable import ClaudeTopCore

private let helper = "/Applications/Claude Top.app/Contents/MacOS/claude-top-hook"

private let existingSettings = """
{
  "model": "opus",
  "env": {
    "A": "1"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "rtk hook claude"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/me/.config/claude-lights/forward.sh",
            "timeout": 10,
            "async": true
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "echo \\"hi\\" \\u00e9 😀"
  },
  "cleanupPeriodDays": 1e3
}

"""

@Suite struct JSONTests {
    @Test func roundTripKeepsOrderAndText() throws {
        let json = try JSON.parse(existingSettings)
        #expect(json.serialized() == existingSettings.trimmingCharacters(in: .newlines)
            .replacingOccurrences(of: "\\u00e9", with: "é") + "\n")
    }

    @Test func parsesEscapes() throws {
        let json = try JSON.parse(#"{"a":"line\nbreak \"q\" é 😀 \/"}"#)
        #expect(json["a"]?.stringValue == "line\nbreak \"q\" é 😀 /")
    }

    @Test func rejectsInvalid() {
        for text in ["{", "{\"a\":}", "[1,]", "{\"a\":1} x", "tru", "\"\u{01}\""] {
            #expect(throws: JSONParseError.self) { try JSON.parse(text) }
        }
    }
}

@Suite struct InstallerTests {
    @Test func installKeepsOtherHooksAndKeys() throws {
        let root = try JSON.parse(existingSettings)
        let installed = try HookInstaller.installing(into: root, helperPath: helper)

        guard case .object(let members) = installed else { Issue.record("not an object"); return }
        #expect(members.map(\.key) == ["model", "env", "hooks", "statusLine", "cleanupPeriodDays"])

        let preToolUse = try #require(installed["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(preToolUse.count == 2)
        #expect(preToolUse[0]["matcher"]?.stringValue == "Bash")

        let stop = try #require(installed["hooks"]?["Stop"]?.arrayValue)
        #expect(stop.count == 2)
        #expect(stop[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue == "/Users/me/.config/claude-lights/forward.sh")

        for event in HookInstaller.events {
            #expect(installed["hooks"]?[event] != nil, "missing \(event)")
        }
        #expect(HookInstaller.status(of: installed, helperPath: helper) == .installed)
    }

    @Test func handlerShape() {
        let handler = HookInstaller.handler(helperPath: helper)
        #expect(handler["type"]?.stringValue == "command")
        #expect(handler["command"]?.stringValue == "'/Applications/Claude Top.app/Contents/MacOS/claude-top-hook'")
        #expect(handler["async"] == .bool(true))
    }

    @Test func quotesSingleQuotesInPath() {
        #expect(HookInstaller.command(helperPath: "/a/it's/claude-top-hook") == #"'/a/it'\''s/claude-top-hook'"#)
    }

    @Test func installIsIdempotent() throws {
        let root = try JSON.parse(existingSettings)
        let once = try HookInstaller.installing(into: root, helperPath: helper)
        let twice = try HookInstaller.installing(into: once, helperPath: helper)
        #expect(once == twice)
    }

    @Test func installReplacesOldPath() throws {
        let root = try JSON.parse(existingSettings)
        let old = try HookInstaller.installing(into: root, helperPath: "/Users/me/Downloads/Claude Top.app/Contents/MacOS/claude-top-hook")
        #expect(HookInstaller.status(of: old, helperPath: helper) == .outdated)
        let new = try HookInstaller.installing(into: old, helperPath: helper)
        #expect(HookInstaller.status(of: new, helperPath: helper) == .installed)
        #expect(new.serialized().contains("Downloads") == false)
    }

    @Test func missingEventIsOutdated() throws {
        var installed = try HookInstaller.installing(into: .object([]), helperPath: helper)
        var hooks = try #require(installed["hooks"])
        hooks["StopFailure"] = nil
        installed["hooks"] = hooks
        #expect(HookInstaller.status(of: installed, helperPath: helper) == .outdated)
    }

    @Test func removeRestoresOriginal() throws {
        let root = try JSON.parse(existingSettings)
        let installed = try HookInstaller.installing(into: root, helperPath: helper)
        let removed = try HookInstaller.removing(from: installed)
        #expect(removed == root)
        #expect(HookInstaller.status(of: removed, helperPath: helper) == .notInstalled)
    }

    @Test func removeFromEmptyFileDropsHooksKey() throws {
        let installed = try HookInstaller.installing(into: .object([]), helperPath: helper)
        #expect(try HookInstaller.removing(from: installed) == .object([]))
    }

    @Test func removeKeepsOtherHandlersInSharedGroup() throws {
        let root = try JSON.parse("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other"},{"type":"command","command":"'/x/claude-top-hook'"}]}]}}
        """)
        let removed = try HookInstaller.removing(from: root)
        let handlers = try #require(removed["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue)
        #expect(handlers.count == 1)
        #expect(handlers[0]["command"]?.stringValue == "other")
    }

    @Test func rejectsNonObjectRoot() {
        #expect(throws: HookInstaller.InstallError.self) {
            try HookInstaller.installing(into: .array([]), helperPath: helper)
        }
    }
}

@Suite struct SettingsFileTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-top-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func missingFileReadsAsEmptyObjectAndWriteCreatesIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SettingsFile(url: directory.appendingPathComponent(".claude/settings.json"))
        #expect(try file.read() == .object([]))
        let backup = try file.write(try HookInstaller.installing(into: .object([]), helperPath: helper))
        #expect(backup == nil)
        #expect(HookInstaller.status(of: try file.read(), helperPath: helper) == .installed)
    }

    @Test func writeMakesBackupKeepsModeAndFollowsSymlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("dotfiles-settings.json")
        try Data(existingSettings.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let file = SettingsFile(url: link)
        let backup = try #require(try file.write(try HookInstaller.installing(into: try file.read(), helperPath: helper)))

        #expect(try String(contentsOf: backup, encoding: .utf8) == existingSettings)
        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(HookInstaller.status(of: try file.read(), helperPath: helper) == .installed)
    }

    @Test func invalidFileThrowsAndIsNotChanged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data("{ bad".utf8).write(to: url)
        #expect(throws: JSONParseError.self) { try SettingsFile(url: url).read() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ bad")
    }
}
