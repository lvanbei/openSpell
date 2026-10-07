import OpenSpellCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SharedSettings.shared
    @Environment(\.openURL) private var openURL
    #if DEBUG
    @AppStorage("debug.fakeCorrections", store: SharedStorage.defaults) private var fakeCorrections = false
    #endif

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $settings.language) {
                        ForEach(CorrectionLanguage.allCases) { Text("\($0.flag)  \($0.name)").tag($0) }
                    }
                } footer: {
                    Text("A hint for the model. Auto-detect keeps whatever language you write in.")
                }

                Section {
                    Toggle("Keep history", isOn: $settings.keepHistory)
                } footer: {
                    Text("Your last \(HistoryStore.limit) corrections stay on this iPhone.")
                }

                Section("Keyboard") {
                    KeyboardStatusRow()
                    Button("Open OpenSpell in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Button("Show the setup again") { settings.hasCompletedSetup = false }
                }

                Section("Privacy") {
                    Text(Self.privacy).font(.footnote)
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link("OpenSpell on GitHub", destination: URL(string: "https://github.com/lvanbei/openSpell")!)
                }

                #if DEBUG
                Section {
                    Toggle("Fake corrections", isOn: $fakeCorrections)
                } header: {
                    Text("Debug")
                } footer: {
                    Text("The keyboard fixes a fixed list of typos without a model, to test writing back into other apps.")
                }
                #endif
            }
            .navigationTitle("Settings")
        }
    }

    static let privacy = """
    Text leaves your iPhone only when you tap Fix, and only goes to the model provider you chose. \
    With Apple Intelligence, it never leaves your iPhone. \
    OpenSpell doesn't log or keep what you type, except the corrections in History when it's on. \
    API keys are stored in the iOS Keychain.
    """
}
