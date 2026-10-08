import Foundation
import FoundationModels

/// Apple Intelligence's on-device model (macOS 26 and iOS 26 or later). It runs in a system process, so the iOS
/// keyboard can use it despite its memory limit, and nothing has to be downloaded.
public enum AppleIntelligence {
    public enum Status: Equatable, Sendable {
        case available, deviceNotEligible, notEnabled, notReady, systemTooOld

        /// Why the model can't be used right now, or nil when it can.
        public var message: String? {
            switch self {
            case .available: nil
            #if os(iOS)
            case .deviceNotEligible: "This iPhone doesn't support Apple Intelligence"
            case .notEnabled: "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri"
            #else
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence"
            case .notEnabled: "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri"
            #endif
            case .notReady: "Apple Intelligence is still downloading. Try again later"
            case .systemTooOld: "Apple Intelligence needs macOS 26 or later"
            }
        }
    }

    public static var status: Status {
        guard #available(macOS 26.0, iOS 26.0, *) else { return .systemTooOld }
        return SystemModel.status
    }

    /// Codes of the languages the model handles, such as "en" and "fr".
    public static var languageCodes: Set<String> {
        guard #available(macOS 26.0, iOS 26.0, *) else { return [] }
        return SystemModel.languageCodes
    }

    /// Auto-detect always passes; the model reports text in a language it doesn't handle.
    public static func supports(_ language: CorrectionLanguage) -> Bool {
        language.code.map(languageCodes.contains) ?? true
    }

    /// Proofreads `text`, in several requests when it doesn't fit the small context window at once.
    public static func correct(_ text: String, language: CorrectionLanguage) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw CorrectionError.modelNotReady(.apple) }
        return try await SystemModel.correct(text, language: language)
    }

    /// One request in a fresh session.
    static func respond(system: String, user: String) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw CorrectionError.modelNotReady(.apple) }
        return try await SystemModel.respond(system: system, user: user)
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum SystemModel {
    // Permissive guardrails are meant for transforming the user's own text, such as proofreading it.
    static let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    static var status: AppleIntelligence.Status {
        switch model.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .notReady
        case .unavailable: .deviceNotEligible
        }
    }

    static var languageCodes: Set<String> {
        Set(model.supportedLanguages.compactMap { $0.languageCode?.identifier })
    }

    static func correct(_ text: String, language: CorrectionLanguage) async throws -> String {
        guard AppleIntelligence.supports(language) else { throw AppleIntelligenceError.unsupportedLanguage(language.name) }
        let system = CorrectionPrompt.system(language: language)
        let budget = await inputBudget(system: system)
        let total = await tokens(in: text)
        var pieces = [text[...]]
        if total > budget {
            // Parts tokenize a little differently from the whole, hence the headroom.
            let perByte = Double(total) / Double(max(text.utf8.count, 1)) * 1.1
            pieces = TextChunker.chunks(of: text, budget: budget) { Int((Double($0.utf8.count) * perByte).rounded(.up)) }
        }
        var corrected = ""
        for piece in pieces.map(String.init) {
            if piece.allSatisfy(\.isWhitespace) {
                corrected += piece
            } else {
                corrected += try await CorrectionService.ask(piece, system: system) { try await respond(system: $0, user: $1) }
            }
        }
        return corrected
    }

    /// Greedy sampling gives the same text the same fix every time.
    static func respond(system: String, user: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: system)
        do {
            return try await session.respond(to: user, options: GenerationOptions(samplingMode: .greedy)).content
        } catch {
            throw AppleIntelligenceError(error) ?? error
        }
    }

    /// Input tokens per request. The answer is about as long as the text, so they share what the instructions leave.
    private static func inputBudget(system: String) async -> Int {
        let instructions = await tokens(in: system)
        return max(100, (model.contextSize - instructions - 200) / 2)
    }

    private static func tokens(in text: String) async -> Int {
        if #available(macOS 26.4, iOS 26.4, *), let count = try? await model.tokenCount(for: text) { return count }
        return text.utf8.count / 2 + 1
    }
}

public enum AppleIntelligenceError: LocalizedError, Equatable {
    /// The language's name, or nil when the model rejected the text's language.
    case unsupportedLanguage(String?)
    case tooLong, declined, busy, notReady

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let name):
            "Apple Intelligence doesn't support \(name ?? "this language") yet. Use another model"
        case .tooLong: "This text is too long for Apple Intelligence. Select a shorter part"
        case .declined: "Apple Intelligence declined this text. Try another model"
        case .busy: "Apple Intelligence is busy. Try again in a moment"
        case .notReady: AppleIntelligence.Status.notReady.message
        }
    }

    /// Maps FoundationModels errors to messages; nil for other errors.
    @available(macOS 26.0, iOS 26.0, *)
    init?(_ error: any Error) {
        if #available(macOS 27.0, iOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: self = .tooLong
                case .guardrailViolation, .refusal: self = .declined
                case .unsupportedLanguageOrLocale: self = .unsupportedLanguage(nil)
                case .rateLimited: self = .busy
                default: return nil
                }
                return
            }
            if error is SystemLanguageModel.Error {
                self = .notReady
                return
            }
        }
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        switch error {
        case .exceededContextWindowSize: self = .tooLong
        case .guardrailViolation, .refusal: self = .declined
        case .unsupportedLanguageOrLocale: self = .unsupportedLanguage(nil)
        case .rateLimited, .concurrentRequests: self = .busy
        case .assetsUnavailable: self = .notReady
        default: return nil
        }
    }
}
