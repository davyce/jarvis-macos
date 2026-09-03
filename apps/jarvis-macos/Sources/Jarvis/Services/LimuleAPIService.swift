import Foundation

enum LimuleAPIService {
    enum ServiceError: LocalizedError {
        case invalidKey(String)
        case notConnected
        case apiError(Int, String)
        case invalidResponse
        case storage(String)
        case tooManyToolRounds

        var errorDescription: String? {
            switch self {
            case .invalidKey(let message):
                return "Connexion Limule refusee : \(message)"
            case .notConnected:
                return "Connecte d'abord la cle API Limule dans Connexions."
            case .apiError(let code, let message):
                return "Limule a repondu \(code) : \(message)"
            case .invalidResponse:
                return "La reponse de Limule est illisible."
            case .storage(let message):
                return "La cle Limule est valide, mais Jarvis ne peut pas l'enregistrer : \(message)"
            case .tooManyToolRounds:
                return "Jarvis a enchaine trop d'appels d'outils sans conclure -- reessaie une demande plus precise."
            }
        }
    }

    /// `content`/`toolCalls`/`toolCallID`/`name` are all optional so this
    /// same type covers every role's shape (a plain "system"/"user" turn
    /// only ever sets `content`; an assistant turn requesting tool use sets
    /// `toolCalls` and may leave `content` nil; a "tool" reply sets
    /// `content` to the result plus `toolCallID`/`name`) -- synthesized
    /// `Encodable` omits nil fields via `encodeIfPresent`, so none of the
    /// existing `.init(role:, content:)` call sites change shape on the
    /// wire.
    struct Message: Encodable {
        let role: String
        let content: String?
        let toolCalls: [ToolCall]?
        let toolCallID: String?
        let name: String?

        init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, name: String? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case role, content, name
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        struct ToolCall: Codable {
            let id: String
            let type: String
            let function: FunctionCall

            struct FunctionCall: Codable {
                let name: String
                let arguments: String
            }
        }
    }

    private struct CompletionRequest: Encodable {
        let messages: [Message]
        let stream = false
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct ResponseMessage: Decodable {
                let content: String?
                let toolCalls: [Message.ToolCall]?
                enum CodingKeys: String, CodingKey { case content; case toolCalls = "tool_calls" }
            }
            let message: ResponseMessage
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
        }
        let choices: [Choice]
    }

    private struct ErrorResponse: Decodable { let detail: String }

    private static let endpoint = URL(string: "https://www.limuleia.com/api/v1/chat/completions")!
    private static let keychainService = "com.adansonia.jarvis.credentials.v2"
    private static let keychainAccount = "limule-api-key"
    nonisolated(unsafe) private static var cachedKey: String?
    nonisolated(unsafe) private static var didLoadKey = false

    static var hasKey: Bool { apiKey() != nil }

    static var keyPreview: String? {
        guard let key = apiKey() else { return nil }
        return String(key.prefix(10)) + "..."
    }

    static func connect(apiKey candidate: String) async throws {
        let key = normalizedAPIKey(from: candidate)
        guard key.hasPrefix("lim_"), key.count > 8 else {
            throw ServiceError.invalidKey("le format attendu commence par lim_")
        }
        try await validate(apiKey: key)
        do { try save(key) } catch { throw ServiceError.storage(error.localizedDescription) }
    }

    static func disconnect() {
        cachedKey = nil
        didLoadKey = true
        try? SecureCredentialStore.delete(service: keychainService, account: keychainAccount)
    }

    /// Injectable so tests can supply a fake key without ever touching the
    /// real Keychain item this app's own saved API key lives in (`apiKey()`
    /// reads/writes that real item and must stay untouched by tests run on
    /// a real dev machine that may have a real key stored there).
    nonisolated(unsafe) static var apiKeyProvider: () -> String? = apiKey

    static func complete(messages: [Message]) async throws -> String {
        guard let key = apiKeyProvider() else { throw ServiceError.notConnected }
        let data = try await request(messages: messages, apiKey: key)
        guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let content = response.choices.first?.message.content,
              !content.isEmpty else {
            throw ServiceError.invalidResponse
        }
        return content
    }

    /// One assistant turn per tool call, one "tool" reply per result,
    /// looping until the model stops requesting tools (a plain text
    /// answer) or `maxRounds` is hit -- a backstop against a runaway loop,
    /// never expected to trigger in normal use. `execute` is the caller's
    /// dispatcher from a tool name + its raw JSON arguments string to a
    /// JSON result string; `toolResults` is returned alongside the final
    /// text so the caller can splice in a rich chat block (a screenshot, a
    /// file list) for a tool whose result deserves more than plain text,
    /// without the model itself needing to know that format exists.
    static func completeWithTools(
        messages initialMessages: [Message],
        toolsJSON: String,
        maxRounds: Int = 6,
        execute: (String, String) async -> String
    ) async throws -> (finalText: String, toolResults: [(name: String, resultJSON: String)]) {
        guard let key = apiKeyProvider() else { throw ServiceError.notConnected }
        var messages = initialMessages
        var collectedResults: [(name: String, resultJSON: String)] = []

        for _ in 0..<maxRounds {
            let data = try await request(messages: messages, apiKey: key, toolsJSON: toolsJSON)
            guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
                  let choice = response.choices.first else {
                throw ServiceError.invalidResponse
            }
            if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
                messages.append(Message(role: "assistant", content: choice.message.content, toolCalls: toolCalls))
                for call in toolCalls {
                    let result = await execute(call.function.name, call.function.arguments)
                    collectedResults.append((call.function.name, result))
                    messages.append(Message(role: "tool", content: result, toolCallID: call.id, name: call.function.name))
                }
                continue
            }
            guard let content = choice.message.content, !content.isEmpty else {
                throw ServiceError.invalidResponse
            }
            return (content, collectedResults)
        }
        throw ServiceError.tooManyToolRounds
    }

    private static func validate(apiKey: String) async throws {
        let data = try await request(
            messages: [Message(role: "user", content: "ping")],
            apiKey: apiKey
        )
        guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              response.choices.first?.message.content?.isEmpty == false else {
            throw ServiceError.invalidResponse
        }
    }

    /// One silent retry on a transient network-layer drop (a flaky Wi-Fi
    /// blip disconnecting mid-request is common and usually resolves on
    /// its own) -- never retried for an HTTP error status or a decode
    /// failure, both of which are real conditions the user should still
    /// see rather than have silently masked by a doomed second attempt.
    private static func request(messages: [Message], apiKey: String, toolsJSON: String? = nil) async throws -> Data {
        do {
            return try await performRequest(messages: messages, apiKey: apiKey, toolsJSON: toolsJSON)
        } catch let error as URLError where isTransientNetworkError(error) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return try await performRequest(messages: messages, apiKey: apiKey, toolsJSON: toolsJSON)
        }
    }

    private static func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Injectable so tests can exercise `completeWithTools`'s multi-round
    /// loop (assistant tool_calls -> tool reply -> next round) without a
    /// real network call, same pattern as `LimuleBridgeClient.transport`.
    nonisolated(unsafe) static var transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    private static func performRequest(messages: [Message], apiKey: String, toolsJSON: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authorizationHeader(for: apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONEncoder().encode(CompletionRequest(messages: messages))
        if let toolsJSON,
           let toolsData = toolsJSON.data(using: .utf8),
           var bodyObject = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let toolsArray = try? JSONSerialization.jsonObject(with: toolsData) as? [Any] {
            bodyObject["tools"] = toolsArray
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyObject)
        } else {
            request.httpBody = bodyData
        }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ServiceError.invalidKey("HTTP \(http.statusCode) - \(errorDetail(in: data))")
            }
            throw ServiceError.apiError(http.statusCode, errorDetail(in: data))
        }
        return data
    }

    static func authorizationHeader(for apiKey: String) -> String {
        "Bearer \(apiKey)"
    }

    static func normalizedAPIKey(from candidate: String) -> String {
        var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = value.firstIndex(of: "=") {
            let label = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            if label.caseInsensitiveCompare("LIMULE_API_KEY") == .orderedSame {
                value = String(value[value.index(after: separator)...])
            }
        }
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst("bearer ".count))
        }
        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        return value
            .filter { !$0.isWhitespace && !$0.isNewline }
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private static func errorDetail(in data: Data) -> String {
        (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.detail
            ?? String(data: data, encoding: .utf8)
            ?? "Erreur inconnue"
    }

    /// Not `private`: reused by `WorkspaceSyncService` so state-sync calls
    /// share this same cached lookup instead of reading Keychain twice.
    static func apiKey() -> String? {
        if didLoadKey { return cachedKey }
        didLoadKey = true
        guard let data = try? SecureCredentialStore.read(service: keychainService, account: keychainAccount),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        cachedKey = key
        return cachedKey
    }

    private static func save(_ key: String) throws {
        try SecureCredentialStore.write(Data(key.utf8), service: keychainService, account: keychainAccount)
        cachedKey = key
        didLoadKey = true
    }
}
