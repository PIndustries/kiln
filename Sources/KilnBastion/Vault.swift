import Foundation
import KilnKit
#if canImport(Security)
import Security
import LocalAuthentication
#endif

/// No file fallback. Secrets are local, non-synchronizing Keychain items.
struct KeyVault {
    let namespace: String
    func store(_ data: Data, name: String) throws {
        #if canImport(Security)
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecUseAuthenticationContext as String:context,
            kSecAttrService as String:namespace,kSecAttrAccount as String:name,
            kSecValueData as String:data,kSecAttrSynchronizable as String:false,
            kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(query as CFDictionary,nil)
        guard status == errSecSuccess else { throw KilnError.message("Keychain save failed (OSStatus \(status)); no plaintext fallback") }
        #else
        throw KilnError.message("Secure key storage requires macOS Keychain in this version")
        #endif
    }
    func read(name: String) throws -> Data {
        #if canImport(Security)
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecUseAuthenticationContext as String:context,
            kSecAttrService as String:namespace,kSecAttrAccount as String:name,
            kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KilnError.message("Keychain key unavailable (OSStatus \(status)). Unlock/authorize the Keychain locally; no key was exported.")
        }
        return data
        #else
        throw KilnError.message("Secure key storage requires macOS Keychain in this version")
        #endif
    }
    func delete(name: String) throws {
        #if canImport(Security)
        let status = SecItemDelete([kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:namespace,kSecAttrAccount as String:name] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KilnError.message("Keychain deletion failed (OSStatus \(status))") }
        #else
        throw KilnError.message("Secure key storage requires macOS Keychain in this version")
        #endif
    }
}
