import Testing
@testable import OpenSpellCore

struct OpenRouterClientTests {
    private func model(_ id: String, free: Bool = true, context: Int = 128_000) -> OpenRouterClient.CatalogModel {
        OpenRouterClient.CatalogModel(id: id, name: id, contextLength: context,
                                      promptPrice: free ? 0 : 0.000001, completionPrice: free ? 0 : 0.000002)
    }

    @Test func recognisesFreeSlugs() {
        #expect(OpenRouterClient.isFreeSlug("google/gemma-3-27b-it:free"))
        #expect(OpenRouterClient.isFreeSlug("openrouter/free"))
        #expect(!OpenRouterClient.isFreeSlug("google/gemini-2.5-flash"))
    }

    @Test func recommendsTheBiggestFreeModelOfThePreferredFamily() {
        let catalog = [
            model("openrouter/free"),
            model("meta-llama/llama-guard-4-12b:free"),
            model("qwen/qwen3-14b:free"),
            model("google/gemma-3-12b-it:free"),
            model("google/gemma-3-27b-it:free"),
            model("mistralai/mistral-large", free: false),
        ]
        #expect(OpenRouterClient.recommendedFree(from: catalog)?.id == "google/gemma-3-27b-it:free")
    }

    @Test func neverRecommendsTheFreeRouterOrUnsuitableModels() {
        let catalog = [model("openrouter/free"), model("some/coder-7b:free"), model("vendor/chat-8b:free")]
        #expect(OpenRouterClient.recommendedFree(from: catalog)?.id == "vendor/chat-8b:free")
        #expect(OpenRouterClient.recommendedFree(from: [model("openrouter/free")]) == nil)
    }

    @Test func labels() {
        #expect(model("a").priceLabel == "Free")
        #expect(model("a", context: 128_000).contextLabel == "128K ctx")
        #expect(model("a", context: 1_048_576).contextLabel == "1M ctx")
    }
}
