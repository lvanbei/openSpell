import Combine
import OpenSpellCore
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject private var updater = Updater.shared
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
            Divider()
            SettingsRow(symbol: "arrow.down.circle", color: .blue, title: "Software update", subtitle: updateMessage) {
                updateControls
            }
        }
        .padding(20)
        .frame(width: 640)
        .onReceive(poll) { _ in axTrusted = AccessibilityPermission.isTrusted }
    }

    private var updateMessage: String {
        let new = updater.update?.version ?? ""
        return switch updater.status {
        case .idle: "Checks GitHub for a newer version of OpenSpell."
        case .checking: "Checking GitHub…"
        case .upToDate: "You have the latest version."
        case .available: "OpenSpell \(new) is available. You have \(Updater.currentVersion)."
        case .downloading(let p): "Downloading OpenSpell \(new)… \(Int(p * 100)) %"
        case .installing: "Installing OpenSpell \(new). It relaunches when it's done."
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private var updateControls: some View {
        switch updater.status {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .downloading(let p):
            ProgressView(value: p).frame(width: 150)
        default:
            if let update = updater.update {
                HStack {
                    Button("Release Notes") { NSWorkspace.shared.open(update.page) }
                    Button("Download and Install") { updater.install() }
                        .buttonStyle(.borderedProminent)
                }
                .fixedSize()
            } else {
                Button("Check for Updates") { updater.check() }
            }
        }
    }
}
