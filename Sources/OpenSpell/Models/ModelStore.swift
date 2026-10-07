import AppKit
import Combine

struct ModelEntry: Codable, Identifiable, Equatable, Hashable {
    /// `cloud` = OpenRouter (raw value kept for saved settings), `gemini` = Google Gemini API directly.
    enum Kind: String, Codable { case local, cloud, gemini }
    var kind: Kind
    /// Hugging Face repo id (local), OpenRouter slug (cloud) or Gemini model id (gemini).
    var repo: String
    var displayName: String

    var id: String { "\(kind.rawValue):\(repo)" }
}

struct RecommendedModel: Identifiable {
    let name: String
    let repo: String
    let size: String
    let vendor: String
    let blurb: String
    var id: String { repo }
}

enum LocalModelState: Equatable {
    case notDownloaded
    case downloading(Double)
    case ready
    case failed(String)
}

enum ModelError: LocalizedError {
    case noModel
    case notReady(String)
    case appleSiliconRequired

    var errorDescription: String? {
        switch self {
        case .noModel: "No language model selected. Pick one in Settings › Models."
        case .notReady(let name): "“\(name)” isn't downloaded yet."
        case .appleSiliconRequired: "On-device models need an Apple silicon Mac."
        }
    }
}

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    static let recommended: [RecommendedModel] = [
        .init(name: "Qwen3 4B Instruct", repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", size: "2.3 GB",
              vendor: "Alibaba", blurb: "Quick and sharp — the best balance on any Apple silicon Mac."),
        .init(name: "Gemma 3n E4B", repo: "mlx-community/gemma-3n-E4B-it-lm-4bit", size: "3.9 GB",
              vendor: "Google", blurb: "Trained on 140+ languages — great with nuance and idioms."),
        .init(name: "Mistral 7B Instruct", repo: "mlx-community/Mistral-7B-Instruct-v0.3-4bit", size: "4.1 GB",
              vendor: "Mistral AI", blurb: "Made in France — superb French. Best with 16 GB of RAM."),
    ]

    static let defaultCloud = ModelEntry(kind: .cloud, repo: "google/gemini-2.5-flash", displayName: "gemini-2.5-flash")
    /// Used only when the model list can't be fetched; normally the newest Flash model is discovered from the key.
    static let defaultGemini = ModelEntry(kind: .gemini, repo: GeminiClient.fallbackModel, displayName: GeminiClient.fallbackModel)

    @Published private(set) var entries: [ModelEntry] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var localStates: [String: LocalModelState] = [:]
    @Published private(set) var hasAPIKey: Bool = OpenRouterClient.apiKey?.isEmpty == false
    @Published private(set) var hasGeminiKey: Bool = GeminiClient.apiKey?.isEmpty == false
    /// OpenRouter's public catalogue (text models), fetched on demand.
    @Published private(set) var openRouterCatalog: [OpenRouterClient.CatalogModel] = []
    /// Whether the saved OpenRouter key is on the free tier (no credits) — then only free models work.
    @Published private(set) var openRouterFreeTier: Bool = UserDefaults.standard.bool(forKey: "openrouter.freeTier")
    /// Models the saved Gemini key can use (best default first).
    @Published private(set) var geminiModels: [GeminiClient.ModelInfo] = []

    private var downloaders: [String: HFDownloader] = [:]
    private let defaults = UserDefaults.standard

    nonisolated static var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("arm64")
    }

    nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "OpenSpell/Models", directoryHint: .isDirectory)
    }

    nonisolated static func directory(for repo: String) -> URL {
        modelsDirectory.appending(path: repo.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
    }

    nonisolated private static func completeMarker(for repo: String) -> URL {
        directory(for: repo).appending(path: ".complete")
    }

    // MARK: Lifecycle

    func bootstrap() {
        if let data = defaults.data(forKey: "models.entries"),
           let saved = try? JSONDecoder().decode([ModelEntry].self, from: data) {
            entries = saved
            selectedID = defaults.string(forKey: "models.selected")
        } else {
            entries = [Self.defaultCloud]
            selectedID = Self.defaultCloud.id
        }
        // Learn whether the OpenRouter key is free tier (switches paid OpenRouter picks to a free model).
        if hasAPIKey { Task { await refreshOpenRouterTier() } }
        for entry in entries where entry.kind == .local {
            localStates[entry.id] = FileManager.default.fileExists(atPath: Self.completeMarker(for: entry.repo).path)
                ? .ready : .notDownloaded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "models.entries") }
        defaults.set(selectedID, forKey: "models.selected")
    }

    // MARK: Queries

    var selected: ModelEntry? { sessionOverride ?? entries.first { $0.id == selectedID } }

    /// Developer aid: use a downloaded local model for this process only (nothing persisted).
    private var sessionOverride: ModelEntry?
    func useForThisSessionOnly(localRepo repo: String) {
        let entry = ModelEntry(kind: .local, repo: repo, displayName: (repo as NSString).lastPathComponent)
        localStates[entry.id] = FileManager.default.fileExists(atPath: Self.completeMarker(for: repo).path) ? .ready : .notDownloaded
        sessionOverride = entry
    }

    func entry(forRepo repo: String, kind: ModelEntry.Kind) -> ModelEntry? {
        entries.first { $0.kind == kind && $0.repo == repo }
    }

    func state(of entry: ModelEntry) -> LocalModelState {
        localStates[entry.id] ?? .notDownloaded
    }

    func isReady(_ entry: ModelEntry) -> Bool {
        switch entry.kind {
        case .local: state(of: entry) == .ready
        case .cloud: hasAPIKey
        case .gemini: hasGeminiKey
        }
    }

    // MARK: Mutations

    func select(_ entry: ModelEntry) {
        selectedID = entry.id
        persist()
        if entry.kind == .local, isReady(entry) {
            // Warm the model up in the background so the first correction is fast.
            let dir = Self.directory(for: entry.repo)
            let eos = Self.extraEOSTokens(for: entry.repo)
            Task.detached(priority: .utility) { try? await LocalLLM.shared.preload(directory: dir, extraEOSTokens: eos) }
        } else {
            Task.detached { await LocalLLM.shared.unload() }
        }
    }

    /// Saves the OpenRouter key. On a free-tier key, makes sure a free model is added and used.
    func saveAPIKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, for: OpenRouterClient.keychainAccount)
        hasAPIKey = OpenRouterClient.apiKey?.isEmpty == false
        guard hasAPIKey else { return }

        if let info = try? await OpenRouterClient.checkKey(trimmed) {
            openRouterFreeTier = info.isFreeTier
            defaults.set(info.isFreeTier, forKey: "openrouter.freeTier")
        }
        if openRouterFreeTier { await ensureFreeOpenRouterModel() }
    }

    /// Re-checks whether the saved OpenRouter key is free tier; on a free key, moves off paid models.
    func refreshOpenRouterTier(key: String? = nil) async {
        guard let key = key ?? OpenRouterClient.apiKey, !key.isEmpty,
              let info = try? await OpenRouterClient.checkKey(key) else { return }
        openRouterFreeTier = info.isFreeTier
        defaults.set(info.isFreeTier, forKey: "openrouter.freeTier")
        if info.isFreeTier, key == OpenRouterClient.apiKey { await ensureFreeOpenRouterModel() }
    }

    func isFreeOpenRouter(_ entry: ModelEntry) -> Bool {
        guard entry.kind == .cloud else { return false }
        if OpenRouterClient.isFreeSlug(entry.repo) { return true }
        return openRouterCatalog.first { $0.id == entry.repo }?.isFree ?? false
    }

    func refreshOpenRouterCatalog() async {
        if let catalog = try? await OpenRouterClient.catalog(), !catalog.isEmpty { openRouterCatalog = catalog }
    }

    /// A free-tier key can't run paid OpenRouter models, so a paid pick is swapped for a free model
    /// (never the openrouter/free router). Does nothing unless an OpenRouter model is selected.
    func ensureFreeOpenRouterModel() async {
        guard selected?.kind == .cloud else { return }
        if openRouterCatalog.isEmpty { await refreshOpenRouterCatalog() }
        guard let current = selected, current.kind == .cloud, !isFreeOpenRouter(current) else { return }
        if let free = entries.first(where: { isFreeOpenRouter($0) && $0.repo != "openrouter/free" }) {
            select(free)
        } else if let pick = OpenRouterClient.recommendedFree(from: openRouterCatalog) {
            addOpenRouter(pick)
        }
    }

    /// Switches to an OpenRouter model (the first one added, else the default) unless one is in use.
    func useOpenRouter() async {
        if selected?.kind != .cloud {
            let cloud = entries.first { $0.kind == .cloud } ?? Self.defaultCloud
            if !entries.contains(cloud) { entries.append(cloud) }
            select(cloud)
        }
        if openRouterFreeTier { await ensureFreeOpenRouterModel() }
    }

    /// Adds a model picked from the catalogue browser and selects it.
    func addOpenRouter(_ model: OpenRouterClient.CatalogModel) {
        let entry = self.entry(forRepo: model.id, kind: .cloud) ?? ModelEntry(kind: .cloud, repo: model.id, displayName: model.name)
        if !entries.contains(entry) { entries.append(entry) }
        select(entry)
    }

    /// Saves the Gemini key and makes sure at least one (current) Gemini model is available.
    func saveGeminiKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, for: GeminiClient.keychainAccount)
        hasGeminiKey = GeminiClient.apiKey?.isEmpty == false
        guard hasGeminiKey else { geminiModels = []; return }

        await refreshGeminiModels()
        if !entries.contains(where: { $0.kind == .gemini }) {
            let best = GeminiClient.recommended(from: geminiModels)?.id ?? GeminiClient.fallbackModel
            entries.append(ModelEntry(kind: .gemini, repo: best, displayName: best))
            persist()
        }
        // If the current model can't run, switch to Gemini.
        if selected.map(isReady) != true, let gemini = entries.first(where: { $0.kind == .gemini }) {
            select(gemini)
        }
    }

    /// Fetches the models the saved key can use. Silent on failure (list stays as it was).
    func refreshGeminiModels(key: String? = nil) async {
        guard let key = key ?? GeminiClient.apiKey, !key.isEmpty else { return }
        if let models = try? await GeminiClient.listModels(apiKey: key), !models.isEmpty {
            geminiModels = models
        }
    }

    /// Best replacement for a retired Gemini model: Google's suggestion, else the newest Flash for this key.
    func replacementGeminiModel(for retired: String, suggestion: String?, key: String? = nil) async -> String? {
        if let suggestion, suggestion != retired { return suggestion }
        await refreshGeminiModels(key: key)
        return GeminiClient.recommended(from: geminiModels.filter { $0.id != retired })?.id
    }

    /// Swaps a retired Gemini model for a new one in place (keeps it selected).
    func replaceGemini(_ entry: ModelEntry, with model: String) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let wasSelected = selectedID == entry.id
        if let existing = entries.first(where: { $0.kind == .gemini && $0.repo == model }) {
            entries.remove(at: i)
            if wasSelected { selectedID = existing.id }
        } else {
            entries[i] = ModelEntry(kind: .gemini, repo: model, displayName: model)
            if wasSelected { selectedID = entries[i].id }
        }
        persist()
        NSLog("OpenSpell: Gemini model \(entry.repo) is unavailable, switched to \(model)")
    }

    /// Adds a Gemini model by id (e.g. "gemini-2.5-flash-lite"), validating it when a key is available.
    func importGemini(model raw: String) async throws {
        let model = GeminiClient.normalize(raw)
        guard !model.isEmpty else { return }
        if let existing = entry(forRepo: model, kind: .gemini) { select(existing); return }
        if let key = GeminiClient.apiKey, !key.isEmpty {
            do {
                if try await GeminiClient.lookup(model: model, apiKey: key) == nil {
                    throw NSError(domain: "OpenSpell", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "“\(model)” isn't a Gemini model that can generate text."])
                }
            } catch let error as URLError {
                NSLog("OpenSpell: couldn't validate Gemini model (\(error)); adding anyway")
            }
        }
        let entry = ModelEntry(kind: .gemini, repo: model, displayName: model)
        entries.append(entry)
        select(entry)
    }

    /// Adds (or resumes) a local model and starts downloading it.
    func downloadLocal(repo rawRepo: String, displayName: String? = nil) {
        let repo = Self.normalizeRepo(rawRepo)
        guard !repo.isEmpty else { return }
        let entry = entry(forRepo: repo, kind: .local)
            ?? ModelEntry(kind: .local, repo: repo, displayName: displayName ?? (repo as NSString).lastPathComponent)
        if !entries.contains(entry) {
            entries.append(entry)
            persist()
        }
        if case .downloading = state(of: entry) { return }
        if state(of: entry) == .ready { return }

        let downloader = HFDownloader()
        downloaders[entry.id] = downloader
        localStates[entry.id] = .downloading(0)
        let id = entry.id
        let dir = Self.directory(for: repo)

        Task {
            do {
                try await downloader.download(repo: repo, to: dir) { fraction in
                    Task { @MainActor in
                        if case .downloading = ModelStore.shared.localStates[id] {
                            ModelStore.shared.localStates[id] = .downloading(fraction)
                        }
                    }
                }
                FileManager.default.createFile(atPath: Self.completeMarker(for: repo).path, contents: Data())
                localStates[id] = .ready
                // First usable model becomes the active one if nothing usable is selected yet.
                if selected.map(isReady) != true, let e = entries.first(where: { $0.id == id }) { select(e) }
            } catch is CancellationError {
                localStates[id] = .notDownloaded
            } catch let error as URLError where error.code == .cancelled {
                localStates[id] = .notDownloaded
            } catch {
                localStates[id] = .failed(error.localizedDescription)
            }
            downloaders[id] = nil
        }
    }

    func cancelDownload(_ entry: ModelEntry) {
        downloaders[entry.id]?.cancel()
    }

    func importOpenRouter(slug rawSlug: String) async throws {
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://openrouter.ai/", with: "")
        guard !slug.isEmpty else { return }
        if let existing = entry(forRepo: slug, kind: .cloud) { select(existing); return }

        var name = (slug as NSString).lastPathComponent
        do {
            guard let info = try await OpenRouterClient.lookup(slug: slug) else {
                throw NSError(domain: "OpenSpell", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "“\(slug)” isn't an OpenRouter model slug."])
            }
            name = (info.id as NSString).lastPathComponent
        } catch let error as URLError {
            NSLog("OpenSpell: couldn't validate slug (\(error)); adding anyway")
        }
        let entry = ModelEntry(kind: .cloud, repo: slug, displayName: name)
        entries.append(entry)
        select(entry)
    }

    func remove(_ entry: ModelEntry) {
        if entry.kind == .local {
            downloaders[entry.id]?.cancel()
            try? FileManager.default.removeItem(at: Self.directory(for: entry.repo))
            localStates[entry.id] = nil
            Task.detached { await LocalLLM.shared.unload() }
        }
        entries.removeAll { $0.id == entry.id }
        if selectedID == entry.id { selectedID = nil }
        persist()
    }

    // MARK: Inference

    func complete(system: String, user: String) async throws -> String {
        guard let entry = selected else { throw ModelError.noModel }
        switch entry.kind {
        case .cloud:
            return try await OpenRouterClient.complete(model: entry.repo, system: system, user: user)
        case .gemini:
            do {
                return try await GeminiClient.complete(model: entry.repo, system: system, user: user)
            } catch GeminiError.modelUnavailable(let retired, let suggestion, _) {
                // Google retires models; heal automatically and retry once.
                guard let replacement = await replacementGeminiModel(for: retired, suggestion: suggestion) else { throw ModelError.noModel }
                replaceGemini(entry, with: replacement)
                return try await GeminiClient.complete(model: replacement, system: system, user: user)
            }
        case .local:
            guard Self.isAppleSilicon else { throw ModelError.appleSiliconRequired }
            guard isReady(entry) else { throw ModelError.notReady(entry.displayName) }
            return try await LocalLLM.shared.complete(
                directory: Self.directory(for: entry.repo),
                extraEOSTokens: Self.extraEOSTokens(for: entry.repo),
                system: system, user: user)
        }
    }

    // MARK: Helpers

    nonisolated static func extraEOSTokens(for repo: String) -> Set<String> {
        let r = repo.lowercased()
        if r.contains("gemma") { return ["<end_of_turn>"] }
        if r.contains("qwen") { return ["<|im_end|>"] }
        return []
    }

    nonisolated static func normalizeRepo(_ s: String) -> String {
        var repo = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] where repo.hasPrefix(prefix) {
            repo = String(repo.dropFirst(prefix.count))
        }
        let parts = repo.split(separator: "/")
        guard parts.count >= 2 else { return "" }
        return parts.prefix(2).joined(separator: "/")
    }
}
