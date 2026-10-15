import AppKit
import ClaudeTopCore
import SwiftUI

enum Palette {
    static let red = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.0)
    static let green = Color(red: 0.20, green: 0.84, blue: 0.29)

    static func color(for state: SessionState) -> Color {
        switch state {
        case .attention: return red
        case .review: return amber
        case .working, .idle: return green
        }
    }

    /// Amber text is hard to read on a light background, so text uses a darker amber there.
    static func textColor(for state: SessionState) -> Color {
        guard state == .review else { return color(for: state) }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(amber)
                : NSColor(red: 0.72, green: 0.45, blue: 0.0, alpha: 1)
        })
    }

    static func nsColor(for light: Light) -> NSColor {
        switch light {
        case .red: return NSColor(red)
        case .amber: return NSColor(amber)
        case .green: return NSColor(green)
        case .off: return .tertiaryLabelColor
        }
    }
}

struct TrafficLightView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            Lamp(color: Palette.red, isOn: model.light == .red, badge: model.redCount)
            Lamp(color: Palette.amber, isOn: model.light == .amber, badge: model.amberCount)
            Lamp(color: Palette.green, isOn: model.light == .green, badge: 0)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .padding(8)
        .animation(.easeInOut(duration: 0.2), value: model.light)
    }
}

private struct Lamp: View {
    let color: Color
    let isOn: Bool
    let badge: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? color : color.opacity(0.16))
                .shadow(color: isOn ? color.opacity(0.85) : .clear, radius: isOn ? 6 : 0)
            if badge > 1 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isOn ? Color.black.opacity(0.7) : color)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// Lets the drag view below get all mouse events.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A drag moves the panel. A click without a drag opens the session list.
private final class DragClickView: NSView {
    var onClick: ((NSView) -> Void)?
    private var downLocation: NSPoint?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downLocation = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = downLocation else { return }
        let location = event.locationInWindow
        if hypot(location.x - start.x, location.y - start.y) > 3 {
            dragged = true
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?(self) }
        downLocation = nil
        dragged = false
    }
}

@MainActor
final class LightPanelController {
    private let panel: NSPanel

    init(model: AppModel, onClick: @escaping (NSView) -> Void) {
        let hosting = PassthroughHostingView(rootView: TrafficLightView(model: model))
        let size = hosting.fittingSize

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = true

        let container = DragClickView(frame: NSRect(origin: .zero, size: size))
        container.onClick = onClick
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        if !panel.setFrameUsingName("LightPanel") {
            positionTopRight(size: size)
        }
        panel.setFrameAutosaveName("LightPanel")
    }

    private func positionTopRight(size: NSSize) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16))
    }

    var isVisible: Bool { panel.isVisible }

    func show() { panel.orderFrontRegardless() }

    func hide() { panel.orderOut(nil) }
}
