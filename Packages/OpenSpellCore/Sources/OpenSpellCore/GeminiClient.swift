import Foundation

public enum GeminiError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case emptyResponse(String?)
    /// The model was retired / isn't offered to this key. `suggestion` is Google's suggested replacement, if any.
    case modelUnavailable(model: String, suggestion: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add a Gemini API key in \(modelsSettings)."
        case .http(let code, let message): "Gemini error \(code): \(message)"
        case .emptyResponse(let reason):
            "Gemini returned no text" + (reason.map { " (\($0))" } ?? "") + "."
        case .modelUnavailable(let model, _, let message):
            "\(model) isn't available: \(message)"
        }
    }
}

/// Client for Google's Gemini API (Google AI Studio keys), used directly without OpenRouter.
public enum GeminiClient {
    static let keychainAccount = "gemini-api-key"
    private static let base = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    public static var apiKey: String? { Keychain.get(keychainAccount) }

    /// Accepts "gemini-2.5-flash", "models/gemini-2.5-flash" or "google/gemini-2.5-flash".
    public static func normalize(_ model: String) -> String {
        var m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["models/", "google/"] where m.hasPrefix(prefix) { m = String(m.dropFirst(prefix.count)) }
        return m
    }

    public static func complete(model rawModel: String, system: String, user: String,
                                apiKey overrideKey: String? = nil) async throws -> String {
        guard let key = overrideKey ?? apiKey, !key.isEmpty else { throw GeminiError.missingAPIKey }
        let model = normalize(rawModel)
        do {
            return try await generate(model: model, system: system, user: user, key: key,
                                      thinking: reducedThinkingConfig(for: model))
        } catch GeminiError.http(400, let message) where message.localizedCaseInsensitiveContains("thinking") {
            // This model doesn't accept our "think less" setting — fall back to its defaults.
            return try await generate(model: model, system: system, user: user, key: key, thinking: nil)
        }
    }

    /// Proofreading doesn't need reasoning, so ask for as little as each generation allows.
    /// (2.5 Flash/Flash-Lite take a zero budget; Gemini 3+ use thinking levels; others keep defaults.)
    private static func reducedThinkingConfig(for model: String) -> [String: Any]? {
        if model.hasPrefix("gemini-2.5-flash") { return ["thinkingBudget": 0] }
        if let version = version(of: model), version >= 3, model.contains("flash") { return ["thinkingLevel": "minimal"] }
        return nil
    }

    private static func generate(model: String, system: String, user: String, key: String,
                                 thinking: [String: Any]?) async throws -> String {
        var request = URLRequest(url: base.appending(path: "models/\(model):generateContent"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generationConfig: [String: Any] = ["temperature": 0]
        if let thinking { generationConfig["thinkingConfig"] = thinking }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": generationConfig,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200..<300).contains(status) else {
            let message = errorMessage(json, data: data, status: status)
            if status == 404 {
                throw GeminiError.modelUnavailable(model: model, suggestion: suggestedReplacement(in: message, for: model),
                                                   message: message)
            }
            throw GeminiError.http(status, message)
        }
        let candidates = json?["candidates"] as? [[String: Any]] ?? []
        let parts = ((candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        // Skip "thought" parts if a model returns them.
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            let reason = (candidates.first?["finishReason"] as? String)
                ?? ((json?["promptFeedback"] as? [String: Any])?["blockReason"] as? String)
            throw GeminiError.emptyResponse(reason)
        }
        return text
    }

    /// Pulls "models/<id>" out of Google's "please use models/… instead" messages.
    static func suggestedReplacement(in message: String, for model: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"models/([A-Za-z0-9.\-]+)"#) else { return nil }
        let ns = message as NSString
        for match in regex.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            if id != model, id.hasPrefix("gemini") { return id }
        }
        return nil
    }

    // MARK: Model discovery

    public struct ModelInfo: Identifiable, Hashable {
        public let id: String           // e.g. "gemini-3.8-flash"
        public let displayName: String
    }

    /// All models this key can call with generateContent.
    static func listModels(apiKey key: String) async throws -> [ModelInfo] {
        var result: [ModelInfo] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: base.appending(path: "models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200..<300).contains(status), let json else {
                throw GeminiError.http(status, errorMessage(json, data: data, status: status))
            }
            for m in json["models"] as? [[String: Any]] ?? [] {
                guard let name = m["name"] as? String,
                      (m["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { continue }
                let id = normalize(name)
                guard id.hasPrefix("gemini") else { continue }
                result.append(ModelInfo(id: id, displayName: m["displayName"] as? String ?? id))
            }
            pageToken = json["nextPageToken"] as? String
            if pageToken?.isEmpty == true { pageToken = nil }
        } while pageToken != nil
        return result.sorted { rank($0.id) > rank($1.id) }
    }

    /// Best default for proofreading: newest stable Flash-Lite, then Flash, then previews.
    public static func recommended(from models: [ModelInfo]) -> ModelInfo? {
        models.filter { isTextModel($0.id) && $0.id.contains("flash") }.max { rank($0.id) < rank($1.id) }
            ?? models.filter { isTextModel($0.id) }.max { rank($0.id) < rank($1.id) }
    }

    /// Offline fallback: Google's moving alias for the current Flash model.
    public static let fallbackModel = "gemini-flash-latest"

    private static func isTextModel(_ id: String) -> Bool {
        let excluded = ["image", "tts", "audio", "live", "embedding", "vision", "robotics", "computer-use", "native"]
        return !excluded.contains { id.contains($0) }
    }

    static func version(of id: String) -> Double? {
        guard let r = id.range(of: #"gemini-(\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
        return Double(id[r].dropFirst("gemini-".count))
    }

    /// Higher = better default. Stable > preview/exp; Flash > Flash-Lite > others; newer version wins.
    private static func rank(_ id: String) -> Double {
        guard isTextModel(id) else { return -1 }
        var score = (version(of: id) ?? 0) * 100
        let unstable = id.contains("preview") || id.contains("exp") || id.contains("latest")
        if !unstable { score += 50 }
        // Proofreading favours speed: Flash-Lite answers in ~1 s, full Flash can take 5–15 s.
        if id.contains("flash-lite") { score += 30 }
        else if id.contains("flash") { score += 20 }
        if id.range(of: #"-\d{3}$"#, options: .regularExpression) != nil { score -= 1 } // pinned "-001" variants
        return score
    }

    /// Validates a key without generating anything (lists one model).
    public static func checkKey(_ key: String) async throws {
        var components = URLComponents(url: base.appending(path: "models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw GeminiError.http(status, errorMessage(json, data: data, status: status))
        }
    }

    /// Returns the model's display name if it exists and supports text generation.
    static func lookup(model rawModel: String, apiKey key: String) async throws -> String? {
        let model = normalize(rawModel)
        var request = URLRequest(url: base.appending(path: "models/\(model)"))
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if status == 404 { return nil }
        guard (200..<300).contains(status), let json else {
            throw GeminiError.http(status, errorMessage(json, data: data, status: status))
        }
        let methods = json["supportedGenerationMethods"] as? [String] ?? []
        guard methods.contains("generateContent") else { return nil }
        return json["displayName"] as? String ?? model
    }

    private static func errorMessage(_ json: [String: Any]?, data: Data, status: Int) -> String {
        let message = ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(data: data, encoding: .utf8) ?? "Unknown error"
        if status == 400 || status == 401 || status == 403,
           message.localizedCaseInsensitiveContains("API key"),
           !message.localizedCaseInsensitiveContains("thinking") {
            return "Invalid API key (\(message))"
        }
        return message
    }
}
