import Foundation

/// Why a correction can't start.
public enum CorrectionError: LocalizedError, Equatable {
    case tooLong
    case modelNotReady(ModelEntry.Kind?)

    public var errorDescription: String? {
        switch self {
        case .tooLong: "Selection is too long (max \(CorrectionService.maxCharacters) characters)"
        case .modelNotReady(.cloud): "Add your OpenRouter API key"
        case .modelNotReady(.gemini): "Add your Gemini API key"
        case .modelNotReady: "Choose a language model first"
        }
    }
}

public struct Correction: Sendable {
    public let original: String
    public let corrected: String
    public let model: ModelEntry
    public let duration: TimeInterval

    public var hasChanges: Bool { corrected != original }
}

/// The platform-neutral half of a correction: limits, prompt, model call and clean-up.
@MainActor
public enum CorrectionService {
    public nonisolated static let maxCharacters = 12_000

    /// The model that would correct `text`, or why a correction can't run.
    public static func readyModel(for text: String) throws -> ModelEntry {
        guard text.count <= maxCharacters else { throw CorrectionError.tooLong }
        let store = ModelStore.shared
        guard let model = store.selected, store.isReady(model) else {
            throw CorrectionError.modelNotReady(store.selected?.kind)
        }
        return model
    }

    public static func correct(_ text: String, language: CorrectionLanguage) async throws -> Correction {
        let model = try readyModel(for: text)
        let started = Date()
        let raw = try await ModelStore.shared.complete(system: CorrectionPrompt.system(language: language),
                                                       user: CorrectionPrompt.user(text))
        try Task.checkCancellation()
        return Correction(original: text, corrected: CorrectionPrompt.postProcess(raw, original: text),
                          model: model, duration: Date().timeIntervalSince(started))
    }
}
