import Combine
import SwiftUI

struct AboutSettingsView: View {
    @State private var axTrusted = AccessibilityPermission.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        SettingsCard {
            HStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenSpell").font(.system(size: 24, weight: .bold))
                    Text(version).foregroundStyle(.secondary)
                    if axTrusted {
                        Label("Accessibility allowed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Accessibility not allowed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button("How it works") { WindowManager.shared.showSetupAssistant() }
                    Button("Accessibility settings") { AccessibilityPermission.openSystemSettings() }
                    Button("Open models folder") {
                        try? FileManager.default.createDirectory(at: ModelStore.modelsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ModelStore.modelsDirectory)
                    }
                    Button("History") { WindowManager.shared.showHistory() }
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .padding(20)
        .frame(width: 640)
        .onReceive(poll) { _ in axTrusted = AccessibilityPermission.isTrusted }
    }
}
