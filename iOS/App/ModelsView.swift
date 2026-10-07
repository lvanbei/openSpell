import OpenSpellCore
import OpenSpellUI
import SwiftUI

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared

    private var entries: [ModelEntry] { store.entries.filter { $0.kind != .local } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if entries.isEmpty {
                        Text("No models yet. Add a key below.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { ModelRow(entry: $0) }
                        .onDelete { offsets in offsets.map { entries[$0] }.forEach(store.remove) }
                } header: {
                    Text("Your models")
                } footer: {
                    Text("Fixes use the checked model. Tap another ready model to switch.")
                }

                Section {
                    KeyField(provider: .gemini)
                    if !store.geminiModels.isEmpty {
                        Menu("Add a Gemini model") {
                            ForEach(store.geminiModels) { model in
                                Button(model.id) { Task { try? await store.importGemini(model: model.id) } }
                            }
                        }
                    }
                } header: {
                    Text("Google Gemini")
                } footer: {
                    Text("Google AI Studio has a free tier. When you tap Fix, the text is sent to Google.")
                }

                Section {
                    KeyField(provider: .openRouter)
                    NavigationLink("Browse OpenRouter models") { OpenRouterBrowser() }
                } header: {
                    Text("OpenRouter")
                } footer: {
                    Text(store.openRouterFreeTier
                         ? "Your key is on the free tier, so only models marked Free work. When you tap Fix, the text is sent to OpenRouter."
                         : "Models ending in “:free” cost nothing. When you tap Fix, the text is sent to OpenRouter.")
                }
            }
            .navigationTitle("Models")
            .task {
                if store.hasGeminiKey, store.geminiModels.isEmpty { await store.refreshGeminiModels() }
            }
        }
    }
}

private struct ModelRow: View {
    let entry: ModelEntry
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        let selected = store.selectedID == entry.id
        let ready = store.isReady(entry)
        Button {
            if ready { store.select(entry) }
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading) {
                    Text(entry.displayName).foregroundStyle(.primary)
                    Text(entry.kind == .gemini ? "Google Gemini" : (store.isFreeOpenRouter(entry) ? "OpenRouter · Free" : "OpenRouter"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if !ready {
                    Label("Needs key", systemImage: "key").font(.footnote).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Secure field with Save and Test for one provider's API key.
struct KeyField: View {
    enum Provider { case gemini, openRouter }

    let provider: Provider
    @ObservedObject private var store = ModelStore.shared
    @State private var key: String
    @State private var state = KeyTestState.idle
    @State private var justSaved = false

    init(provider: Provider) {
        self.provider = provider
        _key = State(initialValue: (provider == .gemini ? GeminiClient.apiKey : OpenRouterClient.apiKey) ?? "")
    }

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SecureField(provider == .gemini ? "Gemini API key" : "OpenRouter key (sk-or-…)", text: $key)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: key) { if state != .running { state = .idle } }
        HStack {
            Button(justSaved ? "Saved" : "Save", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
            Button("Test", action: test)
                .buttonStyle(.bordered)
                .disabled(trimmed.isEmpty || state == .running)
            if state == .running { ProgressView().padding(.leading, 4) }
            Spacer()
            Link("Get a key", destination: URL(string: provider == .gemini ? "https://aistudio.google.com/apikey"
                                                                          : "https://openrouter.ai/keys")!)
                .font(.footnote)
        }
        result
    }

    @ViewBuilder
    private var result: some View {
        switch state {
        case .idle, .running:
            EmptyView()
        case .success(let info, let model, let sample, let seconds):
            VStack(alignment: .leading, spacing: 4) {
                Label("Key works\(info.isEmpty ? "" : " · \(info)")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(model) · \(String(format: "%.1f", seconds)) s").foregroundStyle(.secondary)
                Text(WordDiff.attributed(from: KeyTester.sampleText, to: sample))
            }
            .font(.footnote)
        case .keyOnly(let info, let modelError):
            VStack(alignment: .leading, spacing: 4) {
                Label("Key is valid\(info.isEmpty ? "" : " · \(info)")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Sample correction failed: \(modelError)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.footnote)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red)
        }
    }

    private func save() {
        let key = trimmed
        Task {
            if provider == .gemini {
                await store.saveGeminiKey(key)
            } else {
                await store.saveAPIKey(key)
                if store.selected.map(store.isReady) != true { await store.useOpenRouter() }
            }
            justSaved = true
            try? await Task.sleep(for: .seconds(1.5))
            justSaved = false
        }
    }

    private func test() {
        let key = trimmed
        state = .running
        Task {
            state = provider == .gemini ? await KeyTester.testGemini(key: key) : await KeyTester.testOpenRouter(key: key)
        }
    }
}

/// OpenRouter's text models, searchable, free ones first.
struct OpenRouterBrowser: View {
    @ObservedObject private var store = ModelStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var freeOnly = true

    private var models: [OpenRouterClient.CatalogModel] {
        let recommended = OpenRouterClient.recommendedFree(from: store.openRouterCatalog)?.id
        return store.openRouterCatalog
            .filter { !freeOnly || $0.isFree }
            .filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                if (a.id == recommended) != (b.id == recommended) { return a.id == recommended }
                if a.isFree != b.isFree { return a.isFree }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        let recommended = OpenRouterClient.recommendedFree(from: store.openRouterCatalog)?.id
        List {
            Toggle("Free models only", isOn: $freeOnly)
            ForEach(models) { model in
                Button {
                    store.addOpenRouter(model)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name).foregroundStyle(.primary)
                            Text(model.id + (model.id == recommended ? " · Recommended" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.priceLabel).font(.caption).foregroundStyle(model.isFree ? .green : .secondary)
                        if store.selected?.kind == .cloud, store.selected?.repo == model.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .searchable(text: $query)
        .overlay {
            if store.openRouterCatalog.isEmpty { ProgressView("Loading models…") }
        }
        .navigationTitle("OpenRouter models")
        .task {
            if store.openRouterCatalog.isEmpty { await store.refreshOpenRouterCatalog() }
        }
    }
}
