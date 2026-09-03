import Foundation
import LocalAuthentication
import Security

enum SecureCredentialStore {
    struct StoreError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Trousseau macOS (\(operation)) : \(detail) [\(status)]"
        }
    }

    static func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // `LAContext.interactionNotAllowed` alone only silences a
        // biometric/passcode prompt on `kSecAttrAccessControl`-protected
        // items; it does nothing for the classic "<app> wants to access
        // your keychain -- Always Allow / Deny" ACL dialog every plain
        // generic-password item here actually uses (e.g. after an ad-hoc
        // rebuild leaves the item's trusted-application ACL bound to a
        // binary that no longer matches). `kSecUseAuthenticationUIFail` is
        // the flag that actually suppresses that dialog, failing the read
        // immediately with `errSecInteractionNotAllowed` instead -- every
        // caller already treats a failed read as "not connected" via
        // `try?`, so this turns a wall of stacked system prompts into a
        // normal "reconnect" state.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError(operation: "lecture", status: status) }
        return item as? Data
    }

    /// - Parameter allowInteraction: `true` (the default) permits the OS to
    ///   show its "keychain wants to use your confidential information..."
    ///   dialog if the item's ACL doesn't already trust this build -- fine
    ///   for a write directly caused by the user's own action (entering a
    ///   key, connecting an account), where a prompt has clear context.
    ///   Pass `false` for a write that can happen in the background with no
    ///   user action in sight (e.g. silently re-saving a refreshed OAuth
    ///   token): without this, a stale ACL from a prior build/signing
    ///   identity turned every automatic token refresh into an unexplained,
    ///   recurring system dialog -- it should just fail quietly instead,
    ///   the same as a suppressed `read()`, and simply be retried on the
    ///   next refresh.
    static func write(_ data: Data, service: String, account: String, allowInteraction: Bool = true) throws {
        var query = baseQuery(service: service, account: account)
        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }

        // Any failure other than "doesn't exist yet" -- including a stale
        // per-app ACL left over from a previous ad-hoc-signed build, whose
        // cdhash no longer matches the currently running binary and so
        // can't silently update the item -- is resolved by replacing the
        // item outright. A fresh SecItemAdd re-binds trust to whichever
        // build is running right now, instead of the app repeatedly asking
        // the OS to authorize a build that no longer exists.
        if updateStatus != errSecItemNotFound {
            _ = SecItemDelete(query as CFDictionary)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError(operation: "enregistrement", status: addStatus) }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError(operation: "suppression", status: status)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
