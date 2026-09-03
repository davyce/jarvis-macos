import Foundation

/// HTTP client for LIMULE Bridge (`http://127.0.0.1:8765`), the local
/// control server bundled with LIMULE's own native Mac app. Completely
/// separate auth from `LimuleAPIService`/`WorkspaceSyncService` (cloud,
/// `lim_...` key): this is a shared Keychain token, read-only, and the
/// server only exists (and only accepts requests) when LIMULE's own app
/// has run on this Mac at least once.
enum LimuleBridgeClient {
    enum ServiceError: LocalizedError {
        case tokenUnavailable
        case notReachable(String)
        case unauthorized
        case originRejected
        case missingContentType
        case payloadTooLarge
        case headersTooLarge
        case businessError(code: String, message: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .tokenUnavailable:
                return "LIMULE Bridge n'est pas disponible sur ce Mac (jeton introuvable dans le Trousseau)."
            case .notReachable(let detail):
                return "LIMULE Bridge ne repond pas : \(detail)"
            case .unauthorized:
                return "Jeton LIMULE Bridge invalide ou expire."
            case .originRejected:
                return "LIMULE Bridge a rejete la requete (en-tete Origin present)."
            case .missingContentType:
                return "En-tete Content-Type manquant."
            case .payloadTooLarge:
                return "Donnees trop volumineuses pour LIMULE Bridge."
            case .headersTooLarge:
                return "En-tetes trop volumineux pour LIMULE Bridge."
            case .businessError(_, let message):
                return message
            case .invalidResponse:
                return "Reponse de LIMULE Bridge illisible."
            }
        }
    }

    struct ActionResult {
        let succeeded: Bool
        let message: String
        let data: Data?
    }

    private static let baseURL = URL(string: "http://127.0.0.1:8765")!

    /// Injectable for tests -- avoids a real network call to a daemon that
    /// may not even be running in CI.
    nonisolated(unsafe) static var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        return (data, http)
    }

    /// Injectable for tests -- `LimuleBridgeAuthentication.token()` reads a
    /// real Keychain item.
    nonisolated(unsafe) static var tokenProvider: () -> String? = LimuleBridgeAuthentication.token

    static func perform(_ action: LimuleBridgeAction) async throws -> ActionResult {
        guard let token = tokenProvider() else { throw ServiceError.tokenUnavailable }

        var url = baseURL.appendingPathComponent(action.path)
        if !action.queryItems.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = action.queryItems.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.httpMethod = action.method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Bridge rejects any request bearing an Origin header (anti-browser/
        // anti-exfiltration) -- URLSession never sends one for a native app,
        // so nothing to configure there.
        if action.method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: action.jsonBody ?? [:])
        }

        let (data, http) = try await transport(request)
        try checkStatus(http, data: data)

        if action.isBinaryResponse {
            return ActionResult(succeeded: true, message: action.auditSummary, data: data)
        }

        // Business-logic failures come back as 200 with {"error","message"}.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["error"] as? String {
            let message = json["message"] as? String ?? code
            throw ServiceError.businessError(code: code, message: message)
        }
        return ActionResult(succeeded: true, message: action.auditSummary, data: data)
    }

    /// A non-2xx status doesn't necessarily mean Bridge is unreachable --
    /// e.g. a 422 is Bridge validating the request and rejecting it (an
    /// unsupported app for `createDocument`, a malformed field...), with
    /// the actual reason in its JSON body. Folding that into "HTTP 422"
    /// under `.notReachable` was actively misleading (surfaced verbatim in
    /// the Suivi audit trail and in Jarvis's own replies as "LIMULE Bridge
    /// ne repond pas"), so any status not otherwise mapped first tries to
    /// recover Bridge's own `message` before falling back to the generic
    /// "HTTP <code>" text.
    private static func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200: return
        case 401: throw ServiceError.unauthorized
        case 403: throw ServiceError.originRejected
        case 415: throw ServiceError.missingContentType
        case 413: throw ServiceError.payloadTooLarge
        case 431: throw ServiceError.headersTooLarge
        default:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                let code = json["error"] as? String ?? "HTTP \(http.statusCode)"
                throw ServiceError.businessError(code: code, message: message)
            }
            throw ServiceError.notReachable("HTTP \(http.statusCode)")
        }
    }
}
