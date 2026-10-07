import Foundation

public enum KeyTestState: Equatable, Sendable {
    case idle
    case running
    case success(key: String, model: String, sample: String, seconds: Double)
    case keyOnly(key: String, modelError: String)
    case failure(String)
}

/// Checks an API key, then runs a sample correction with it.
@MainActor
public enum KeyTester {
    public static let sampleText = "I beleive we can definately ship it by tommorow."

    private static func sampleCorrection(_ run: () async throws -> String) async -> Result<(String, Double), Error> {
        let start = Date()
        do {
            let raw = try await run()
            return .success((CorrectionPrompt.postProcess(raw, original: sampleText), Date().timeIntervalSince(start)))
        } catch {
            return .failure(error)
        }
    }

    /// Validates the key, then runs a sample correction. Free-tier keys are tested with a free model.
    public static func testOpenRouter(key: String) async -> KeyTestState {
        let info: OpenRouterClient.KeyInfo
        do { info = try await OpenRouterClient.checkKey(key) } catch { return .failure(error.localizedDescription) }

        let store = ModelStore.shared
        if store.openRouterCatalog.isEmpty { await store.refreshOpenRouterCatalog() }
        if key == OpenRouterClient.apiKey { await store.refreshOpenRouterTier(key: key) }

        let entry: ModelEntry? = (store.selected?.kind == .cloud ? store.selected : nil)
            ?? store.entries.first { $0.kind == .cloud }
        var slug = entry?.repo
        var name = entry?.displayName
        var summary = info.summary

        // A free key can't run paid models — test with a free one instead (and say so).
        if info.isFreeTier, entry.map(store.isFreeOpenRouter) != true {
            let free = store.entries.first(where: store.isFreeOpenRouter)
            let pick = free.map { ($0.repo, $0.displayName) }
                ?? OpenRouterClient.recommendedFree(from: store.openRouterCatalog).map { ($0.id, $0.name) }
            if let pick {
                slug = pick.0
                name = pick.1
                summary += " · tested with a free model" + (free == nil ? " (Save adds it)" : "")
            }
        }
        guard let slug, let name else { return .keyOnly(key: summary, modelError: "No OpenRouter model to test — use Browse models.") }

        let result = await sampleCorrection {
            try await OpenRouterClient.complete(model: slug, system: CorrectionPrompt.system(language: .auto),
                                                user: CorrectionPrompt.user(sampleText), apiKey: key)
        }
        switch result {
        case .success(let (fixed, seconds)):
            return .success(key: summary, model: name, sample: fixed, seconds: seconds)
        case .failure(let error):
            return .keyOnly(key: summary, modelError: error.localizedDescription)
        }
    }

    /// Validates the key, then runs a sample correction. Retired models are replaced automatically.
    public static func testGemini(key: String) async -> KeyTestState {
        do { try await GeminiClient.checkKey(key) } catch { return .failure(error.localizedDescription) }

        let store = ModelStore.shared
        await store.refreshGeminiModels(key: key)

        // Model to test: the selected/first Gemini entry, else what we'd pick for a new user.
        let entry: ModelEntry? = (store.selected?.kind == .gemini ? store.selected : nil)
            ?? store.entries.first { $0.kind == .gemini }
        var model = entry?.repo ?? GeminiClient.recommended(from: store.geminiModels)?.id ?? GeminiClient.fallbackModel
        var note = ""

        func run(_ m: String) async -> Result<(String, Double), Error> {
            await sampleCorrection {
                try await GeminiClient.complete(model: m, system: CorrectionPrompt.system(language: .auto),
                                                user: CorrectionPrompt.user(sampleText), apiKey: key)
            }
        }

        var result = await run(model)
        if case .failure(GeminiError.modelUnavailable(let retired, let suggestion, _)) = result,
           let replacement = await store.replacementGeminiModel(for: retired, suggestion: suggestion, key: key) {
            if let entry { store.replaceGemini(entry, with: replacement) }
            note = "\(retired) was retired, switched to \(replacement)"
            model = replacement
            result = await run(replacement)
        }

        switch result {
        case .success(let (fixed, seconds)):
            return .success(key: note, model: model, sample: fixed, seconds: seconds)
        case .failure(let error):
            return .keyOnly(key: note, modelError: "\(model): \(error.localizedDescription)")
        }
    }
}
