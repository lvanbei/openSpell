import OpenSpellCore
import OpenSpellUI
import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var hfRepo = ""
    @State private var openRouterSlug = ""
    @State private var geminiModel = ""
    @State private var importing = false
    @State private var importError: String?
    @State private var geminiImporting = false
    @State private var geminiImportError: String?
    @State private var showingOpenRouterBrowser = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "Your models")
                if store.selected == nil, !store.entries.isEmpty {
                    Label("No model selected — click one below. Corrections won't run until you do.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                SettingsCard {
                    if store.entries.isEmpty {
                        Text("No models yet — download or add one below.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { RowDivider() }
                        addedRow(entry)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Caption("Corrections use the model marked “In use”. Click another ready model to switch.")

                SectionHeader(text: "Recommended on-device models").padding(.top, 12)
                SettingsCard {
                    ForEach(Array(ModelStore.recommended.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { RowDivider() }
                        recommendedRow(model)
                    }
                }
                if !ModelStore.isAppleSilicon {
                    Caption("On-device models need an Apple silicon Mac. Use a cloud model instead.")
                        .foregroundStyle(.orange)
                } else {
                    Caption("Free, private, and they work offline. Downloaded once from Hugging Face.")
                }

                SectionHeader(text: "Download from Hugging Face").padding(.top, 12)
                HStack {
                    TextField("mlx-community/Qwen3-4B-4bit", text: $hfRepo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(downloadCustom)
                    Button("Download", action: downloadCustom)
                        .disabled(ModelStore.normalizeRepo(hfRepo).isEmpty || !ModelStore.isAppleSilicon)
                }
                Caption("An MLX repo id. Downloaded, then run entirely on-device.")

                // MARK: Google Gemini
                Divider().padding(.vertical, 10)
                providerHeader("Google Gemini", symbol: "sparkle", color: .purple,
                               subtitle: "Use Gemini directly with a free or paid Google AI Studio key.")

                SectionHeader(text: "Gemini API key").padding(.top, 6)
                APIKeySection(
                    placeholder: "Paste your Gemini API key",
                    initialKey: GeminiClient.apiKey ?? "",
                    caption: "Stored in the macOS Keychain. Saving picks the best current Gemini model for your key.",
                    linkTitle: "Get a Gemini key",
                    link: URL(string: "https://aistudio.google.com/apikey")!,
                    formatWarning: { _ in nil },
                    isSaved: { $0 == (GeminiClient.apiKey ?? "") && store.hasGeminiKey },
                    save: { key in Task { await store.saveGeminiKey(key) } },
                    test: { key in await KeyTester.testGemini(key: key) })

                SectionHeader(text: "Add a Gemini model").padding(.top, 12)
                HStack {
                    TextField(GeminiClient.recommended(from: store.geminiModels)?.id ?? "gemini-flash-latest", text: $geminiModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(importGemini)
                    Menu {
                        if store.geminiModels.isEmpty {
                            Text(store.hasGeminiKey ? "Loading…" : "Save a Gemini key first")
                        }
                        ForEach(store.geminiModels) { m in
                            Button(m.id == GeminiClient.recommended(from: store.geminiModels)?.id ? "\(m.id)  (recommended)" : m.id) {
                                geminiModel = m.id
                                importGemini()
                            }
                        }
                    } label: {
                        Text("Available")
                    }
                    .fixedSize()
                    .help("Models your Gemini key can use")
                    Button(geminiImporting ? "Adding…" : "Add", action: importGemini)
                        .disabled(GeminiClient.normalize(geminiModel).isEmpty || geminiImporting)
                }
                HStack {
                    if let geminiImportError {
                        Caption(geminiImportError).foregroundStyle(.red)
                    } else {
                        Caption("A Gemini model id, or pick one from Available.")
                    }
                    Spacer()
                    Link(destination: URL(string: "https://ai.google.dev/gemini-api/docs/models")!) {
                        Label("Browse models", systemImage: "arrow.up.forward.square")
                    }.font(.system(size: 12))
                }

                // MARK: OpenRouter
                Divider().padding(.vertical, 10)
                providerHeader("OpenRouter", symbol: "point.3.connected.trianglepath.dotted", color: .blue,
                               subtitle: "Hundreds of cloud models (Gemini, Claude, GPT, Llama…) through one key.")

                SectionHeader(text: "OpenRouter API key").padding(.top, 6)
                APIKeySection(
                    placeholder: "sk-or-…",
                    initialKey: OpenRouterClient.apiKey ?? "",
                    caption: "Stored in the macOS Keychain. Needed for OpenRouter models.",
                    linkTitle: "Get an API key",
                    link: URL(string: "https://openrouter.ai/keys")!,
                    formatWarning: { key in
                        key.hasPrefix("sk-or-") ? nil
                            : (key.hasPrefix("AIza") || key.hasPrefix("AQ.")
                               ? "This looks like a Gemini key — paste it in the Gemini section above."
                               : "This doesn't look like an OpenRouter key — they start with “sk-or-v1-”.")
                    },
                    isSaved: { $0 == (OpenRouterClient.apiKey ?? "") && store.hasAPIKey },
                    save: { key in Task { await store.saveAPIKey(key) } },
                    test: { key in await KeyTester.testOpenRouter(key: key) })

                SectionHeader(text: "Choose an OpenRouter model").padding(.top, 12)
                HStack(spacing: 10) {
                    Button {
                        showingOpenRouterBrowser = true
                    } label: {
                        Label("Browse models…", systemImage: "list.bullet.rectangle")
                    }
                    .controlSize(.large)
                    .popover(isPresented: $showingOpenRouterBrowser, arrowEdge: .bottom) {
                        OpenRouterBrowser(onPick: { showingOpenRouterBrowser = false })
                    }
                    if let current = store.selected, current.kind == .cloud {
                        Text("Using ").foregroundStyle(.secondary) + Text(current.displayName).bold()
                        if store.isFreeOpenRouter(current) { Pill(text: "Free") }
                    } else if let free = store.entries.first(where: store.isFreeOpenRouter) {
                        Button("Use \(free.displayName)") { store.select(free) }
                    }
                    Spacer()
                }
                .font(.system(size: 13))
                if store.openRouterFreeTier {
                    Label("Your key is on the free tier — only models marked Free will work.", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                Text("Or enter a model slug").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
                HStack {
                    TextField("google/gemma-4-31b-it:free", text: $openRouterSlug)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(importSlug)
                    Button(importing ? "Importing…" : "Import", action: importSlug)
                        .disabled(openRouterSlug.trimmingCharacters(in: .whitespaces).isEmpty || importing)
                }
                HStack {
                    if let importError {
                        Caption(importError).foregroundStyle(.red)
                    } else {
                        Caption("Any OpenRouter slug. Slugs ending in “:free” cost nothing.")
                    }
                    Spacer()
                    Link(destination: URL(string: "https://openrouter.ai/models")!) {
                        Label("Browse models", systemImage: "arrow.up.forward.square")
                    }.font(.system(size: 12))
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 720)
        .task {
            if store.openRouterCatalog.isEmpty { await store.refreshOpenRouterCatalog() }
            if store.hasGeminiKey, store.geminiModels.isEmpty { await store.refreshGeminiModels() }
        }
    }

    private func providerHeader(_ title: String, symbol: String, color: Color, subtitle: String) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .bold))
                Caption(subtitle)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func recommendedRow(_ model: RecommendedModel) -> some View {
        let entry = store.entry(forRepo: model.repo, kind: .local)
        HStack(spacing: 12) {
            Image(systemName: "internaldrive").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 14, weight: .semibold))
                    Pill(text: model.size)
                }
                Text("\(model.vendor) · \(model.blurb)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let entry {
                statusView(for: entry, compact: true)
            } else {
                Button("Download") { store.downloadLocal(repo: model.repo, displayName: model.name) }
                    .disabled(!ModelStore.isAppleSilicon)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func addedRow(_ entry: ModelEntry) -> some View {
        let isSelected = store.selectedID == entry.id
        let isReady = store.isReady(entry)
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .opacity(isSelected || isReady ? 1 : 0.35)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName).font(.system(size: 14, weight: .semibold))
                    badge(for: entry.kind)
                    if store.isFreeOpenRouter(entry) { Pill(text: "Free") }
                    if isSelected { Pill(text: "In use", color: .accentColor) }
                }
                Text(entry.repo).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            statusView(for: entry, compact: false)
            Button(role: .destructive) { store.remove(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(entry.kind == .local ? "Remove (deletes downloaded weights)" : "Remove")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .onTapGesture { if isReady { store.select(entry) } }
        .help(isReady && !isSelected ? "Click to use this model for corrections" : "")
    }

    @ViewBuilder
    private func badge(for kind: ModelEntry.Kind) -> some View {
        switch kind {
        case .local: Pill(text: "local", color: .green)
        case .cloud: Pill(text: "OpenRouter", color: .blue)
        case .gemini: Pill(text: "Gemini API", color: .purple)
        }
    }

    @ViewBuilder
    private func statusView(for entry: ModelEntry, compact: Bool) -> some View {
        switch entry.kind {
        case .cloud, .gemini:
            if !store.isReady(entry) {
                Label(entry.kind == .gemini ? "Needs Gemini key" : "Needs API key", systemImage: "key")
                    .foregroundStyle(.orange).font(.system(size: 12))
            }
        case .local:
            switch store.state(of: entry) {
            case .downloading(let p):
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: p).frame(width: 150)
                        Text("\(Int(p * 100)) %").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { store.cancelDownload(entry) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel download")
                }
            case .ready:
                if compact, store.selectedID == entry.id {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor).font(.system(size: 13, weight: .medium))
                } else if compact {
                    Button("Use") { store.select(entry) }
                }
            case .notDownloaded:
                Button(compact ? "Download" : "Resume") { store.downloadLocal(repo: entry.repo) }
            case .failed(let message):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                    Button("Retry") { store.downloadLocal(repo: entry.repo) }
                }
            }
        }
    }

    // MARK: Actions

    private func downloadCustom() {
        let repo = ModelStore.normalizeRepo(hfRepo)
        guard !repo.isEmpty else { return }
        store.downloadLocal(repo: repo)
        hfRepo = ""
    }

    private func importSlug() {
        importError = nil
        importing = true
        let slug = openRouterSlug
        Task {
            do {
                try await store.importOpenRouter(slug: slug)
                openRouterSlug = ""
            } catch {
                importError = error.localizedDescription
            }
            importing = false
        }
    }

    private func importGemini() {
        geminiImportError = nil
        geminiImporting = true
        let model = geminiModel
        Task {
            do {
                try await store.importGemini(model: model)
                geminiModel = ""
            } catch {
                geminiImportError = error.localizedDescription
            }
            geminiImporting = false
        }
    }
}

// MARK: - Reusable API key editor

/// Secure field + paste + Save + Test, with inline results. Used for every cloud provider.
struct APIKeySection: View {
    let placeholder: String
    let caption: String
    let linkTitle: String
    let link: URL
    let formatWarning: (String) -> String?
    let isSaved: (String) -> Bool
    let save: (String) -> Void
    let test: (String) async -> KeyTestState

    @State private var key: String
    @State private var justSaved = false
    @State private var state: KeyTestState = .idle

    init(placeholder: String, initialKey: String, caption: String, linkTitle: String, link: URL,
         formatWarning: @escaping (String) -> String?, isSaved: @escaping (String) -> Bool,
         save: @escaping (String) -> Void, test: @escaping (String) async -> KeyTestState) {
        self.placeholder = placeholder
        self.caption = caption
        self.linkTitle = linkTitle
        self.link = link
        self.formatWarning = formatWarning
        self.isSaved = isSaved
        self.save = save
        self.test = test
        _key = State(initialValue: initialKey)
    }

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField(placeholder, text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(doSave)
                    .onChange(of: key) { if state != .running { state = .idle } }
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        key = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Paste from clipboard")
                Button(justSaved ? "Saved ✓" : "Save", action: doSave)
                Button(action: runTest) {
                    if state == .running {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Testing…") }
                    } else {
                        Label("Test", systemImage: "checkmark.shield")
                    }
                }
                .disabled(trimmed.isEmpty || state == .running)
                .help("Check the key and run a sample correction")
            }
            result
            if !trimmed.isEmpty, let warning = formatWarning(trimmed) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            HStack {
                Caption(caption)
                Spacer()
                Link(destination: link) {
                    Label(linkTitle, systemImage: "arrow.up.forward.square")
                }.font(.system(size: 12))
            }
        }
    }

    private func doSave() {
        save(trimmed)
        key = trimmed
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justSaved = false }
    }

    private func runTest() {
        state = .running
        let k = trimmed
        Task { state = await test(k) }
    }

    @ViewBuilder
    private var result: some View {
        switch state {
        case .idle, .running:
            EmptyView()
        case .success(let info, let model, let sample, let seconds):
            VStack(alignment: .leading, spacing: 4) {
                Label("Key works\(info.isEmpty ? "" : " — \(info)")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(model) · \(String(format: "%.1f", seconds)) s:  ")
                    .foregroundStyle(.secondary)
                + Text(WordDiff.attributed(from: KeyTester.sampleText, to: sample))
                if !isSaved(trimmed) {
                    Text("Not saved yet — click Save to use this key.").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .keyOnly(let info, let modelError):
            VStack(alignment: .leading, spacing: 4) {
                Label("Key is valid\(info.isEmpty ? "" : " — \(info)")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Sample correction failed: \(modelError)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - OpenRouter model browser

/// Searchable list of OpenRouter's text models with a "Free only" filter.
struct OpenRouterBrowser: View {
    var onPick: () -> Void
    @ObservedObject private var store = ModelStore.shared
    @State private var query = ""
    @State private var freeOnly = true
    @State private var loading = false

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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search models", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Free only", isOn: $freeOnly).toggleStyle(.checkbox)
            }
            if store.openRouterFreeTier && !freeOnly {
                Label("Your key is on the free tier — paid models will fail.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if loading && store.openRouterCatalog.isEmpty {
                ProgressView("Loading catalogue…").frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(models) { m in
                    Button {
                        store.addOpenRouter(m)
                        onPick()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(m.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    if m.id == recommended { Pill(text: "Recommended", color: .accentColor) }
                                }
                                Text(m.id).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(m.contextLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                            if m.isFree {
                                Pill(text: "Free")
                            } else {
                                Text(m.priceLabel).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if store.selected?.kind == .cloud, store.selected?.repo == m.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .overlay {
                    if models.isEmpty { Text("No matching models").foregroundStyle(.secondary) }
                }
            }
            Caption("\(models.count) models · Free models are rate-limited and may be slower. Prices are input / output per million tokens.")
        }
        .padding(14)
        .frame(width: 520, height: 460)
        .task {
            if store.openRouterCatalog.isEmpty {
                loading = true
                await store.refreshOpenRouterCatalog()
                loading = false
            }
        }
    }
}
