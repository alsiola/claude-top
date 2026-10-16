import AppKit
import ClaudeTopCore
import SwiftUI

struct AppActions {
    var showSettings: () -> Void
    var togglePanel: () -> Void
    var installHooks: () -> Void
    var removeHooks: () -> Void
    var quit: () -> Void
}

struct SessionListView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let actions: AppActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Claude sessions").font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.redCount > 0 { CountChip(count: model.redCount, label: "need you", color: Palette.red) }
                if model.amberCount > 0 { CountChip(count: model.amberCount, label: "to review", color: Palette.amber) }
                if model.redCount == 0 && model.amberCount == 0 {
                    Text("\(model.sessions.count) running").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if model.sessions.isEmpty {
                VStack(spacing: 6) {
                    Text("No sessions").font(.headline)
                    Text("Start Claude Code in iTerm2. Sessions show here after their first event.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.sessions) { session in
                            SessionRow(session: session, model: model, tab: model.tab(for: session))
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                if model.hookStatus != .installed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
                    Button(model.hookStatus == .outdated ? "Update hooks…" : "Install hooks…", action: actions.installHooks)
                        .buttonStyle(.link)
                } else {
                    Text("Click a row to go to its tab and clear it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Menu {
                    Button(settings.showPanel ? "Hide Light Panel" : "Show Light Panel", action: actions.togglePanel)
                    Button("Settings…", action: actions.showSettings)
                    Divider()
                    Button("Install Hooks…", action: actions.installHooks)
                    Button("Remove Hooks…", action: actions.removeHooks)
                    Divider()
                    Button("Quit Claude Top", action: actions.quit)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
    }
}

private struct CountChip: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)").font(.callout.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
    }
}

struct SessionRow: View {
    let session: Session
    let model: AppModel
    /// Passed as a value, so that the row draws again when the iTerm2 tabs change.
    let tab: (number: Int?, title: String?)
    @State private var hovering = false

    private var needsYou: Bool {
        !session.discovered && session.state.needsYou
    }

    private var dotColor: Color {
        session.discovered ? Color.secondary.opacity(0.5) : Palette.color(for: session.state)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .opacity(session.state == .idle && !session.discovered ? 0.5 : 1)
                .shadow(color: needsYou ? dotColor.opacity(0.7) : .clear, radius: 4)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title ?? session.project)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 12.5, weight: needsYou ? .medium : .regular))
                    .foregroundStyle(needsYou ? Palette.textColor(for: session.state) : Color.secondary)
                    .lineLimit(session.state == .failed ? 2 : 1)
                if !location.isEmpty {
                    Text(location)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if !session.discovered {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(Self.age(from: session.lastEventMs, now: context.date))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 15))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : (needsYou ? dotColor.opacity(0.07) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onTapGesture { model.open(session) }
        .help(needsYou ? "Go to this tab and clear the color" : "Go to this tab")
        .contextMenu {
            Button("Go to Session") { model.focus(session) }
            if !session.discovered {
                Button("Clear (Set to Green)") { model.dismiss(session.id) }
                Button("Remove from List") { model.remove(session.id) }
            }
        }
    }

    /// The project is already the first line when there is no tab title.
    private var location: String {
        var parts: [String] = tab.title == nil ? [] : [session.project]
        if let number = tab.number { parts.append("Tab \(number)") }
        return parts.joined(separator: " · ")
    }

    private var detail: String {
        if session.classifying { return "Checking…" }
        return session.reason ?? Self.defaultDetail(session.state)
    }

    static func defaultDetail(_ state: SessionState) -> String {
        switch state {
        case .working: return "Working"
        case .idle: return "Idle"
        case .review: return "Ready for review"
        case .attention: return "Needs you"
        case .failed: return "Something went wrong"
        }
    }

    static func age(from ms: Int64, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - Int(ms / 1000))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
