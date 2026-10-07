import Foundation

public enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenRouter API key in \(modelsSettings)."
        case .http(let code, let message): "OpenRouter error \(code): \(message)"
        case .emptyResponse: "The model returned an empty answer."
        }
    }
}

/// Thin client for OpenRouter's OpenAI-compatible chat completions API.
public enum OpenRouterClient {
    static let keychainAccount = "openrouter-api-key"
    private static let base = URL(string: "https://openrouter.ai/api/v1")!

    public static var apiKey: String? { Keychain.get(keychainAccount) }

    public static func complete(model: String, system: String, user: String, apiKey overrideKey: String? = nil) async throws -> String {
        guard let key = overrideKey ?? apiKey, !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        do {
            return try await send(model: model, system: system, user: user, key: key, mustReason: false)
        } catch OpenRouterError.http(400, let message) where message.localizedCaseInsensitiveContains("reasoning is mandatory") {
            // This model (or the one a router like openrouter/free picked) can't stop reasoning — keep it minimal instead.
            return try await send(model: model, system: system, user: user, key: key, mustReason: true)
        }
    }

    private static func send(model: String, system: String, user: String, key: String, mustReason: Bool) async throws -> String {
        var request = URLRequest(url: base.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/openspell", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("OpenSpell", forHTTPHeaderField: "X-Title")

        // Without a cap OpenRouter reserves the model's full output length against your credit,
        // which fails on free / low-balance keys. Corrections are about as long as the input.
        let answerTokens = min(4096, max(256, user.utf8.count / 2 + 128))
        // Don't spend tokens "thinking" for a proofreading task.
        let reasoning: [String: Any] = mustReason ? ["effort": "minimal", "exclude": true] : ["enabled": false]
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // Reasoning tokens count against max_tokens, so leave room to think before answering.
            "max_tokens": mustReason ? answerTokens + 2048 : answerTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "reasoning": reasoning,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            if status == 401 { throw OpenRouterError.http(401, "Invalid API key (\(message)). Check it in \(modelsSettings).") }
            if status == 402 {
                throw OpenRouterError.http(402, "\(model) needs OpenRouter credits. Pick a model marked Free in \(modelsSettings) › Browse models, or add credits.")
            }
            if status == 429 {
                throw OpenRouterError.http(429, "\(model) is rate-limited right now (free models are shared). Try again in a moment or pick another model. (\(message))")
            }
            throw OpenRouterError.http(status, message)
        }
        if let err = json?["error"] as? [String: Any] {
            throw OpenRouterError.http(status, err["message"] as? String ?? "Unknown error")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw OpenRouterError.emptyResponse
        }
        return content
    }

    struct ModelInfo { let id: String; let name: String }

    /// A model from OpenRouter's public catalogue.
    public struct CatalogModel: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let contextLength: Int
        /// USD per token.
        public let promptPrice: Double
        public let completionPrice: Double

        public var isFree: Bool { promptPrice == 0 && completionPrice == 0 }

        /// "$0.10 / $0.40 per M tokens" style summary.
        public var priceLabel: String {
            if isFree { return "Free" }
            return String(format: "$%.2g / $%.2g per M", promptPrice * 1_000_000, completionPrice * 1_000_000)
        }

        public var contextLabel: String {
            contextLength >= 1_000_000 ? "\(contextLength / 1_000_000)M ctx" : "\(contextLength / 1000)K ctx"
        }
    }

    static func isFreeSlug(_ slug: String) -> Bool { slug.hasSuffix(":free") || slug == "openrouter/free" }

    /// Text-in / text-out models only (no image, audio or music generators).
    static func catalog() async throws -> [CatalogModel] {
        let (data, _) = try await URLSession.shared.data(from: base.appending(path: "models"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = json?["data"] as? [[String: Any]] ?? []
        return models.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let arch = m["architecture"] as? [String: Any]
            let inputs = arch?["input_modalities"] as? [String] ?? ["text"]
            let outputs = arch?["output_modalities"] as? [String] ?? ["text"]
            guard inputs.contains("text"), outputs == ["text"] else { return nil }
            let pricing = m["pricing"] as? [String: Any]
            func price(_ key: String) -> Double {
                if let s = pricing?[key] as? String { return Double(s) ?? 1 }
                return (pricing?[key] as? NSNumber)?.doubleValue ?? 1
            }
            return CatalogModel(id: id, name: m["name"] as? String ?? id,
                                contextLength: (m["context_length"] as? NSNumber)?.intValue ?? 0,
                                promptPrice: price("prompt"), completionPrice: price("completion"))
        }
    }

    /// Best free model for proofreading: a general-purpose instruct model, preferably from a well-known
    /// family. Never OpenRouter's own free router, which answers with a different model each time.
    public static func recommendedFree(from catalog: [CatalogModel]) -> CatalogModel? {
        let unsuitable = ["safety", "guard", "code", "coder", "reasoning", "omni", "vision", "math"]
        let families = ["google/gemma", "meta-llama/", "mistralai/", "qwen/", "nvidia/nemotron", "deepseek/"]
        let candidates = catalog.filter { m in
            m.isFree && m.id != "openrouter/free" && !unsuitable.contains { m.id.lowercased().contains($0) }
        }
        for family in families {
            // Within a family prefer the biggest-looking model (more accurate), e.g. 31b over 26b-a4b.
            let inFamily = candidates.filter { $0.id.hasPrefix(family) }
            if let best = inFamily.max(by: { parameterSize($0.id) < parameterSize($1.id) }) { return best }
        }
        return candidates.first
    }

    /// Rough parameter count from ids like "gemma-4-31b-it" → 31.
    private static func parameterSize(_ id: String) -> Double {
        guard let r = id.range(of: #"(\d+(\.\d+)?)b\b"#, options: .regularExpression) else { return 0 }
        return Double(id[r].dropLast()) ?? 0
    }

    public struct KeyInfo {
        public let label: String?
        public let usage: Double?
        public let limit: Double?
        public let isFreeTier: Bool

        public var summary: String {
            var parts: [String] = []
            if let label, !label.isEmpty { parts.append("“\(label)”") }
            if let limit, let usage {
                parts.append(String(format: "$%.2f of $%.2f left", max(0, limit - usage), limit))
            } else if let usage {
                parts.append(String(format: "$%.2f used, no limit", usage))
            }
            if isFreeTier { parts.append("free tier") }
            return parts.joined(separator: " · ")
        }
    }

    /// Validates a key without spending credits (GET /key).
    public static func checkKey(_ key: String) async throws -> KeyInfo {
        var request = URLRequest(url: base.appending(path: "key"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status), let info = json?["data"] as? [String: Any] else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "Unexpected response"
            if status == 401 { throw OpenRouterError.http(401, "Invalid API key (\(message))") }
            throw OpenRouterError.http(status, message)
        }
        return KeyInfo(label: info["label"] as? String,
                       usage: (info["usage"] as? NSNumber)?.doubleValue,
                       limit: (info["limit"] as? NSNumber)?.doubleValue,
                       isFreeTier: info["is_free_tier"] as? Bool ?? false)
    }

    /// Looks a slug up in OpenRouter's public catalogue. Returns nil if it doesn't exist.
    static func lookup(slug: String) async throws -> ModelInfo? {
        let (data, _) = try await URLSession.shared.data(from: base.appending(path: "models"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = json?["data"] as? [[String: Any]] ?? []
        guard let match = models.first(where: { ($0["id"] as? String) == slug }) else { return nil }
        let name = (match["name"] as? String) ?? slug
        return ModelInfo(id: slug, name: name)
    }
}
