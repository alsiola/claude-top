import AppKit
import ClaudeTopCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var server: SocketServer?
    private var panel: LightPanelController!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var tabRefreshTimer: Timer?
    private var statusFlashTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
           .contains(where: { $0 != NSRunningApplication.current }) {
            // A second copy would take over the socket of the first one.
            NSApp.terminate(nil)
            return
        }

        settings = AppSettings()
        model = AppModel(settings: settings)

        let server = SocketServer { [weak model] data in
            Task { @MainActor in model?.handle(data) }
        }
        do {
            try server.start(path: Paths.socketPath)
            self.server = server
        } catch {
            showError("Claude Top cannot listen for hook events.", detail: String(describing: error))
        }

        setUpMainMenu()
        setUpStatusItem()
        setUpPopover()
        panel = LightPanelController(model: model) { [weak self] view in
            self?.togglePopover(relativeTo: view, edge: .minX)
        }
        if settings.showPanel { panel.show() }

        model.$light.combineLatest(model.$failing)
            .sink { [weak self] light, failing in self?.updateStatusItem(light, failing: failing) }
            .store(in: &subscriptions)

        model.refreshHookStatus()
        checkHooksAtLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private var actions: AppActions {
        AppActions(
            showSettings: { [weak self] in self?.showSettings() },
            togglePanel: { [weak self] in self?.togglePanel() },
            installHooks: { [weak self] in self?.installHooks() },
            removeHooks: { [weak self] in self?.removeHooks() },
            quit: { NSApp.terminate(nil) }
        )
    }

    /// The menu bar is hidden for this app, but text fields get ⌘C, ⌘V, and the
    /// other edit shortcuts only through the key equivalents of a main menu.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Claude Top", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(withTitle: "Claude Top", action: nil, keyEquivalent: "").submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Status item and popover

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon(.off)
    }

    private func setUpPopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(model: model, settings: settings, actions: actions)
        )
    }

    private func updateStatusItem(_ light: Light, failing: Bool) {
        statusFlashTimer?.invalidate()
        statusFlashTimer = nil
        updateStatusIcon(light)
        guard failing else { return }
        statusFlashTimer = Timer.scheduledTimer(withTimeInterval: Flash.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusIcon(light, lit: Flash.isLit(at: Date()))
            }
        }
    }

    private func updateStatusIcon(_ light: Light, lit: Bool = true) {
        let color = lit ? Palette.nsColor(for: light) : Palette.nsColor(for: light).withAlphaComponent(0.2)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            color.setFill()
            dot.fill()
            if light == .off {
                NSColor.secondaryLabelColor.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
            return true
        }
        image.isTemplate = false
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Claude Top"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(relativeTo: sender, edge: .minY)
        }
    }

    private func togglePopover(relativeTo view: NSView, edge: NSRectEdge) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.refreshHookStatus()
        model.prune()
        model.refreshITermTabs()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        popover.contentViewController?.view.window?.makeKey()
        startTabRefresh()
    }

    /// Tabs move and change titles, so the list asks iTerm2 again while it is open.
    private func startTabRefresh() {
        tabRefreshTimer?.invalidate()
        tabRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else {
                    timer.invalidate()
                    return
                }
                self.model.refreshITermTabs()
            }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Sessions…", action: #selector(menuShowSessions), keyEquivalent: "").target = self
        let panelItem = menu.addItem(withTitle: "Show Light Panel", action: #selector(menuTogglePanel), keyEquivalent: "")
        panelItem.target = self
        panelItem.state = settings.showPanel ? .on : .off
        menu.addItem(withTitle: "Settings…", action: #selector(menuShowSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Install Hooks…", action: #selector(menuInstallHooks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove Hooks…", action: #selector(menuRemoveHooks), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Top", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuShowSessions() {
        guard let button = statusItem.button else { return }
        togglePopover(relativeTo: button, edge: .minY)
    }

    @objc private func menuTogglePanel() { togglePanel() }
    @objc private func menuShowSettings() { showSettings() }
    @objc private func menuInstallHooks() { installHooks() }
    @objc private func menuRemoveHooks() { removeHooks() }

    // MARK: Panel and settings

    private func togglePanel() {
        settings.showPanel.toggle()
        if settings.showPanel { panel.show() } else { panel.hide() }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = Self.makeSettingsWindow(settings: settings, model: model, actions: actions)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    static func makeSettingsWindow(settings: AppSettings, model: AppModel, actions: AppActions) -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, model: model, actions: actions))
        // A grouped Form is a scroll view with no natural height, so the window
        // must not take its size from the SwiftUI content.
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.defaultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(SettingsView.defaultSize)
        window.contentMinSize = NSSize(width: SettingsView.defaultSize.width, height: 360)
        window.title = "Claude Top Settings"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    // MARK: Hooks

    private func checkHooksAtLaunch() {
        switch model.hookStatus {
        case .installed:
            break
        case .outdated:
            installHooks(intro: "The Claude Code hooks for Claude Top do not match this copy of the app. The app moved, or a new version adds events.")
        case .notInstalled:
            guard !settings.askedToInstall else { return }
            settings.askedToInstall = true
            installHooks(intro: "Claude Top needs Claude Code hooks to see your sessions.")
        }
    }

    private func installHooks() {
        installHooks(intro: nil)
    }

    private func installHooks(intro: String?) {
        popover.performClose(nil)
        let helperPath = model.helperPath
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            showError(
                "The hook helper is missing.",
                detail: "Expected it at \(helperPath). Build the app with scripts/build-app.sh, then open the .app bundle."
            )
            return
        }
        let file = SettingsFile()
        let updated: JSON
        do {
            updated = try HookInstaller.installing(into: try file.read(), helperPath: helperPath)
        } catch {
            showError("Claude Top cannot read \(file.resolvedURL.path).", detail: "The file was not changed.\n\n\(error)")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Install Claude Code hooks?"
        alert.informativeText = [
            intro,
            "Claude Top will add one entry for each of these events to \(file.resolvedURL.path):",
            HookInstaller.events.joined(separator: ", "),
            "It does not change your other hooks. It saves a backup of the file first.",
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.accessoryView = codeView(HookInstaller.handler(helperPath: helperPath).serialized())
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let backup = try file.write(updated)
            model.refreshHookStatus()
            showInfo(
                "Hooks installed.",
                detail: "Start new Claude Code sessions, or restart running ones, so that they use the hooks."
                    + (backup.map { "\n\nBackup: \($0.path)" } ?? "")
            )
        } catch {
            showError("Claude Top cannot write \(file.resolvedURL.path).", detail: String(describing: error))
        }
    }

    private func removeHooks() {
        popover.performClose(nil)
        let file = SettingsFile()
        let updated: JSON
        let current: JSON
        do {
            current = try file.read()
            updated = try HookInstaller.removing(from: current)
        } catch {
            showError("Claude Top cannot read \(file.resolvedURL.path).", detail: "The file was not changed.\n\n\(error)")
            return
        }
        guard updated != current else {
            showInfo("No hooks to remove.", detail: "\(file.resolvedURL.path) has no Claude Top entries.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Remove Claude Code hooks?"
        alert.informativeText = "Claude Top will remove only its own entries from \(file.resolvedURL.path). It saves a backup of the file first."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let backup = try file.write(updated)
            model.refreshHookStatus()
            showInfo("Hooks removed.", detail: backup.map { "Backup: \($0.path)" } ?? "")
        } catch {
            showError("Claude Top cannot write \(file.resolvedURL.path).", detail: String(describing: error))
        }
    }

    private func codeView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return scroll
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showInfo(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
