import ClaudeTopCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static let defaultSize = NSSize(width: 480, height: 820)

    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel
    let actions: AppActions

    @State private var keyField = ""
    @State private var keyMessage: String?
    @State private var loginMessage: String?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var webhookURL = ""
    @State private var webhookHeaders = ""
    @State private var webhookMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Use Jev to classify Stop events", isOn: $settings.useJev)
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenRouter API key")
                    HStack {
                        SecureField("OpenRouter API key", text: $keyField, prompt: Text("sk-or-…"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            let status = model.saveAPIKey(keyField)
                            keyField = ""
                            keyMessage = status == errSecSuccess ? nil : "Keychain error \(status)"
                        }
                    }
                    Text(keyMessage ?? (model.hasAPIKey
                        ? "A key is in the Keychain. Save an empty field to delete it."
                        : "No key. The app uses the offline rule."))
                        .font(.caption)
                        .foregroundStyle(keyMessage == nil ? Color.secondary : Color.red)
                }
                TextField("Model ID", text: $settings.model)
                threshold("Red threshold", value: $settings.redThreshold)
                threshold("Amber threshold", value: $settings.amberThreshold)
                LabeledContent("Cost today", value: String(format: "$%.5f", settings.costToday))
                if let error = model.lastClassifierError {
                    Text("Last error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Stop classifier")
            } footer: {
                Text("With Jev on, the last message of each turn (up to 4,000 characters) goes to OpenRouter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Alerts") {
                Toggle("Sound on red", isOn: $settings.soundOnRed)
                Toggle("Sound on amber", isOn: $settings.soundOnAmber)
                Toggle("Notification on red", isOn: notifyBinding($settings.notifyOnRed))
                Toggle("Notification on amber", isOn: notifyBinding($settings.notifyOnAmber))
            }

            Section {
                Toggle("Send state changes to a webhook", isOn: $settings.webhookEnabled)
                TextField("URL", text: $webhookURL, prompt: Text("http://homeassistant.local:8123/api/webhook/…"))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Headers")
                    TextEditor(text: $webhookHeaders)
                        .font(.body.monospaced())
                        .frame(height: 54)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    Text("One header on each line, for example \"Authorization: Bearer …\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save") {
                        webhookMessage = model.saveWebhook(url: webhookURL, headers: webhookHeaders)
                    }
                    Button("Send Test", action: model.sendTestWebhook)
                        .disabled(model.webhookConfig == nil)
                }
                if let webhookMessage {
                    Text(webhookMessage).font(.caption).foregroundStyle(.red)
                }
                if let result = model.lastWebhookResult {
                    Text(webhookResultText(result))
                        .font(.caption)
                        .foregroundStyle(result.error == nil ? Color.secondary : Color.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Webhook")
            } footer: {
                Text("Each change sends a JSON POST. The URL and the headers are in the Keychain. Save an empty URL to delete them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show light panel", isOn: Binding(
                    get: { settings.showPanel },
                    set: { _ in actions.togglePanel() }
                ))
                Toggle("Open at login", isOn: Binding(
                    get: { openAtLogin },
                    set: setOpenAtLogin
                ))
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Claude Code hooks") {
                LabeledContent("Status", value: hookStatusText)
                HStack {
                    Button(model.hookStatus == .outdated ? "Update Hooks…" : "Install Hooks…", action: actions.installHooks)
                    Button("Remove Hooks…", action: actions.removeHooks)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: Self.defaultSize.width, minHeight: 360)
        .onAppear {
            model.refreshHookStatus()
            webhookURL = model.webhookConfig?.url.absoluteString ?? ""
            webhookHeaders = model.webhookConfig?.headersText ?? ""
        }
    }

    private func webhookResultText(_ result: WebhookResult) -> String {
        let time = result.date.formatted(date: .omitted, time: .standard)
        if let error = result.error { return "Last send (\(result.type), \(time)) failed: \(error)" }
        return "Last send (\(result.type), \(time)): HTTP \(result.status ?? 0)"
    }

    private var hookStatusText: String {
        switch model.hookStatus {
        case .installed: return "Installed"
        case .outdated: return "Out of date"
        case .notInstalled: return "Not installed"
        }
    }

    private func threshold(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0.05...0.95, step: 0.05)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.body.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private func notifyBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                if newValue { Notifier.requestAuthorization() }
            }
        )
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
