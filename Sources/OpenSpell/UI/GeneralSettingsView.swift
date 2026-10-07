import Combine
import OpenSpellCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var axTrusted = AccessibilityPermission.isTrusted
    @State private var showingTest = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            SettingsCard {
                SettingsRow(symbol: "globe", color: .blue, title: "Language",
                            subtitle: "Hint for the model. Auto keeps whatever language you write in.") {
                    Picker("", selection: $settings.language) {
                        ForEach(CorrectionLanguage.allCases) { lang in
                            Text("\(lang.flag)  \(lang.name)").tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                RowDivider()
                SettingsRow(symbol: "accessibility", color: .teal, title: "Accessibility",
                            subtitle: "Required to read the selection and write back the corrected text.") {
                    if axTrusted {
                        Button("Allowed") {}.disabled(true)
                    } else {
                        Button("Allow…") {
                            AccessibilityPermission.request()
                            AccessibilityPermission.openSystemSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                RowDivider()
                SettingsRow(symbol: "power", color: .gray, title: "Launch at login") {
                    Toggle("", isOn: Binding(get: { settings.launchAtLogin },
                                             set: { settings.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                forceClickSection
            }

            SettingsCard {
                SettingsRow(symbol: "capsule.fill", color: Color(white: 0.35), title: "Bubble position",
                            subtitle: "Where “Correcting…” appears. Auto picks the top or bottom of the screen, away from your selection.") {
                    HStack(spacing: 8) {
                        Picker("", selection: $settings.bubblePosition) {
                            ForEach(BubblePosition.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230)
                        Button {
                            Bubble.shared.flash(.correcting, anchor: nil, duration: 2)
                        } label: { Label("Preview", systemImage: "eye") }
                    }
                }
            }

            SettingsCard {
                SettingsRow(symbol: "clock.arrow.circlepath", color: .orange, title: "Keep history",
                            subtitle: "Every correction is saved on this Mac with the app it came from.") {
                    HStack {
                        Button("Open History") { WindowManager.shared.showHistory() }
                        Toggle("", isOn: $settings.keepHistory).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .onReceive(poll) { _ in
            axTrusted = AccessibilityPermission.isTrusted
            settings.refreshLaunchAtLogin()
        }
    }

    private var forceClickSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(symbol: "hand.point.up.left.fill", color: .purple, title: "Force click sensitivity",
                        subtitle: "How firmly you need to press to start a correction.") {
                HStack(spacing: 8) {
                    Toggle("", isOn: $settings.forceClickEnabled).toggleStyle(.switch).labelsHidden()
                        .help("Use a firm trackpad press as a trigger")
                    Text("\(ForceSensitivity.label(for: settings.forceSensitivity)) · \(Int(settings.forceSensitivity))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    Button { showingTest = true } label: { Label("Test", systemImage: "waveform") }
                        .popover(isPresented: $showingTest) { ForceTestView() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Slider(value: Binding(get: { settings.forceSensitivity },
                                      set: { settings.forceSensitivity = ($0 / 10).rounded() * 10 }),
                       in: ForceSensitivity.range)
                    .tint(.purple)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { settings.forceSensitivity = ForceSensitivity.medium })
                presetLabels
                Caption("Drag the slider or pick a preset. Double-click to reset to “Medium”.")
                    .padding(.top, 4)
                if !ForceTouchMonitor.systemForceClickEnabled {
                    HStack {
                        Label("“Force Click and haptic feedback” is off in System Settings › Trackpad — firm presses can't be detected.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Button("Open") { ForceTouchMonitor.openTrackpadSettings() }
                    }
                }
            }
            .padding(.leading, 56)
            .padding(.trailing, 14)
            .padding(.bottom, 12)
            .disabled(!settings.forceClickEnabled)
            .opacity(settings.forceClickEnabled ? 1 : 0.5)
        }
    }

    private var presetLabels: some View {
        GeometryReader { geo in
            let span = ForceSensitivity.range.upperBound - ForceSensitivity.range.lowerBound
            ForEach([("Light", ForceSensitivity.light), ("Medium", ForceSensitivity.medium), ("Firm", ForceSensitivity.firm)], id: \.0) { name, value in
                let selected = ForceSensitivity.label(for: settings.forceSensitivity) == name
                Button(name) { withAnimation { settings.forceSensitivity = value } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .fixedSize()
                    .position(x: geo.size.width * (value - ForceSensitivity.range.lowerBound) / span, y: 8)
            }
        }
        .frame(height: 16)
    }
}
