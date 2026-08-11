import Foundation
import Security
import LocalAuthentication

/// Encrypted-at-rest key storage. The Chrome extension used PBKDF2 + AES-256-GCM
/// with a user password; on iOS the equivalent (and stronger) primitive is the
/// hardware Keychain: the vault item is encrypted by the Secure Enclave and can
/// only be read after Face ID / Touch ID / device-passcode authentication.
/// Keys never leave the device and are excluded from iCloud/desktop backups
/// (`ThisDeviceOnly`), matching the extension's "keys live ONLY on this device".
enum Keychain {
    static let service = "io.ordnet.browser"
    static let vaultAccount = "ordplug_vault_v11"

    enum KeychainError: LocalizedError {
        case notFound
        case authFailed(String)
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound:            return "No wallet on this device yet."
            case .authFailed(let m):   return m
            case .unhandled(let s):    return "Keychain error (\(s))."
            }
        }
    }

    /// Save (or replace) the encrypted vault. Requires user presence to read back.
    static func saveVault(_ data: Data) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],           // Face ID / Touch ID with passcode fallback
            &accessError
        ) else {
            throw KeychainError.authFailed("Could not create keychain protection: \(accessError?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    /// Read the vault — this is what triggers the Face ID prompt.
    /// (The prompt text comes from LAContext.localizedReason — the old
    /// kSecUseOperationPrompt key is deprecated since iOS 14.)
    static func readVault(reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unhandled(status) }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.authFailed("Authentication was cancelled.")
        default:
            throw KeychainError.unhandled(status)
        }
    }

    static func vaultExists() -> Bool {
        // presence check WITHOUT triggering Face ID: a non-interactive LAContext
        // (kSecUseAuthenticationUIFail is deprecated since iOS 14)
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: false,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func deleteVault() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Re-authenticate the user (backup reveal, exactly like the extension's
    /// password gate before showing a WIF/phrase).
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            if !ok { throw KeychainError.authFailed("Authentication failed.") }
        } catch {
            throw KeychainError.authFailed("Authentication was cancelled.")
        }
    }
}
