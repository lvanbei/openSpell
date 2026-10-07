import Foundation
import OpenSpellCore

struct RecommendedModel: Identifiable {
    let name: String
    let repo: String
    let size: String
    let vendor: String
    let blurb: String
    var id: String { repo }
}

extension ModelStore {
    static let recommended: [RecommendedModel] = [
        .init(name: "Qwen3 4B Instruct", repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", size: "2.3 GB",
              vendor: "Alibaba", blurb: "Quick and sharp — the best balance on any Apple silicon Mac."),
        .init(name: "Gemma 3n E4B", repo: "mlx-community/gemma-3n-E4B-it-lm-4bit", size: "3.9 GB",
              vendor: "Google", blurb: "Trained on 140+ languages — great with nuance and idioms."),
        .init(name: "Mistral 7B Instruct", repo: "mlx-community/Mistral-7B-Instruct-v0.3-4bit", size: "4.1 GB",
              vendor: "Mistral AI", blurb: "Made in France — superb French. Best with 16 GB of RAM."),
    ]

    nonisolated static var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("arm64")
    }
}

/// On-device models: MLX inference and Hugging Face downloads.
struct MLXRuntime: LocalModelRuntime {
    func makeDownloader() -> any ModelDownloader { HFDownloader() }

    func complete(directory: URL, extraEOSTokens: Set<String>, system: String, user: String) async throws -> String {
        guard ModelStore.isAppleSilicon else { throw ModelError.appleSiliconRequired }
        return try await LocalLLM.shared.complete(directory: directory, extraEOSTokens: extraEOSTokens,
                                                  system: system, user: user)
    }

    func preload(directory: URL, extraEOSTokens: Set<String>) async throws {
        try await LocalLLM.shared.preload(directory: directory, extraEOSTokens: extraEOSTokens)
    }

    func unload() async {
        await LocalLLM.shared.unload()
    }
}

extension HFDownloader: ModelDownloader {}
