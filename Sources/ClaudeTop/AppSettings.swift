import ClaudeTopCore
import Foundation
import Security

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var useJev: Bool { didSet { defaults.set(useJev, forKey: Keys.useJev) } }
    @Published var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    @Published var redThreshold: Double { didSet { defaults.set(redThreshold, forKey: Keys.redThreshold) } }
    @Published var amberThreshold: Double { didSet { defaults.set(amberThreshold, forKey: Keys.amberThreshold) } }
    @Published var soundOnRed: Bool { didSet { defaults.set(soundOnRed, forKey: Keys.soundOnRed) } }
    @Published var soundOnAmber: Bool { didSet { defaults.set(soundOnAmber, forKey: Keys.soundOnAmber) } }
    @Published var notifyOnRed: Bool { didSet { defaults.set(notifyOnRed, forKey: Keys.notifyOnRed) } }
    @Published var notifyOnAmber: Bool { didSet { defaults.set(notifyOnAmber, forKey: Keys.notifyOnAmber) } }
    @Published var showPanel: Bool { didSet { defaults.set(showPanel, forKey: Keys.showPanel) } }
    @Published var askedToInstall: Bool { didSet { defaults.set(askedToInstall, forKey: Keys.askedToInstall) } }
    @Published var webhookEnabled: Bool { didSet { defaults.set(webhookEnabled, forKey: Keys.webhookEnabled) } }
    @Published private(set) var costToday: Double = 0

    private enum Keys {
        static let useJev = "useJev"
        static let model = "model"
        static let redThreshold = "redThreshold"
        static let amberThreshold = "amberThreshold"
        static let soundOnRed = "soundOnRed"
        static let soundOnAmber = "soundOnAmber"
        static let notifyOnRed = "notifyOnRed"
        static let notifyOnAmber = "notifyOnAmber"
        static let showPanel = "showPanel"
        static let askedToInstall = "askedToInstall"
        static let webhookEnabled = "webhookEnabled"
        static let costDay = "costDay"
        static let costTotal = "costTotal"
    }

    init() {
        defaults.register(defaults: [
            Keys.useJev: true,
            Keys.model: JevClassifier.defaultModel,
            Keys.redThreshold: 0.5,
            Keys.amberThreshold: 0.5,
            Keys.showPanel: true,
        ])
        useJev = defaults.bool(forKey: Keys.useJev)
        model = defaults.string(forKey: Keys.model) ?? JevClassifier.defaultModel
        redThreshold = defaults.double(forKey: Keys.redThreshold)
        amberThreshold = defaults.double(forKey: Keys.amberThreshold)
        soundOnRed = defaults.bool(forKey: Keys.soundOnRed)
        soundOnAmber = defaults.bool(forKey: Keys.soundOnAmber)
        notifyOnRed = defaults.bool(forKey: Keys.notifyOnRed)
        notifyOnAmber = defaults.bool(forKey: Keys.notifyOnAmber)
        showPanel = defaults.bool(forKey: Keys.showPanel)
        askedToInstall = defaults.bool(forKey: Keys.askedToInstall)
        webhookEnabled = defaults.bool(forKey: Keys.webhookEnabled)
        costToday = defaults.string(forKey: Keys.costDay) == Self.today() ? defaults.double(forKey: Keys.costTotal) : 0
    }

    var thresholds: Thresholds {
        Thresholds(red: redThreshold, amber: amberThreshold)
    }

    var trimmedModel: String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? JevClassifier.defaultModel : value
    }

    func addCost(_ cost: Double) {
        let today = Self.today()
        if defaults.string(forKey: Keys.costDay) != today {
            defaults.set(today, forKey: Keys.costDay)
            costToday = 0
        }
        costToday += cost
        defaults.set(costToday, forKey: Keys.costTotal)
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

struct Keychain {
    static let openRouter = Keychain(account: "openrouter-api-key")
    /// The URL and the headers together, as JSON. Both can contain a secret.
    static let webhook = Keychain(account: "webhook")

    private static let service = "ClaudeTop"
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) -> OSStatus {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func readWebhook() -> WebhookConfig? {
        guard let text = webhook.read() else { return nil }
        return try? JSONDecoder().decode(WebhookConfig.self, from: Data(text.utf8))
    }

    static func saveWebhook(_ config: WebhookConfig) -> OSStatus {
        guard let data = try? JSONEncoder().encode(config) else { return errSecParam }
        return webhook.save(String(decoding: data, as: UTF8.self))
    }
}
