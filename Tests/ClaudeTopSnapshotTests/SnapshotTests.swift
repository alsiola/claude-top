import AppKit
import ClaudeTopCore
import SwiftUI
import Testing
@testable import ClaudeTop

/// Renders the views to PNG files for a visual check. Runs only when
/// SNAPSHOT_DIR is set: SNAPSHOT_DIR=/some/dir scripts/test.sh --filter Snapshot
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil))
@MainActor
struct SnapshotTests {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? "/dev/null")

    private func send(_ model: AppModel, _ json: String, at ts: Int64, iterm: String? = nil) {
        let context = iterm.map { #","context":{"iterm_session_id":"\#($0)"}"# } ?? ""
        let envelope = #"{"v":1,"ts_ms":\#(ts),"payload":\#(json)\#(context)}"#
        model.handle(Data(envelope.utf8))
    }

    private func save<V: View>(_ view: V, _ name: String, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).background(
            scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
        ))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    @Test func renderViews() async throws {
        let settings = AppSettings()
        settings.useJev = false
        // The Keychain item belongs to the app, so a read from the test binary opens a password dialog.
        let model = AppModel(
            settings: settings,
            storageURL: nil,
            scanProcesses: { [ClaudeProcess(pid: 999_999, cwd: "/x/old-session", itermSessionID: "w0t6p0:AB")] },
            readAPIKey: { nil }, readWebhookConfig: { nil }
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try save(TrafficLightView(model: model), "panel-off", scheme: .dark)

        model.prune()
        send(model, #"{"session_id":"a","hook_event_name":"UserPromptSubmit","cwd":"/x/claude-top"}"#, at: now - 30_000)
        try save(TrafficLightView(model: model), "panel-green", scheme: .dark)

        send(model, #"{"session_id":"b","hook_event_name":"Stop","cwd":"/x/web-app","last_assistant_message":"Fixed. Tests pass."}"#, at: now - 400_000, iterm: "w0t0p0:CD")
        send(model, #"{"session_id":"c","hook_event_name":"Stop","cwd":"/x/docs-site","last_assistant_message":"Updated the guide."}"#, at: now - 200_000)
        try await Task.sleep(nanoseconds: 300_000_000)
        try save(TrafficLightView(model: model), "panel-amber", scheme: .dark)

        send(model, #"{"session_id":"d","hook_event_name":"PermissionRequest","cwd":"/x/api-server","tool_name":"Bash"}"#, at: now - 90_000, iterm: "w0t2p0:AB")
        send(model, #"{"session_id":"e","hook_event_name":"Stop","cwd":"/x/infra","last_assistant_message":"Which region do you want, eu-west-1 or us-east-1?"}"#, at: now - 5_000)
        send(model, #"{"session_id":"f","hook_event_name":"SessionStart","cwd":"/x/scratch","source":"startup"}"#, at: now - 7_200_000)
        try await Task.sleep(nanoseconds: 300_000_000)
        try save(TrafficLightView(model: model), "panel-red", scheme: .dark)

        let actions = AppActions(showSettings: {}, togglePanel: {}, installHooks: {}, removeHooks: {}, quit: {})
        for scheme in [ColorScheme.light, .dark] {
            try save(SessionListView(model: model, settings: settings, actions: actions), "list", scheme: scheme)
            // ImageRenderer cannot draw the ScrollView of the list, so the rows are drawn alone.
            let rows = VStack(spacing: 0) {
                ForEach(model.sessions) { SessionRow(session: $0, model: model, tab: model.tab(for: $0)) }
            }.frame(width: 360)
            try save(rows, "rows", scheme: scheme)
        }
    }

    /// Draws the real window through AppKit, because ImageRenderer cannot draw a Form.
    @Test func settingsWindowHasContent() throws {
        let settings = AppSettings()
        let model = AppModel(settings: settings, storageURL: nil, scanProcesses: { [] }, readAPIKey: { nil }, readWebhookConfig: { nil })
        let actions = AppActions(showSettings: {}, togglePanel: {}, installHooks: {}, removeHooks: {}, quit: {})
        let window = AppDelegate.makeSettingsWindow(settings: settings, model: model, actions: actions)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        #expect(content.frame.height >= 700)

        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("settings.png"))
    }
}
