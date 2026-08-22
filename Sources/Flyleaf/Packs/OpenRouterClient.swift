import Foundation

enum OpenRouterError: Error, CustomStringConvertible {
    case noKey
    case http(status: Int, message: String)
    case decode(String)
    case transport(String)
    case empty

    var description: String {
        switch self {
        case .noKey: return "No OpenRouter API key configured"
        case .http(let s, let m): return "OpenRouter error \(s): \(m)"
        case .decode(let m): return "Could not parse OpenRouter response: \(m)"
        case .transport(let m): return "Network error: \(m)"
        case .empty: return "OpenRouter returned an empty response"
        }
    }
}

// OpenAI-compatible client for OpenRouter, used with a cheap model to extract
// entities from local book text. Kept separate from the Anthropic client: the
// web-research path stays on Claude, this handles bulk text extraction.
final class OpenRouterClient: @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static let defaultModel = "google/gemini-3.7-flash"

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        session = URLSession(configuration: config)
    }

    @MainActor
    static func fromKeychain() -> OpenRouterClient? {
        guard let key = Keychain.get(account: SecretAccount.openRouterKey), !key.isEmpty else { return nil }
        return OpenRouterClient(apiKey: key, model: Prefs.shared.extractModel)
    }

    func extract(
        system: String,
        user: String,
        schema: [String: Any],
        schemaName: String = "extraction",
        maxTokens: Int = 8000
    ) async throws -> String {
        try await send(system: system, user: user, schema: schema, schemaName: schemaName, maxTokens: maxTokens, useSchema: true, retriesLeft: 2)
    }

    private func send(
        system: String,
        user: String,
        schema: [String: Any],
        schemaName: String,
        maxTokens: Int,
        useSchema: Bool,
        retriesLeft: Int
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if useSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema],
            ]
        } else {
            body["messages"] = [
                ["role": "system", "content": system + "\nRespond with only a single JSON object, no prose or code fences."],
                ["role": "user", "content": user],
            ]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/tldev/flyleaf", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Flyleaf", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let status: Int
        do {
            let (d, response) = try await session.data(for: request)
            data = d
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw OpenRouterError.transport(error.localizedDescription)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenRouterError.decode("non-JSON, HTTP \(status)")
        }

        if status != 200 {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
            log(.packs, .warn, "OpenRouter HTTP \(status): \(message)")
            // Some models reject strict json_schema; retry with prompt-only JSON.
            if useSchema && (status == 400 || status == 404 || message.lowercased().contains("response_format") || message.lowercased().contains("json_schema")) {
                return try await send(system: system, user: user, schema: schema, schemaName: schemaName, maxTokens: maxTokens, useSchema: false, retriesLeft: retriesLeft)
            }
            if (status == 429 || status >= 500) && retriesLeft > 0 {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return try await send(system: system, user: user, schema: schema, schemaName: schemaName, maxTokens: maxTokens, useSchema: useSchema, retriesLeft: retriesLeft - 1)
            }
            throw OpenRouterError.http(status: status, message: message)
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw OpenRouterError.empty
        }
        let usage = json["usage"] as? [String: Any]
        log(.packs, "OpenRouter \(model): in \((usage?["prompt_tokens"] as? NSNumber)?.intValue ?? 0)t out \((usage?["completion_tokens"] as? NSNumber)?.intValue ?? 0)t")
        return content
    }
}
