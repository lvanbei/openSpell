import OpenSpellCore
import OpenSpellUI
import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    KeyboardStatusRow()
                    ModelStatusRow()
                }
                Section {
                    Playground()
                } header: {
                    Text("Try it")
                } footer: {
                    Text("Tap Fix here, or tap in the text, switch to the OpenSpell keyboard with the globe key and tap Fix there.")
                }
            }
            .navigationTitle("OpenSpell")
        }
    }
}

/// Whether the keyboard has run with Full Access (it can only report back with it).
struct KeyboardStatusRow: View {
    @ObservedObject private var settings = SharedSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let seen = settings.keyboardLastSeen {
                Label {
                    VStack(alignment: .leading) {
                        Text("Keyboard ready")
                        Text("Last opened \(seen, format: .relative(presentation: .named))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label {
                    VStack(alignment: .leading) {
                        Text("Keyboard not seen yet")
                        Text("Add it and allow Full Access, then open it once.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "keyboard.badge.ellipsis").foregroundStyle(.orange)
                }
            }
        }
    }
}

struct ModelStatusRow: View {
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        if let model = store.selected, store.isReady(model) {
            Label {
                VStack(alignment: .leading) {
                    Text(model.displayName)
                    Text(provider(of: model)).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label {
                VStack(alignment: .leading) {
                    Text("No model ready")
                    Text(hint).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func provider(of model: ModelEntry) -> String {
        switch model.kind {
        case .apple: "On this iPhone"
        case .gemini: "Google Gemini"
        default: "OpenRouter"
        }
    }

    private var hint: String {
        let apple = AppleIntelligence.status
        if store.selected?.kind == .apple, let reason = apple.message { return reason }
        return apple == .deviceNotEligible ? "Add a Gemini or OpenRouter key in Models."
                                           : "Choose Apple Intelligence or add a key in Models."
    }
}

/// A text field to try OpenSpell in, with the keyboard or with the Fix button below it.
struct Playground: View {
    static let sample = "Hi Sarah,\nI beleive we can definately ship the new featur by tommorow."

    @State private var text = Playground.sample
    @State private var running = false
    @State private var diff: AttributedString?
    @State private var message: String?

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: 120)
        HStack {
            Button(action: fix) {
                if running {
                    ProgressView()
                } else {
                    Label("Fix", systemImage: "text.badge.checkmark").foregroundStyle(.white)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
            Button("Bring the typos back") {
                text = Self.sample
                diff = nil
                message = nil
            }
            .buttonStyle(.borderless)
        }
        if let diff {
            Text(diff).font(.callout)
        }
        if let message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func fix() {
        let original = text
        running = true
        diff = nil
        message = nil
        Task {
            defer { running = false }
            do {
                let correction = try await CorrectionService.correct(original, language: SharedSettings.shared.language)
                guard correction.hasChanges else {
                    message = "No mistakes found"
                    return
                }
                text = correction.corrected
                diff = WordDiff.attributed(from: original, to: correction.corrected)
                if SharedSettings.shared.keepHistory {
                    HistoryStore.shared.add(HistoryItem(original: original, corrected: correction.corrected,
                                                        appName: "OpenSpell", bundleID: nil,
                                                        model: correction.model.displayName, duration: correction.duration))
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
