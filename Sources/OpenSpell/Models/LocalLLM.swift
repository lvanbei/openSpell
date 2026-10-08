import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Bridges swift-transformers' tokenizer to mlx-swift-lm's protocol
/// (same thing the `#huggingFaceTokenizerLoader()` macro generates).
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Weights are already on disk, so the downloader is never used.
private struct NoDownloader: MLXLMCommon.Downloader {
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        throw CocoaError(.fileNoSuchFile)
    }
}

/// Runs MLX models on-device. Keeps the last used model in memory until it has been idle for `idleTimeout`.
actor LocalLLM {
    static let shared = LocalLLM()

    /// Weights take gigabytes of unified memory, which an idle menu bar app shouldn't hold on to.
    static let idleTimeout: Duration = .seconds(3 * 60)

    private var loadedDirectory: URL?
    private var container: ModelContainer?
    /// Loads and generations in flight; the idle timer never unloads under them.
    private var activeRequests = 0
    private var idleUnload: Task<Void, Never>?

    init() {
        // Keep MLX's buffer cache modest — we're a background utility.
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }

    func complete(directory: URL, extraEOSTokens: Set<String>, system: String, user: String) async throws -> String {
        beginUse()
        defer { endUse() }
        let container = try await load(directory: directory, extraEOSTokens: extraEOSTokens)
        // Rough upper bound: corrections are about as long as the input.
        let maxTokens = min(4096, max(128, user.utf8.count / 2 + 64))
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)

        // Hybrid reasoning models (Qwen3 etc.) honour this; other templates ignore it.
        let context: [String: any Sendable] = ["enable_thinking": false]

        do {
            let session = ChatSession(container, instructions: system, generateParameters: params,
                                      additionalContext: context)
            return try await session.respond(to: user)
        } catch {
            // Some chat templates (older Mistral/Gemma) reject a system role — inline it instead.
            let session = ChatSession(container, generateParameters: params, additionalContext: context)
            return try await session.respond(to: system + "\n\nText:\n" + user)
        }
    }

    func preload(directory: URL, extraEOSTokens: Set<String>) async throws {
        beginUse()
        defer { endUse() }
        _ = try await load(directory: directory, extraEOSTokens: extraEOSTokens)
    }

    func unload() {
        idleUnload?.cancel()
        container = nil
        loadedDirectory = nil
        MLX.Memory.clearCache()
    }

    private func beginUse() {
        activeRequests += 1
        idleUnload?.cancel()
    }

    private func endUse() {
        activeRequests -= 1
        guard activeRequests == 0, container != nil else { return }
        idleUnload = Task {
            try? await Task.sleep(for: Self.idleTimeout)
            if !Task.isCancelled { unload() }
        }
    }

    private func load(directory: URL, extraEOSTokens: Set<String>) async throws -> ModelContainer {
        if let container, loadedDirectory == directory { return container }
        unload()
        let configuration = ModelConfiguration(directory: directory, extraEOSTokens: extraEOSTokens)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: NoDownloader(), using: TransformersTokenizerLoader(), configuration: configuration)
        container = loaded
        loadedDirectory = directory
        return loaded
    }
}
