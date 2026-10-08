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
        case .modelNotReady(.apple): AppleIntelligence.status.message ?? "Apple Intelligence isn't ready"
        case .modelNotReady: "Choose a language model first"
        }
    }
}

/// The model answered with something other than the whole text corrected: a reply, a translation, a summary,
/// only part of it, or notes around it.
public struct NotACorrectionError: LocalizedError, Equatable {
    public var errorDescription: String? {
        "The model didn't return your text corrected, so nothing was changed. Try again or pick another model"
    }
}

public struct Correction: Sendable {
    public let original: String
    public let corrected: String
    public let model: ModelEntry
    public let duration: TimeInterval

    public init(original: String, corrected: String, model: ModelEntry, duration: TimeInterval) {
        self.original = original
        self.corrected = corrected
        self.model = model
        self.duration = duration
    }

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
        let corrected = try await correctedText(text, language: language, model: model)
        try Task.checkCancellation()
        return Correction(original: text, corrected: corrected, model: model, duration: Date().timeIntervalSince(started))
    }

    private static func correctedText(_ text: String, language: CorrectionLanguage, model: ModelEntry) async throws -> String {
        // The on-device model's context window is small, so it splits long text itself.
        if model.kind == .apple { return try await AppleIntelligence.correct(text, language: language) }
        return try await ask(text, system: CorrectionPrompt.system(language: language)) { system, user in
            try await ModelStore.shared.complete(system: system, user: user)
        }
    }

    /// Asks for `text` corrected, and once more with a reminder if the answer is something else.
    /// Never returns anything but the whole text, corrected.
    nonisolated public static func ask(_ text: String, system: String,
                                       model: @Sendable (_ system: String, _ user: String) async throws -> String) async throws -> String {
        for user in [CorrectionPrompt.user(text), CorrectionPrompt.retry(text)] {
            let output = CorrectionPrompt.clean(try await model(system, user), original: text)
            if let corrected = CorrectionCheck.correction(in: output, of: text) {
                return CorrectionPrompt.surrounded(corrected, like: text)
            }
            try Task.checkCancellation()
            NSLog("OpenSpell: the model's answer wasn't the corrected text (\(output.count) characters for \(text.count))")
        }
        throw NotACorrectionError()
    }
}
