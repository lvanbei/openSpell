import AppKit
import SwiftUI

// MARK: - Building blocks shared by the settings screens

struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 56) }
}

struct Pill: View {
    let text: String
    var color: Color = .green

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color == .green ? Color.green.mix(with: .primary, by: 0.35) : color)
    }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Keyboard shortcut recorder

struct KeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Type shortcut…" : (combo?.displayString ?? "Record shortcut"))
                .font(.system(size: 14, weight: .medium))
                .frame(minWidth: 180)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
        .help("Click, then press the key combination. Esc cancels, ⌫ clears.")
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
            } else if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function]).isEmpty { // ⌫
                combo = nil
                stop()
            } else if let new = KeyCombo(event: event) {
                combo = new
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeyCenter.shared.resume() }
        recording = false
    }
}

// MARK: - Pressure pad (force click test / calibration)

/// An AppKit view that reports trackpad pressure for presses *inside* it.
struct PressurePad: NSViewRepresentable {
    /// (stage, effective stage-1 pressure 0…1)
    var onPressure: (Int, Double) -> Void
    var onRelease: () -> Void = {}

    func makeNSView(context: Context) -> PadView {
        let v = PadView()
        v.onPressure = onPressure
        v.onRelease = onRelease
        return v
    }

    func updateNSView(_ nsView: PadView, context: Context) {
        nsView.onPressure = onPressure
        nsView.onRelease = onRelease
    }

    final class PadView: NSView {
        var onPressure: ((Int, Double) -> Void)?
        var onRelease: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func pressureChange(with event: NSEvent) {
            let effective: Double = event.stage >= 2 ? 1 : (event.stage == 1 ? Double(event.pressure) : 0)
            onPressure?(event.stage, effective)
        }

        override func mouseDown(with event: NSEvent) {
            // Configure pressure so stage 2 still exists but doesn't do anything here.
            pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        }

        override func mouseUp(with event: NSEvent) {
            onRelease?()
        }
    }
}

/// Live pressure meter with the current threshold marked.
struct PressureMeter: View {
    let pressure: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(pressure >= threshold ? Color.green.gradient : Color.purple.gradient)
                    .frame(width: max(8, geo.size.width * pressure))
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: geo.size.height + 8)
                    .offset(x: geo.size.width * threshold - 1)
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.05), value: pressure)
    }
}

struct ForceTestView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var pressure: Double = 0
    @State private var peak: Double = 0
    @State private var triggered = false

    var body: some View {
        let threshold = ForceSensitivity.pressureThreshold(for: settings.forceSensitivity)
        VStack(spacing: 14) {
            Text("Press firmly on the pad").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(triggered ? Color.green.opacity(0.25) : Color.primary.opacity(0.06))
                VStack(spacing: 6) {
                    Image(systemName: triggered ? "checkmark.circle.fill" : "hand.point.up.left")
                        .font(.system(size: 30))
                        .foregroundStyle(triggered ? .green : .secondary)
                    Text(triggered ? "That would start a correction" : "Light clicks stay clicks")
                        .font(.callout).foregroundStyle(.secondary)
                }
                PressurePad(onPressure: { _, p in
                    pressure = p
                    peak = max(peak, p)
                    if p >= threshold { triggered = true }
                }, onRelease: {
                    pressure = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { triggered = false; peak = 0 }
                })
            }
            .frame(width: 280, height: 140)

            PressureMeter(pressure: pressure, threshold: threshold).frame(width: 280)
            Text("Peak \(Int(peak * 100)) %  ·  trigger at \(Int(threshold * 100)) %")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { ForceTouchMonitor.shared.isSuspended = true }
        .onDisappear { ForceTouchMonitor.shared.isSuspended = false }
    }
}
