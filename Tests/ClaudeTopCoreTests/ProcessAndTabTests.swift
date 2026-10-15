import Foundation
import Testing
@testable import ClaudeTopCore

@Suite struct ITermTests {
    @Test func sessionIDParts() {
        let value = "w0t4p0:31C15808-FB93-4406-B87C-4C1C4642EF11"
        #expect(ITermSessionID.uuid(from: value) == "31C15808-FB93-4406-B87C-4C1C4642EF11")
        #expect(ITermSessionID.startTabNumber(from: value) == 5)
        #expect(ITermSessionID.startTabNumber(from: "w1t12p3:AB") == 13)
        #expect(ITermSessionID.uuid(from: "w0t0p0:bad\"; do shell script") == nil)
        #expect(ITermSessionID.uuid(from: nil) == nil)
        #expect(ITermSessionID.startTabNumber(from: "garbage") == nil)
    }

    @Test func listingParse() {
        let text = "AAA\u{1F}1\u{1F}2\u{1F}✳ Build the spec\nBBB\u{1F}2\u{1F}1\u{1F}\nbad line\n"
        let tabs = ITermListing.parse(text)
        #expect(tabs["AAA"] == ITermTab(windowIndex: 1, tabIndex: 2, title: "✳ Build the spec"))
        #expect(tabs["BBB"] == ITermTab(windowIndex: 2, tabIndex: 1, title: ""))
        #expect(tabs.count == 2)
    }

    @Test func displayTitleDropsClaudeDecoration() {
        func title(_ raw: String) -> String { ITermTab(windowIndex: 1, tabIndex: 1, title: raw).displayTitle }
        #expect(title("✳ Phase 2 auth branches and PRs (claude)") == "Phase 2 auth branches and PRs")
        #expect(title("◐ macOS attention lights app spec (claude)") == "macOS attention lights app spec")
        #expect(title("zsh") == "zsh")
        #expect(title("✳ ") == "")
    }
}

@Suite struct ProcessScannerTests {
    @Test func readsOwnWorkingDirectoryAndEnvironment() {
        #expect(ProcessScanner.workingDirectory(of: getpid()) == FileManager.default.currentDirectoryPath)
        #expect(ProcessScanner.environment(of: getpid())["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }

    @Test func procArgsLayout() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { buffer.append(contentsOf: $0) }
        for part in ["/bin/claude", "\0\0\0", "claude", "\0", "--resume", "\0", "A=1", "\0", "ITERM_SESSION_ID=w0t1p0:X", "\0", "\0"] {
            buffer.append(contentsOf: Array(part.utf8))
        }
        #expect(ProcessScanner.parseProcArgs(buffer) == ["A": "1", "ITERM_SESSION_ID": "w0t1p0:X"])
    }

    @Test func placeholdersSkipKnownProcesses() {
        var store = SessionStore()
        store.apply(Envelope(
            tsMs: 1,
            payload: HookPayload(sessionID: "s1", hookEventName: "UserPromptSubmit"),
            context: HookContext(claudePID: 100)
        ))
        let rows = store.placeholders(for: [
            ClaudeProcess(pid: 100, cwd: "/a", itermSessionID: nil),
            ClaudeProcess(pid: 200, cwd: "/x/other", itermSessionID: "w0t2p0:AB"),
        ])
        #expect(rows.map(\.id) == ["pid-200"])
        #expect(rows[0].discovered)
        #expect(rows[0].project == "other")
        #expect(rows[0].livenessPID == 200)
    }

    @Test func restoreDropsPendingAndPlaceholders() throws {
        var store = SessionStore()
        store.apply(Envelope(tsMs: 1, payload: HookPayload(sessionID: "s1", hookEventName: "Stop")))
        var placeholder = Session(id: "pid-5")
        placeholder.discovered = true
        let saved = Array(store.sessions.values) + [placeholder]
        let data = try JSONEncoder().encode(saved)
        let restored = SessionStore(restoring: try JSONDecoder().decode([Session].self, from: data))
        #expect(Array(restored.sessions.keys) == ["s1"])
        #expect(restored.sessions["s1"]?.classifying == false)
    }
}
