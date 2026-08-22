import Foundation

enum AnthropicError: Error, CustomStringConvertible {
    case noAuth
    case http(status: Int, message: String)
    case refusal(String)
    case truncated
    case structuredOutputRejected
    case decode(String)
    case transport(String)

    var description: String {
        switch self {
        case .noAuth: return "No Claude account or API key configured"
        case .http(let s, let m): return "Claude API error \(s): \(m)"
        case .refusal(let m): return "The model declined this request: \(m)"
        case .truncated: return "Response hit the token limit"
        case .structuredOutputRejected: return "Structured output not accepted"
        case .decode(let m): return "Could not parse Claude response: \(m)"
        case .transport(let m): return "Network error: \(m)"
        }
    }
}

enum AnthropicAuth {
    case apiKey(String)
    case oauth(String)
}

struct AnthropicResult {
    var text: String
    var citations: [URL]
    var stopReason: String
    var servedBy: String
    var inputTokens: Int
    var outputTokens: Int
}

// Raw Messages API client. Swift has no official SDK, so this speaks the wire
// format directly: web_search_20260209 for retrieval, output_config.format
// (json_schema) for structured packs, server-side refusal fallbacks enabled.
// Auth is either the user's Claude account (OAuth bearer token minted by the
// Anthropic CLI, oauth-2025-04-20 beta) or a plain API key.
final class AnthropicClient: @unchecked Sendable {
    private var auth: AnthropicAuth
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(auth: AnthropicAuth, model: String) {
        self.auth = auth
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
    }

    // Claude account (CLI profile) wins over a pasted key when both exist.
    @MainActor
    static func resolve() async -> AnthropicClient? {
        let model = Prefs.shared.packModel
        if let token = await Task.detached(operation: { AntCLI.mintAccessToken() }).value {
            return AnthropicClient(auth: .oauth(token), model: model)
        }
        if let key = Keychain.get(account: SecretAccount.anthropicKey), !key.isEmpty {
            return AnthropicClient(auth: .apiKey(key), model: model)
        }
        return nil
    }

    func complete(
        system: String? = nil,
        user: String,
        webSearch: Bool = false,
        maxSearches: Int = 8,
        outputSchema: [String: Any]? = nil,
        maxTokens: Int = 16000
    ) async throws -> AnthropicResult {
        try await send(
            system: system, user: user, webSearch: webSearch, maxSearches: maxSearches,
            outputSchema: outputSchema, maxTokens: maxTokens,
            useFallbacks: modelSupportsFallbacks, retriesLeft: 2
        )
    }

    private var modelSupportsFallbacks: Bool {
        model.contains("opus-5") || model.contains("fable")
    }

    private func send(
        system: String?,
        user: String,
        webSearch: Bool,
        maxSearches: Int,
        outputSchema: [String: Any]?,
        maxTokens: Int,
        useFallbacks: Bool,
        retriesLeft: Int
    ) async throws -> AnthropicResult {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": user]],
        ]
        if let system {
            body["system"] = system
        }
        if webSearch {
            body["tools"] = [[
                "type": "web_search_20260209",
                "name": "web_search",
                "max_uses": maxSearches,
            ]]
        }
        if let outputSchema {
            body["output_config"] = ["format": ["type": "json_schema", "schema": outputSchema]]
        }
        if useFallbacks {
            body["fallbacks"] = "default"
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var betas = [String]()
        switch auth {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauth(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            betas.append("oauth-2025-04-20")
        }
        if useFallbacks {
            betas.append("server-side-fallback-2026-07-01")
        }
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let status: Int
        do {
            let (d, response) = try await session.data(for: request)
            data = d
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError.decode("non-JSON response, HTTP \(status)")
        }

        if status != 200 {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
            log(.anthropic, .warn, "HTTP \(status): \(message)")
            if status == 401, case .oauth = auth, retriesLeft > 0 {
                // Token expired mid-flight; the CLI refreshes on mint.
                if let fresh = await Task.detached(operation: { AntCLI.mintAccessToken() }).value {
                    auth = .oauth(fresh)
                    return try await send(
                        system: system, user: user, webSearch: webSearch, maxSearches: maxSearches,
                        outputSchema: outputSchema, maxTokens: maxTokens,
                        useFallbacks: useFallbacks, retriesLeft: retriesLeft - 1
                    )
                }
            }
            if status == 400 && useFallbacks && message.lowercased().contains("fallback") {
                return try await send(
                    system: system, user: user, webSearch: webSearch, maxSearches: maxSearches,
                    outputSchema: outputSchema, maxTokens: maxTokens,
                    useFallbacks: false, retriesLeft: retriesLeft
                )
            }
            if status == 400 && outputSchema != nil
                && (message.contains("output_config") || message.contains("format") || message.contains("schema")) {
                throw AnthropicError.structuredOutputRejected
            }
            if (status == 429 || status == 529 || status >= 500) && retriesLeft > 0 {
                let delay = status == 429 ? 30.0 : 10.0
                log(.anthropic, "Retrying in \(Int(delay))s (\(retriesLeft) retries left)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await send(
                    system: system, user: user, webSearch: webSearch, maxSearches: maxSearches,
                    outputSchema: outputSchema, maxTokens: maxTokens,
                    useFallbacks: useFallbacks, retriesLeft: retriesLeft - 1
                )
            }
            throw AnthropicError.http(status: status, message: message)
        }

        let stopReason = json["stop_reason"] as? String ?? ""
        if stopReason == "refusal" {
            let explanation = ((json["stop_details"] as? [String: Any])?["explanation"] as? String) ?? "safety refusal"
            throw AnthropicError.refusal(explanation)
        }

        var text = ""
        var citations = [URL]()
        for block in (json["content"] as? [[String: Any]]) ?? [] {
            guard block["type"] as? String == "text" else { continue }
            text += (block["text"] as? String) ?? ""
            for citation in (block["citations"] as? [[String: Any]]) ?? [] {
                if let urlString = citation["url"] as? String, let url = URL(string: urlString) {
                    citations.append(url)
                }
            }
        }

        if stopReason == "max_tokens" {
            throw AnthropicError.truncated
        }

        let usage = json["usage"] as? [String: Any]
        let result = AnthropicResult(
            text: text,
            citations: citations,
            stopReason: stopReason,
            servedBy: json["model"] as? String ?? model,
            inputTokens: (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0,
            outputTokens: (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0
        )
        log(.anthropic, "Completed via \(result.servedBy): in \(result.inputTokens)t out \(result.outputTokens)t stop=\(stopReason)")
        return result
    }
}
