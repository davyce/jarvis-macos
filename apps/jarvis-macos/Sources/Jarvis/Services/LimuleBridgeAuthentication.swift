import Foundation
import LocalAuthentication
import Security

/// Read-only access to the LIMULE Bridge auth token, shared via a Keychain
/// Access Group with LIMULE's own native app. Jarvis must never generate a
/// token here -- only LIMULE's own app creates one (see `BridgeAuthentication
/// .swift` in the limule repo, which this mirrors on the read side only).
enum LimuleBridgeAuthentication {
    private static let service = "com.adansonia.limule.bridge-auth"
    private static let account = "local-api-token-v2"
    private static let accessGroup = "264EZSM3VZ.com.adansonia.limule.shared"

    /// Per-process cache. Without it, every single Bridge call would
    /// re-read the Keychain and could re-trigger a system prompt -- LIMULE's
    /// own code has a comment documenting exactly this cost (up to 10
    /// prompts for a 5-action task before they added this cache). The token
    /// never changes mid-run, so one read attempt per launch is enough.
    nonisolated(unsafe) private static var cachedToken: String?
    nonisolated(unsafe) private static var didAttemptRead = false

    static func token() -> String? {
        if let cachedToken { return cachedToken }
        guard !didAttemptRead else { return nil }
        didAttemptRead = true
        cachedToken = read()
        return cachedToken
    }

    /// Test hook: forces the next `token()` call to re-read instead of
    /// returning a cached (possibly nil) result.
    static func resetCache() {
        cachedToken = nil
        didAttemptRead = false
    }

    private static func read() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // A Bridge call must never suspend Jarvis behind a Keychain prompt --
        // a failure to read the token just means Bridge is unavailable.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
