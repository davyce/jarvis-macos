import Foundation

/// Client for Limule's `/api/v1/state/*` persistent-storage API (scope
/// `state`), used to keep Jarvis's conversations and projects in sync
/// across the user's machines. Authenticated with the same `lim_...` key
/// as `LimuleAPIService` -- a completely different system from LIMULE
/// Bridge (local HTTP, Keychain-shared token, no `lim_...` key involved).
///
/// Every call degrades to a thrown `ServiceError` rather than crashing;
/// callers (see `ProjectStore`) are expected to catch, never propagate to
/// the UI as a blocking alert, and keep local storage as the source of
/// truth regardless of sync outcome.
enum WorkspaceSyncService {
    enum ServiceError: LocalizedError {
        case notConnected
        case unauthorized
        case network(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Connecte d'abord la cle API Limule dans Connexions."
            case .unauthorized:
                return "La cle API Limule n'a pas la permission de synchroniser (scope \u{201C}state\u{201D})."
            case .network(let message):
                return "Synchronisation Limule impossible : \(message)"
            case .invalidResponse:
                return "Reponse de synchronisation illisible."
            }
        }
    }

    /// One item in the `"conversations"` namespace: the conversation's own
    /// metadata plus its full message list, since Limule's state store has
    /// no separate "messages" endpoint -- a conversation is one JSON blob.
    struct ConversationPayload: Codable, Equatable {
        var conversation: Conversation
        var messages: [CommandEntry]
    }

    private static let baseURL = URL(string: "https://www.limuleia.com/api/v1/state")!

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Injectable for tests -- avoids a real network call. Returns the raw
    /// body and the HTTP response; callers interpret status codes.
    nonisolated(unsafe) static var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        return (data, http)
    }

    // MARK: - Generic namespace/item calls

    static func putItem<T: Encodable>(namespace: String, itemKey: String, value: T) async throws {
        var request = try authorizedRequest(namespace: namespace, itemKey: itemKey, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(value)
        let (_, http) = try await transport(request)
        try checkStatus(http)
    }

    static func getItem<T: Decodable>(namespace: String, itemKey: String, as type: T.Type) async throws -> T? {
        let request = try authorizedRequest(namespace: namespace, itemKey: itemKey, method: "GET")
        let (data, http) = try await transport(request)
        if http.statusCode == 404 { return nil }
        try checkStatus(http)
        return try decoder.decode(ItemEnvelope<T>.self, from: data).value
    }

    static func getNamespace<T: Decodable>(_ namespace: String, as type: T.Type) async throws -> [String: T] {
        let request = try authorizedRequest(namespace: namespace, itemKey: nil, method: "GET")
        let (data, http) = try await transport(request)
        try checkStatus(http)
        return try decoder.decode(NamespaceEnvelope<T>.self, from: data).items
    }

    static func deleteItem(namespace: String, itemKey: String) async throws {
        let request = try authorizedRequest(namespace: namespace, itemKey: itemKey, method: "DELETE")
        let (_, http) = try await transport(request)
        // A missing item is already the desired end state -- idempotent delete.
        if http.statusCode == 404 { return }
        try checkStatus(http)
    }

    // MARK: - Helpers

    /// Injectable for tests -- `LimuleAPIService.apiKey()` caches from a real
    /// Keychain read on first call for the life of the process, so tests
    /// need a way to simulate "no key"/"has key" without touching it.
    nonisolated(unsafe) static var apiKeyProvider: () -> String? = LimuleAPIService.apiKey

    private static func authorizedRequest(namespace: String, itemKey: String?, method: String) throws -> URLRequest {
        guard let key = apiKeyProvider() else { throw ServiceError.notConnected }
        var url = baseURL.appendingPathComponent(namespace)
        if let itemKey { url = url.appendingPathComponent(itemKey) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(LimuleAPIService.authorizationHeader(for: key), forHTTPHeaderField: "Authorization")
        return request
    }

    private static func checkStatus(_ http: HTTPURLResponse) throws {
        if http.statusCode == 401 || http.statusCode == 403 { throw ServiceError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.network("HTTP \(http.statusCode)")
        }
    }
}

private struct ItemEnvelope<T: Decodable>: Decodable { let value: T }
private struct NamespaceEnvelope<T: Decodable>: Decodable { let items: [String: T] }

/// Pure, independently-testable merge logic -- last-write-wins for whole
/// records, but a union-by-id merge for conversation messages so two
/// devices diverging before a sync can never silently lose chat history.
enum WorkspaceMerge {
    static func mergeProjects(local: [JarvisProject], remote: [String: JarvisProject]) -> [JarvisProject] {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for (id, remoteProject) in remote {
            if let localProject = byID[id] {
                if remoteProject.updatedAt > localProject.updatedAt {
                    byID[id] = remoteProject
                }
            } else {
                byID[id] = remoteProject
            }
        }
        return byID.values.sorted { $0.order < $1.order }
    }

    static func mergeConversation(
        local: WorkspaceSyncService.ConversationPayload?,
        remote: WorkspaceSyncService.ConversationPayload?
    ) -> WorkspaceSyncService.ConversationPayload? {
        guard let remote else { return local }
        guard let local else { return remote }

        let conversation = remote.conversation.updatedAt > local.conversation.updatedAt
            ? remote.conversation
            : local.conversation

        var byID = Dictionary(uniqueKeysWithValues: local.messages.map { ($0.id, $0) })
        for message in remote.messages where byID[message.id] == nil {
            byID[message.id] = message
        }
        let messages = byID.values.sorted { $0.createdAt < $1.createdAt }

        return WorkspaceSyncService.ConversationPayload(conversation: conversation, messages: messages)
    }
}
