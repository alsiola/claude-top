import AppKit
import ClaudeTopCore
import Combine
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var light: Light = .off
    /// One or more sessions failed with an API error. The red light flashes.
    @Published private(set) var failing = false
    @Published private(set) var redCount = 0
    @Published private(set) var amberCount = 0
    @Published private(set) var hookStatus: HookInstaller.Status = .notInstalled
    @Published private(set) var hasAPIKey = false
    @Published private(set) var lastClassifierError: String?
    /// Live iTerm2 tabs by session UUID. Empty when iTerm2 does not answer.
    @Published private(set) var itermTabs: [String: ITermTab] = [:]
    @Published private(set) var webhookConfig: WebhookConfig?
    @Published private(set) var lastWebhookResult: WebhookResult?

    let settings: AppSettings
    private var store: SessionStore
    private var placeholders: [Session] = []
    private var apiKey: String?
    /// The sessions at the last webhook diff.
    private var webhookSessions: [String: Session]
    /// Each delivery waits for the one before it, so the receiver gets the events in order.
    private var webhookDelivery: Task<Void, Never>?
    private var pruneTimer: Timer?
    private let storageURL: URL?
    private let scanProcesses: () -> [ClaudeProcess]

    private static let pruneInterval: TimeInterval = 30
    private static let maxIdleMs: Int64 = 12 * 60 * 60 * 1000

    init(
        settings: AppSettings,
        storageURL: URL? = Paths.sessionsFile,
        scanProcesses: @escaping () -> [ClaudeProcess] = ProcessScanner.claudeProcesses,
        readAPIKey: () -> String? = Keychain.openRouter.read,
        readWebhookConfig: () -> WebhookConfig? = Keychain.readWebhook
    ) {
        self.settings = settings
        self.storageURL = storageURL
        self.scanProcesses = scanProcesses
        store = SessionStore(restoring: Self.load(from: storageURL))
        webhookSessions = store.sessions
        apiKey = readAPIKey()
        webhookConfig = readWebhookConfig()
        hasAPIKey = !(apiKey ?? "").isEmpty
        pruneTimer = Timer.scheduledTimer(withTimeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        prune()
    }

    private static func load(from url: URL?) -> [Session] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
    }

    private func save() {
        guard let storageURL else { return }
        let sessions = Array(store.sessions.values)
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? JSONEncoder().encode(sessions).write(to: storageURL, options: .atomic)
    }

    var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(HookInstaller.helperName)").path
    }

    // MARK: Events

    func handle(_ data: Data) {
        guard let envelope = try? Envelope.decode(data),
              let sessionID = envelope.payload.sessionID
        else { return }
        let before = store.sessions[sessionID]?.state
        let request = store.apply(envelope)
        if let pid = envelope.context?.claudePID {
            placeholders.removeAll { $0.context?.claudePID == pid }
        }
        publish()
        announce(sessionID, before: before)
        if let request { classify(request) }
    }

    private func classify(_ request: ClassifyRequest) {
        let chain = StopClassifierChain(primary: makeClassifier())
        Task { [weak self] in
            let (result, error) = await chain.classify(request.input)
            guard let self else { return }
            self.lastClassifierError = error.map { String(describing: $0) }
            if let cost = result.cost { self.settings.addCost(cost) }
            let before = self.store.sessions[request.sessionID]?.state
            if self.store.applyClassification(request, result) {
                self.publish()
                self.announce(request.sessionID, before: before)
            }
        }
    }

    private func makeClassifier() -> StopClassifier? {
        guard settings.useJev, let apiKey, !apiKey.isEmpty else { return nil }
        return JevClassifier(apiKey: apiKey, model: settings.trimmedModel, thresholds: settings.thresholds)
    }

    /// Removes sessions whose process stopped, and finds processes with no events yet.
    func prune() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        store.prune(nowMs: nowMs, maxIdleMs: Self.maxIdleMs) { pid in
            kill(pid, 0) == 0 || errno == EPERM
        }
        placeholders = store.placeholders(for: scanProcesses())
        publish()
    }

    func refreshITermTabs() {
        if let tabs = ITermFocuser.listTabs() { itermTabs = tabs }
    }

    func tab(for session: Session) -> (number: Int?, title: String?) {
        let id = session.context?.itermSessionID
        if let uuid = ITermSessionID.uuid(from: id), let tab = itermTabs[uuid] {
            let title = tab.displayTitle
            return (tab.tabIndex, title.isEmpty ? nil : title)
        }
        return (ITermSessionID.startTabNumber(from: id), nil)
    }

    private func publish() {
        let rows = store.sorted + placeholders
        if rows != sessions { sessions = rows }
        let oldLight = light
        let newLight = store.light == .off && !placeholders.isEmpty ? .green : store.light
        if newLight != light { light = newLight }
        if store.isFailing != failing { failing = store.isFailing }
        redCount = store.count(.attention) + store.count(.failed)
        amberCount = store.count(.review)
        let events = WebhookEvent.diff(from: webhookSessions, to: store.sessions, oldLight: oldLight, newLight: newLight)
        webhookSessions = store.sessions
        if settings.webhookEnabled { deliver(events) }
        save()
    }

    // MARK: User actions

    func dismiss(_ sessionID: String) {
        store.dismiss(sessionID)
        publish()
    }

    func remove(_ sessionID: String) {
        store.remove(sessionID)
        publish()
    }

    func focus(_ session: Session) {
        ITermFocuser.focus(session.context)
    }

    /// Going to a red or amber session counts as seeing it. Without this, a
    /// wrong classification would keep the light on until the next prompt.
    func open(_ session: Session) {
        if !session.discovered, session.state.needsYou {
            dismiss(session.id)
        }
        focus(session)
    }

    func saveAPIKey(_ key: String) -> OSStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.openRouter.delete()
            apiKey = nil
            hasAPIKey = false
            return errSecSuccess
        }
        let status = Keychain.openRouter.save(trimmed)
        if status == errSecSuccess {
            apiKey = trimmed
            hasAPIKey = true
        }
        return status
    }

    // MARK: Webhook

    func saveWebhook(url: String, headers: String) -> String? {
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Keychain.webhook.delete()
            webhookConfig = nil
            return nil
        }
        do {
            let config = try WebhookConfig(url: url, headers: headers)
            let status = Keychain.saveWebhook(config)
            guard status == errSecSuccess else { return "Keychain error \(status)" }
            webhookConfig = config
            return nil
        } catch {
            return String(describing: error)
        }
    }

    func sendTestWebhook() {
        deliver([.test])
    }

    private func deliver(_ events: [WebhookEvent]) {
        guard let config = webhookConfig, !events.isEmpty else { return }
        let client = WebhookClient(config: config)
        let messages = events.map {
            WebhookMessage(event: $0, timestamp: Date(), light: light, red: redCount, amber: amberCount)
        }
        let previous = webhookDelivery
        webhookDelivery = Task { [weak self] in
            await previous?.value
            for message in messages {
                let result: WebhookResult
                do {
                    let status = try await client.send(message)
                    result = WebhookResult(date: Date(), type: message.event.type, error: nil, status: status)
                } catch {
                    result = WebhookResult(date: Date(), type: message.event.type, error: String(describing: error), status: nil)
                }
                self?.lastWebhookResult = result
            }
        }
    }

    func refreshHookStatus() {
        guard let root = try? SettingsFile().read() else {
            hookStatus = .notInstalled
            return
        }
        hookStatus = HookInstaller.status(of: root, helperPath: helperPath)
    }

    // MARK: Alerts

    private func announce(_ sessionID: String, before: SessionState?) {
        guard let session = store.sessions[sessionID], session.state != before else { return }
        let sound: Bool
        let notify: Bool
        switch session.state {
        case .failed, .attention:
            sound = settings.soundOnRed
            notify = settings.notifyOnRed
        case .review:
            sound = settings.soundOnAmber
            notify = settings.notifyOnAmber
        case .working, .idle:
            return
        }
        if sound {
            NSSound(named: session.state.light == .red ? "Sosumi" : "Glass")?.play()
        }
        if notify {
            Notifier.post(
                title: session.project,
                body: session.reason ?? SessionRow.defaultDetail(session.state)
            )
        }
    }
}

struct WebhookResult: Equatable {
    var date: Date
    var type: String
    var error: String?
    var status: Int?
}

enum Notifier {
    /// The notification center needs an app bundle. `swift run` has none.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
