import Combine
import SwiftUI

struct SetupAssistantView: View {
    var onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, accessibility, model, forceClick, tryIt }

    @State private var step: Step = .welcome
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .accessibility: AccessibilityStep()
                case .model: ModelStep()
                case .forceClick: CalibrationStep()
                case .tryIt: TryItStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { s in
                        Circle().fill(s == step ? Color.accentColor : Color.primary.opacity(0.2)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step != .welcome {
                    Button("Back") { go(-1) }
                }
                if step == .tryIt {
                    Button("Done") {
                        settings.hasCompletedSetup = true
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(step == .welcome ? "Get Started" : "Continue") { go(1) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
    }

    private func go(_ delta: Int) {
        withAnimation(.snappy) {
            step = Step(rawValue: step.rawValue + delta) ?? step
        }
    }
}

private struct StepHeader: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            IconBadge(symbol: symbol, color: color, size: 56)
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            StepHeader(symbol: "text.badge.checkmark", color: .blue, title: "Fix typos in any app",
                       subtitle: "Select text anywhere, press ⇧⌘Space or press firmly on your trackpad, and the corrected text replaces your selection — right where you type.")
            VStack(alignment: .leading, spacing: 12) {
                bullet("menubar.rectangle", "Lives quietly in your menu bar. No Dock icon.")
                bullet("lock.shield", "On-device models keep every word on your Mac.")
                bullet("cloud", "Or bring your own OpenRouter key for cloud models.")
                bullet("clock.arrow.circlepath", "A history of every fix, so you can go back.")
            }
            .padding(20)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            Spacer()
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.blue).frame(width: 22) }
    }
}

private struct AccessibilityStep: View {
    @State private var trusted = AccessibilityPermission.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(symbol: "accessibility", color: .teal, title: "Allow Accessibility",
                       subtitle: "OpenSpell needs Accessibility access to read your selection and write the corrected text back. macOS asks once, under System Settings › Privacy & Security › Accessibility.")
            if trusted {
                Label("Accessibility allowed", systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.green)
            } else {
                VStack(spacing: 10) {
                    Button("Open System Settings") {
                        AccessibilityPermission.request()
                        AccessibilityPermission.openSystemSettings()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Caption("Turn on OpenSpell in the list. This page updates automatically.")
                }
            }
            Spacer()
        }
        .onReceive(poll) { _ in
            let now = AccessibilityPermission.isTrusted
            if now && !trusted { ForceTouchMonitor.shared.start() }
            trusted = now
        }
    }
}

private struct ModelStep: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var apiKey = OpenRouterClient.apiKey ?? ""
    @State private var geminiKey = GeminiClient.apiKey ?? ""

    var body: some View {
        let model = ModelStore.recommended.first { $0.repo == "mlx-community/gemma-3n-E4B-it-lm-4bit" } ?? ModelStore.recommended[0]
        let modelEntry = store.entry(forRepo: model.repo, kind: .local)

        VStack(spacing: 20) {
            StepHeader(symbol: "brain", color: .pink, title: "Choose a language model",
                       subtitle: "Run a model privately on your Mac, or use a cloud model with your own Gemini or OpenRouter key. You can change this any time in Settings › Models.")

            SettingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text("On-device: \(model.name)").bold(); Pill(text: model.size) }
                        Caption("Private, free and offline. Needs Apple silicon.")
                    }
                    Spacer()
                    if let modelEntry {
                        switch store.state(of: modelEntry) {
                        case .downloading(let p): ProgressView(value: p).frame(width: 120)
                        case .ready:
                            if store.selectedID == modelEntry.id {
                                Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Use") { store.select(modelEntry) }
                            }
                        default: Button("Download") { store.downloadLocal(repo: model.repo, displayName: model.name) }
                        }
                    } else {
                        Button("Download") { store.downloadLocal(repo: model.repo, displayName: model.name) }
                            .disabled(!ModelStore.isAppleSilicon)
                    }
                }
                .padding(14)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkle").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cloud: Gemini Flash with a Google key").bold()
                            Caption("Free tier available at aistudio.google.com. Your text is sent to Google.")
                        }
                        Spacer()
                        if store.hasGeminiKey, store.selected?.kind == .gemini {
                            Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    HStack {
                        SecureField("Gemini API key", text: $geminiKey).textFieldStyle(.roundedBorder)
                        Button("Save & Use") {
                            Task {
                                await store.saveGeminiKey(geminiKey)
                                if let gemini = store.entries.first(where: { $0.kind == .gemini }) { store.select(gemini) }
                            }
                        }
                        .disabled(geminiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "cloud").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cloud: any model via OpenRouter").bold()
                            Caption("Free models work with a free key. Your text is sent to OpenRouter.")
                        }
                        Spacer()
                        if store.hasAPIKey, store.selected?.kind == .cloud {
                            Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    HStack {
                        SecureField("OpenRouter API key (sk-or-…)", text: $apiKey).textFieldStyle(.roundedBorder)
                        Button("Save & Use") {
                            Task {
                                await store.saveAPIKey(apiKey)
                                // Free-tier keys already switched to a free model; otherwise use the best OpenRouter entry.
                                if store.selected?.kind != .cloud, let cloud = store.entries.first(where: { $0.kind == .cloud }) {
                                    store.select(cloud)
                                }
                            }
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
            }
            Spacer()
        }
    }
}

private struct CalibrationStep: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var pressure: Double = 0
    @State private var currentPeak: Double = 0
    @State private var peaks: [Double] = []

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(symbol: "hand.point.up.left.fill", color: .purple, title: "Learn your press",
                       subtitle: "Press firmly on the pad below three times, the way you'd like to trigger a correction. Light clicks will stay clicks.")

            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.purple.opacity(0.10))
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.purple.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { i in
                            Image(systemName: i < peaks.count ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(i < peaks.count ? .green : .secondary)
                        }
                    }
                    Text(peaks.count >= 3 ? "Calibrated!" : "Press firmly here").foregroundStyle(.secondary)
                }
                PressurePad(onPressure: { _, p in
                    pressure = p
                    currentPeak = max(currentPeak, p)
                }, onRelease: {
                    pressure = 0
                    if currentPeak > 0.2, peaks.count < 3 {
                        peaks.append(currentPeak)
                        if peaks.count == 3 { applyCalibration() }
                    }
                    currentPeak = 0
                })
            }
            .frame(height: 140)

            PressureMeter(pressure: pressure, threshold: ForceSensitivity.pressureThreshold(for: settings.forceSensitivity))

            HStack {
                Toggle("Use force click to correct", isOn: $settings.forceClickEnabled)
                Spacer()
                Text("Sensitivity: \(ForceSensitivity.label(for: settings.forceSensitivity)) · \(Int(settings.forceSensitivity))")
                    .monospacedDigit().foregroundStyle(.secondary)
                Button("Redo") { peaks = [] }.disabled(peaks.isEmpty)
            }
            Caption("No Force Touch trackpad? Skip this — the keyboard shortcut works on every Mac.")
            Spacer()
        }
        .onAppear { ForceTouchMonitor.shared.isSuspended = true }
        .onDisappear { ForceTouchMonitor.shared.isSuspended = false }
    }

    private func applyCalibration() {
        let average = peaks.reduce(0, +) / Double(peaks.count)
        // Trigger a bit below the user's typical firm press.
        settings.forceSensitivity = ForceSensitivity.value(forPressure: average * 0.85).rounded()
    }
}

private struct TryItStep: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var text = "Hi Sarah,\nI beleive we can definately ship the new featur by tommorow."

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(symbol: "sparkles", color: .orange, title: "Try it",
                       subtitle: "Select the text below, then press \(settings.hotKey?.displayString ?? "your shortcut") — or press firmly on the trackpad.")
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .frame(height: 140)
            HStack {
                Button("Bring the typos back") {
                    text = "Hi Sarah,\nI beleive we can definately ship the new featur by tommorow."
                }
                Spacer()
                if ModelStore.shared.selected.map(ModelStore.shared.isReady) != true {
                    Label("No ready model yet — go back a step.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            Spacer()
        }
    }
}
