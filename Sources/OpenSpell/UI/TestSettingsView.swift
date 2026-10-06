import SwiftUI

struct TestSettingsView: View {
    @ObservedObject private var diag = Diagnostics.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var playground = Diagnostics.sample

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // 1. Automatic checks
                HStack {
                    SectionHeader(text: "1 · Health check")
                    Button {
                        Task { await diag.runChecks() }
                    } label: {
                        if diag.isRunningChecks {
                            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Checking…") }
                        } else {
                            Label("Run checks", systemImage: "play.fill")
                        }
                    }
                    .disabled(diag.isRunningChecks)
                }
                SettingsCard {
                    ForEach(Array(diag.checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { RowDivider() }
                        checkRow(check)
                    }
                }

                // 2. Live triggers
                SectionHeader(text: "2 · Try the triggers").padding(.top, 14)
                SettingsCard {
                    triggerRow(symbol: "keyboard", color: .blue,
                               title: "Keyboard shortcut",
                               prompt: "Press \(settings.hotKey?.displayString ?? "your shortcut") now — anywhere.",
                               state: diag.shortcutListen,
                               start: diag.listenForShortcut)
                    RowDivider()
                    triggerRow(symbol: "hand.point.up.left.fill", color: .purple,
                               title: "Force click",
                               prompt: "Press firmly on the trackpad now.",
                               state: diag.forceListen,
                               start: diag.listenForForceClick)
                    if diag.forceListen != .idle {
                        ForceDiagnosticsView()
                            .padding(.leading, 56).padding(.trailing, 14).padding(.bottom, 12)
                    }
                }
                Caption("While listening, the trigger is only detected — no correction runs.")

                // 3. End-to-end
                HStack {
                    SectionHeader(text: "3 · Full test in another app").padding(.top, 14)
                    Button {
                        Task { await diag.runEndToEnd() }
                    } label: {
                        if diag.isE2ERunning {
                            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Running…") }
                        } else {
                            Label("Run in TextEdit", systemImage: "play.fill")
                        }
                    }
                    .disabled(diag.isE2ERunning)
                    .padding(.top, 14)
                }
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        e2eStatus
                        if let before = diag.e2eOriginal, let after = diag.e2eResult {
                            Text(WordDiff.attributed(from: before, to: after))
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Caption("Opens a scratch document in TextEdit, selects it through Accessibility, and runs the real pipeline: read the selection → ask the model → paste back → check the result. Close the document afterwards without saving.")

                // 4. Playground
                SectionHeader(text: "4 · Playground").padding(.top, 14)
                TextEditor(text: $playground)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 80)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Caption("Select some text above, then press \(settings.hotKey?.displayString ?? "your shortcut") or press firmly.")
                    Spacer()
                    Button("Bring the typos back") { playground = Diagnostics.sample }
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 720)
        .task {
            if diag.checks.allSatisfy({ $0.status == .pending }) { await diag.runChecks() }
        }
    }

    // MARK: Rows

    private func checkRow(_ check: Diagnostics.Check) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(check.status).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.system(size: 13, weight: .semibold))
                if !check.detail.isEmpty {
                    Text(check.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let before = check.sampleOriginal, let after = check.sampleCorrected {
                    Text(WordDiff.attributed(from: before, to: after))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer()
            fixButton(for: check)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func fixButton(for check: Diagnostics.Check) -> some View {
        if check.status == .fail || check.status == .warn {
            switch check.id {
            case .accessibility:
                Button("Open Settings") {
                    AccessibilityPermission.request()
                    AccessibilityPermission.openSystemSettings()
                }
            case .shortcut:
                Button("Change…") { WindowManager.shared.showSettings(tab: .shortcut) }
            case .forceClick:
                if !ForceTouchMonitor.systemForceClickEnabled {
                    Button("Trackpad Settings") { ForceTouchMonitor.openTrackpadSettings() }
                } else {
                    Button("Open Settings") { AccessibilityPermission.openSystemSettings() }
                }
            case .model, .modelResponse:
                Button("Models…") { WindowManager.shared.showSettings(tab: .models) }
            }
        }
    }

    private func triggerRow(symbol: String, color: Color, title: String, prompt: String,
                            state: Diagnostics.Listen, start: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Group {
                    switch state {
                    case .idle: Text("Click Listen, then use the trigger.")
                    case .waiting: Text(prompt).foregroundStyle(Color.accentColor)
                    case .received(let date): Text("Received at \(date.formatted(date: .omitted, time: .standard)) ✓").foregroundStyle(.green)
                    case .timedOut: Text("Nothing received. Check the health results above.").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .waiting:
                ProgressView().controlSize(.small)
            case .received:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                Button("Again", action: start)
            case .timedOut:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                Button("Retry", action: start)
            case .idle:
                Button("Listen", action: start)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var e2eStatus: some View {
        switch diag.e2e {
        case .idle:
            Label("Not run yet.", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .running(let step):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step) }
        case .pass(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .fail(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: Diagnostics.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .off: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}

/// Live view of what the force-click listeners actually receive.
private struct ForceDiagnosticsView: View {
    @ObservedObject private var monitor = ForceTouchMonitor.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let threshold = ForceSensitivity.pressureThreshold(for: settings.forceSensitivity)
        VStack(alignment: .leading, spacing: 6) {
            PressureMeter(pressure: monitor.livePressure, threshold: threshold)
            Text("Pressure events — event tap: \(monitor.tapPressureEvents) · global monitor: \(monitor.monitorPressureEvents) · peak \(Int(monitor.peakPressure * 100)) % (trigger at \(Int(threshold * 100)) %)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            if let hint {
                Label(hint, systemImage: "lightbulb").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private var hint: String? {
        if !settings.forceClickEnabled { return "Force click is turned off in General." }
        if !ForceTouchMonitor.systemForceClickEnabled {
            return "Turn on “Force Click and haptic feedback” in System Settings › Trackpad."
        }
        if monitor.tapPressureEvents == 0 && monitor.monitorPressureEvents == 0 {
            return nil // nothing pressed yet (or no Force Touch trackpad / Force Click disabled in System Settings › Trackpad)
        }
        let threshold = ForceSensitivity.pressureThreshold(for: settings.forceSensitivity)
        if monitor.peakPressure < threshold {
            return "Pressure is arriving but never reached the trigger level — lower the sensitivity in General (e.g. Medium)."
        }
        return nil
    }
}
