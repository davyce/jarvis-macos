import CryptoKit
import Foundation
import Observation

struct GoogleOAuthConfiguration: Decodable {
    struct InstalledApplication: Decodable {
        let clientID: String
        let clientSecret: String?
        let projectID: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case projectID = "project_id"
        }
    }

    let installed: InstalledApplication
}

@Observable @MainActor
final class LimuleMailService {
    private struct Tokens: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let email: String
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private struct GoogleProfile: Decodable { let email: String }
    private struct GmailList: Decodable { let resultSizeEstimate: Int? }
    private struct GoogleError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private static let keychainService = "com.adansonia.jarvis.credentials.v2"
    private static let tokensAccount = "oauth-tokens"
    private static let clientSecretAccount = "google-oauth-client-secret"
    private static let clientDefaultsKey = "jarvis.google.oauth.client-id"
    private static let projectDefaultsKey = "jarvis.google.oauth.project-id"
    private static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send"
    ]

    var email: String?
    var gmailConnected = false
    var inboxEstimate: Int?
    var isLoading = false
    var errorMessage: String?
    var hasClientID: Bool { Self.storedClientID() != nil }
    var googleProjectID: String? { UserDefaults.standard.string(forKey: Self.projectDefaultsKey) }

    @discardableResult
    func importGoogleConfiguration(_ data: Data) throws -> String {
        let configuration: GoogleOAuthConfiguration
        do {
            configuration = try JSONDecoder().decode(GoogleOAuthConfiguration.self, from: data)
        } catch {
            throw MailError.message("Ce fichier n'est pas une configuration OAuth Google de type Application de bureau.")
        }

        let projectID = configuration.installed.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = configuration.installed.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty, clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw MailError.message("La configuration OAuth Google est incomplete.")
        }
        guard !projectID.localizedCaseInsensitiveContains("limule") else {
            throw MailError.message("Ce fichier appartient au projet Google Cloud Limule IA. Selectionne le projet Jarvis, puis telecharge son fichier OAuth JSON.")
        }

        UserDefaults.standard.set(clientID, forKey: Self.clientDefaultsKey)
        UserDefaults.standard.set(projectID, forKey: Self.projectDefaultsKey)
        if let clientSecret = configuration.installed.clientSecret, !clientSecret.isEmpty {
            guard Self.saveKeychain(Data(clientSecret.utf8), account: Self.clientSecretAccount) else {
                throw MailError.message("Le secret OAuth Google n'a pas pu etre enregistre dans le Trousseau.")
            }
        }
        errorMessage = nil
        return projectID
    }

    func restore() async {
        guard let tokens = Self.storedTokens() else {
            email = nil
            gmailConnected = false
            errorMessage = nil
            return
        }
        email = tokens.email
        gmailConnected = true
        await refreshGmail()
    }

    func refreshGmail() async {
        guard gmailConnected else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            inboxEstimate = try await fetchInboxEstimate()
            errorMessage = nil
        } catch {
            inboxEstimate = nil
            errorMessage = error.localizedDescription
        }
    }

    func connectGmail(clientID candidate: String? = nil) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let supplied = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientID = supplied?.isEmpty == false ? supplied! : Self.storedClientID()
            guard let clientID, clientID.hasSuffix(".apps.googleusercontent.com") else {
                throw MailError.message("Importe le fichier OAuth JSON du projet Google Cloud Jarvis.")
            }
            guard let projectID = googleProjectID,
                  !projectID.localizedCaseInsensitiveContains("limule") else {
                UserDefaults.standard.removeObject(forKey: Self.clientDefaultsKey)
                UserDefaults.standard.removeObject(forKey: Self.projectDefaultsKey)
                throw MailError.message("Configuration Limule bloquee. Importe le fichier OAuth JSON du projet Google Cloud Jarvis.")
            }
            if supplied?.isEmpty == false {
                throw MailError.message("Pour eviter une mauvaise configuration, importe le fichier OAuth JSON complet du projet Jarvis.")
            }

            let server = try await OAuthLoopbackServer.start()
            let verifier = Self.randomURLSafeString(byteCount: 48)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
            let state = Self.randomURLSafeString(byteCount: 24)

            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: server.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]
            guard let authorizationURL = components.url else { throw MailError.invalidResponse }
            let callback = try await server.receiveCallback(opening: authorizationURL)
            let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard query.first(where: { $0.name == "state" })?.value == state else { throw MailError.invalidState }
            if let oauthError = query.first(where: { $0.name == "error" })?.value {
                throw MailError.message("Google a refuse l'autorisation : \(oauthError)")
            }
            guard let code = query.first(where: { $0.name == "code" })?.value else { throw MailError.invalidResponse }

            let tokenResponse = try await exchangeCode(code, clientID: clientID, verifier: verifier, redirectURI: server.redirectURI)
            let profile = try await fetchProfile(accessToken: tokenResponse.access_token)
            let refreshToken = tokenResponse.refresh_token ?? Self.storedTokens()?.refreshToken
            guard let refreshToken, !refreshToken.isEmpty else {
                throw MailError.message("Google n'a pas fourni de jeton de renouvellement.")
            }

            let tokens = Tokens(
                accessToken: tokenResponse.access_token,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(tokenResponse.expires_in),
                email: profile.email
            )
            guard let encoded = try? JSONEncoder().encode(tokens),
                  Self.saveKeychain(encoded, account: Self.tokensAccount) else {
                throw MailError.message("Les jetons Gmail n'ont pas pu etre enregistres dans le Trousseau.")
            }
            email = profile.email
            gmailConnected = true
            inboxEstimate = try await fetchInboxEstimate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectGmail() async {
        isLoading = true
        defer { isLoading = false }
        if let tokens = Self.storedTokens() {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formData(["token": tokens.refreshToken])
            _ = try? await URLSession.shared.data(for: request)
        }
        Self.deleteKeychain(account: Self.tokensAccount)
        email = nil
        gmailConnected = false
        inboxEstimate = nil
    }

    private func fetchInboxEstimate() async throws -> Int {
        let accessToken = try await validAccessToken()
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [URLQueryItem(name: "maxResults", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MailError.google(data) }
        return try JSONDecoder().decode(GmailList.self, from: data).resultSizeEstimate ?? 0
    }

    private func validAccessToken() async throws -> String {
        guard var tokens = Self.storedTokens(),
              let clientID = Self.storedClientID() else { throw MailError.notConnected }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = [
            "client_id": clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = Self.storedClientSecret() { values["client_secret"] = clientSecret }
        request.httpBody = Self.formData(values)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MailError.google(data) }
        let refreshed = try JSONDecoder().decode(TokenResponse.self, from: data)
        tokens = Tokens(
            accessToken: refreshed.access_token,
            refreshToken: tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(refreshed.expires_in),
            email: tokens.email
        )
        // Best-effort persistence: this refresh happens silently in the
        // background (no user action in sight), so it must never pop a
        // blocking Keychain dialog -- `allowInteraction: false` makes a
        // stale-ACL write fail quietly instead. The freshly refreshed
        // token is still returned and used for this request either way;
        // if it couldn't be saved, the next call just refreshes again.
        if let encoded = try? JSONEncoder().encode(tokens) {
            _ = Self.saveKeychain(encoded, account: Self.tokensAccount, allowInteraction: false)
        }
        return tokens.accessToken
    }

    private func exchangeCode(_ code: String, clientID: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let clientSecret = Self.storedClientSecret() { values["client_secret"] = clientSecret }
        request.httpBody = Self.formData(values)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MailError.google(data) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchProfile(accessToken: String) async throws -> GoogleProfile {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MailError.google(data) }
        return try JSONDecoder().decode(GoogleProfile.self, from: data)
    }

    private static func storedTokens() -> Tokens? {
        guard let data = readKeychainData(account: tokensAccount) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func formData(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func storedClientID() -> String? {
        guard let value = UserDefaults.standard.string(forKey: clientDefaultsKey), !value.isEmpty else { return nil }
        return value
    }

    private static func storedClientSecret() -> String? {
        guard let data = readKeychainData(account: clientSecretAccount),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private static func readKeychainData(account: String) -> Data? {
        try? SecureCredentialStore.read(service: keychainService, account: account)
    }

    private static func saveKeychain(_ data: Data, account: String, allowInteraction: Bool = true) -> Bool {
        do {
            try SecureCredentialStore.write(data, service: keychainService, account: account, allowInteraction: allowInteraction)
            return true
        } catch {
            return false
        }
    }

    private static func deleteKeychain(account: String) {
        try? SecureCredentialStore.delete(service: keychainService, account: account)
    }

    private enum MailError: LocalizedError {
        case invalidState
        case invalidResponse
        case notConnected
        case message(String)

        static func google(_ data: Data) -> MailError {
            if let message = try? JSONDecoder().decode(GoogleError.self, from: data).error.message {
                return .message("Google : \(message)")
            }
            return .invalidResponse
        }

        var errorDescription: String? {
            switch self {
            case .invalidState: return "La verification de securite Google a echoue."
            case .invalidResponse: return "La reponse Gmail est illisible."
            case .notConnected: return "Gmail n'est pas connecte."
            case .message(let message): return message
            }
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
