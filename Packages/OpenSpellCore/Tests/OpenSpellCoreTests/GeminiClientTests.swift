import Testing
@testable import OpenSpellCore

struct GeminiClientTests {
    @Test func normalizesModelIds() {
        #expect(GeminiClient.normalize("models/gemini-2.5-flash") == "gemini-2.5-flash")
        #expect(GeminiClient.normalize("google/gemini-2.5-flash") == "gemini-2.5-flash")
        #expect(GeminiClient.normalize("  gemini-2.5-flash \n") == "gemini-2.5-flash")
    }

    @Test func recommendsTheNewestStableFlashLite() {
        let models = ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.2-flash-preview",
                      "gemini-2.5-pro", "gemini-3.1-flash-image", "gemini-3.1-flash-lite-001"]
            .map { GeminiClient.ModelInfo(id: $0, displayName: $0) }
        #expect(GeminiClient.recommended(from: models)?.id == "gemini-3.1-flash-lite")
    }

    @Test func recommendsANonFlashTextModelWhenThereIsNoFlash() {
        let models = ["gemini-2.5-pro", "gemini-2.5-pro-tts"].map { GeminiClient.ModelInfo(id: $0, displayName: $0) }
        #expect(GeminiClient.recommended(from: models)?.id == "gemini-2.5-pro")
        #expect(GeminiClient.recommended(from: []) == nil)
    }

    @Test func findsGooglesSuggestedReplacement() {
        #expect(GeminiClient.suggestedReplacement(
            in: "Gemini 1.5 Flash is no longer available. Please use models/gemini-2.5-flash instead.",
            for: "gemini-1.5-flash") == "gemini-2.5-flash")
        #expect(GeminiClient.suggestedReplacement(
            in: "models/gemini-1.5-flash was retired, migrate to models/gemini-2.0-flash.",
            for: "gemini-1.5-flash") == "gemini-2.0-flash")
        #expect(GeminiClient.suggestedReplacement(in: "Use models/text-bison instead.", for: "gemini-1.5-flash") == nil)
    }

    @Test func parsesVersions() {
        #expect(GeminiClient.version(of: "gemini-2.5-flash") == 2.5)
        #expect(GeminiClient.version(of: "gemini-3-flash") == 3)
        #expect(GeminiClient.version(of: "learnlm-2.0") == nil)
    }
}
