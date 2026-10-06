import AppKit
import SwiftUI

enum BubbleState: Equatable {
    case correcting
    case done(String)
    case info(String)
    case error(String)
}

@MainActor
final class BubbleModel: ObservableObject {
    @Published var state: BubbleState = .correcting
}

/// Floating, non-activating "Correcting…" pill. Never steals focus from the app being edited.
@MainActor
final class Bubble {
    static let shared = Bubble()

    private let model = BubbleModel()
    private lazy var panel: NSPanel = makePanel()
    private var hideWorkItem: DispatchWorkItem?

    func show(_ state: BubbleState, anchor: CGRect?, position: BubblePosition? = nil) {
        hideWorkItem?.cancel()
        model.state = state
        let hosting = panel.contentView as! NSHostingView<BubbleView>
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, anchor: anchor, position: position ?? AppSettings.shared.bubblePosition))
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
    }

    func flash(_ state: BubbleState, anchor: CGRect?, duration: TimeInterval = 1.4, position: BubblePosition? = nil) {
        // Keep the pill where it already is if it's visible (e.g. Correcting… → Corrected).
        if panel.isVisible {
            hideWorkItem?.cancel()
            model.state = state
            let hosting = panel.contentView as! NSHostingView<BubbleView>
            let old = panel.frame
            let size = hosting.fittingSize
            panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height), display: true)
        } else {
            show(state, anchor: anchor, position: position)
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { [panel] in panel.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: BubbleView(model: model))
        return panel
    }

    private func origin(for size: CGSize, anchor: CGRect?, position: BubblePosition) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let reference = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? mouse
        let screen = NSScreen.screens.first { $0.frame.contains(reference) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let margin: CGFloat = 14

        let top = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - margin)
        let bottom = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + margin + 40)

        switch position {
        case .top:
            return top
        case .bottom:
            return bottom
        case .cursor:
            var p = CGPoint(x: mouse.x + 14, y: mouse.y - size.height - 14)
            p.x = min(max(p.x, visible.minX + margin), visible.maxX - size.width - margin)
            p.y = min(max(p.y, visible.minY + margin), visible.maxY - size.height - margin)
            return p
        case .auto:
            // Stay out of the way of the text: selection in the upper half → show at the bottom.
            return reference.y > visible.midY ? bottom : top
        }
    }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(12) // room for the shadow
        .fixedSize()
        .animation(.snappy, value: model.state)
    }

    @ViewBuilder private var icon: some View {
        switch model.state {
        case .correcting:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .info:
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var text: String {
        switch model.state {
        case .correcting: "Correcting…"
        case .done(let s), .info(let s), .error(let s): s
        }
    }
}
