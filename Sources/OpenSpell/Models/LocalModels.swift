import Foundation
import MLXLLM
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
        .init(name: "Qwen3.5 4B", repo: "mlx-community/Qwen3.5-4B-MLX-4bit", size: "3.1 GB",
              vendor: "Alibaba", blurb: "The newer generation — accurate in many languages."),
        .init(name: "Gemma 3n E4B", repo: "mlx-community/gemma-3n-E4B-it-lm-4bit", size: "3.9 GB",
              vendor: "Google", blurb: "Trained on 140+ languages — great with nuance and idioms."),
        .init(name: "Gemma 4 E4B", repo: "mlx-community/gemma-4-e4b-it-4bit", size: "5.2 GB",
              vendor: "Google", blurb: "The most accurate here, superb in French. Best with 16 GB of RAM."),
        .init(name: "Llama 3.2 3B Instruct", repo: "mlx-community/Llama-3.2-3B-Instruct-4bit", size: "1.8 GB",
              vendor: "Meta", blurb: "The smallest and fastest. Best in English, fine with 8 GB of RAM."),
    ]

    nonisolated static var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("arm64")
    }
}

/// Searches Hugging Face for MLX text models that OpenSpell can run.
enum HFSearch {
    struct Model: Identifiable, Hashable, Sendable {
        /// The repo, e.g. "mlx-community/Qwen3-4B-Instruct-2507-4bit".
        let id: String
        let downloads: Int
        /// Weight precision from the repo's tags, e.g. 4.
        let bits: Int?

        var name: String { (id as NSString).lastPathComponent }
        var author: String { (id as NSString).deletingLastPathComponent }
    }

    /// The most downloaded matches first. Gated repos, embedding models and architectures MLX can't run are left out.
    static func models(matching query: String, communityOnly: Bool) async throws -> [Model] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "expand[]", value: "tags"),
            URLQueryItem(name: "expand[]", value: "downloads"),
            URLQueryItem(name: "expand[]", value: "gated"),
        ]
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { components.queryItems?.append(URLQueryItem(name: "search", value: query)) }
        if communityOnly { components.queryItems?.append(URLQueryItem(name: "author", value: "mlx-community")) }

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HFDownloadError.http(status, "the model list") }
        var models: [Model] = []
        for item in (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? [] {
            // `gated` is false, or a string saying how access is granted (downloads would need a token).
            guard let id = item["id"] as? String, !(item["gated"] is String), item["gated"] as? Bool != true,
                  !["embed", "rerank"].contains(where: id.lowercased().contains) else { continue }
            let tags = item["tags"] as? [String] ?? []
            // Hugging Face tags a repo with its architecture (config.json's model_type).
            var runnable = false
            for tag in tags where await LLMTypeRegistry.shared.contains(tag) {
                runnable = true
                break
            }
            guard runnable else { continue }
            // Tagged "4-bit" or "4bit".
            let bits = tags.lazy.compactMap { $0.hasSuffix("bit") ? Int($0.dropLast(3).replacingOccurrences(of: "-", with: "")) : nil }.first
            models.append(Model(id: id, downloads: item["downloads"] as? Int ?? 0, bits: bits))
        }
        return models
    }

    /// Bytes to download: weights, configuration and tokenizer.
    static func downloadSize(of repo: String) async throws -> Int64 {
        try await HFDownloader.listFiles(repo: repo).reduce(0) { $0 + $1.size }
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
