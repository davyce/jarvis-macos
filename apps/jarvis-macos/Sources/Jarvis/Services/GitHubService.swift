import Foundation

enum GitHubService {
    enum ServiceError: LocalizedError {
        case invalidToken
        case apiError(Int, String)
        case invalidResponse
        case storage(String)

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "Le jeton GitHub est invalide ou ne peut pas etre verifie."
            case .apiError(let code, let message): return "GitHub a repondu \(code) : \(message)"
            case .invalidResponse: return "Reponse GitHub illisible."
            case .storage(let message): return "Le jeton GitHub est valide, mais Jarvis ne peut pas l'enregistrer : \(message)"
            }
        }
    }

    struct User: Decodable {
        let login: String
        let avatar_url: URL?
        let name: String?
    }

    struct Repository: Decodable, Identifiable {
        let id: Int
        let full_name: String
        let `private`: Bool
        let html_url: URL
        let updated_at: Date?
    }

    private static let keychainService = "com.adansonia.jarvis.credentials.v2"
    private static let keychainAccount = "personal-access-token"
    nonisolated(unsafe) private static var cachedToken: String?
    nonisolated(unsafe) private static var didLoadToken = false

    static var hasToken: Bool { token() != nil }

    static func connect(token candidate: String) async throws -> User {
        let trimmed = normalizedToken(from: candidate)
        guard !trimmed.isEmpty else { throw ServiceError.invalidToken }
        let user: User = try await get("/user", token: trimmed)
        do { try saveToken(trimmed) } catch { throw ServiceError.storage(error.localizedDescription) }
        return user
    }

    static func currentUser() async throws -> User {
        guard let storedToken = token() else { throw ServiceError.invalidToken }
        return try await get("/user", token: storedToken)
    }

    static func repositories() async throws -> [Repository] {
        guard let storedToken = token() else { throw ServiceError.invalidToken }
        let account: User = try await get("/user", token: storedToken)
        async let accessible = paginatedRepositories(
            path: "/user/repos?affiliation=owner,collaborator,organization_member&sort=full_name&direction=asc",
            token: storedToken
        )
        async let publicOwned = paginatedRepositories(
            path: "/users/\(account.login)/repos?type=owner&sort=full_name&direction=asc",
            token: storedToken
        )

        var byID: [Int: Repository] = [:]
        for repository in try await accessible + publicOwned {
            byID[repository.id] = repository
        }
        return byID.values.sorted { $0.full_name.localizedCaseInsensitiveCompare($1.full_name) == .orderedAscending }
    }

    static func disconnect() {
        cachedToken = nil
        didLoadToken = true
        try? SecureCredentialStore.delete(service: keychainService, account: keychainAccount)
    }

    private static func token() -> String? {
        if didLoadToken { return cachedToken }
        didLoadToken = true
        guard let data = try? SecureCredentialStore.read(service: keychainService, account: keychainAccount),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        cachedToken = value
        return cachedToken
    }

    private static func saveToken(_ token: String) throws {
        try SecureCredentialStore.write(Data(token.utf8), service: keychainService, account: keychainAccount)
        cachedToken = token
        didLoadToken = true
    }

    static func normalizedToken(from candidate: String) -> String {
        var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)) }
        return value
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
            .filter { !$0.isWhitespace && !$0.isNewline }
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private static func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        guard let url = URL(string: "https://api.github.com\(path)") else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Erreur inconnue"
            throw ServiceError.apiError(http.statusCode, message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func paginatedRepositories(path: String, token: String) async throws -> [Repository] {
        var repositories: [Repository] = []
        for page in 1...100 {
            let separator = path.contains("?") ? "&" : "?"
            let batch: [Repository] = try await get("\(path)\(separator)per_page=100&page=\(page)", token: token)
            repositories.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return repositories
    }
}
