import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow(symbol: "checklist", color: .blue, title: "Correct selection") {
                    HStack(spacing: 8) {
                        KeyRecorder(combo: $settings.hotKey)
                        Button("Reset") { settings.hotKey = .defaultCombo }
                            .controlSize(.large)
                            .fixedSize()
                            .disabled(settings.hotKey == .defaultCombo)
                    }
                }
            }
            Caption("Select text in any app, then press this shortcut — or press firmly on the trackpad. The corrected text replaces the selection.")
                .padding(.horizontal, 4)
        }
        .padding(20)
        .frame(width: 640)
    }
}
