import Foundation
import Security
import VPNCore

public protocol VPNCredentialStore: Sendable {
    func password(for profileID: VPNProfileID) throws -> String
    func passwordWithoutUserInteraction(for profileID: VPNProfileID) throws -> String
    func savePassword(_ password: String, for profileID: VPNProfileID) throws
    func containsPassword(for profileID: VPNProfileID) throws -> Bool
    func deletePassword(for profileID: VPNProfileID) throws
    func serverCertificatePin(for profileID: VPNProfileID) throws -> String?
    func serverCertificatePinWithoutUserInteraction(for profileID: VPNProfileID) throws -> String?
    func saveServerCertificatePin(_ pin: String, for profileID: VPNProfileID) throws
    func containsServerCertificatePin(for profileID: VPNProfileID) throws -> Bool
    func deleteServerCertificatePin(for profileID: VPNProfileID) throws
    func deleteAllCredentials() throws
}

public extension VPNCredentialStore {
    func deleteCredentials(for profileID: VPNProfileID) throws {
        try deletePassword(for: profileID)
        try deleteServerCertificatePin(for: profileID)
    }
}

public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case missingPassword(profileID: String)
    case invalidStoredValue(kind: String)
    case keychainReadFailed(kind: String, status: OSStatus)
    case keychainWriteFailed(kind: String, status: OSStatus)
    case keychainDeleteFailed(kind: String, status: OSStatus)
    case keychainInteractionRequired(kind: String)
    case credentialVaultLocked
    case credentialVaultReadFailed(String)
    case credentialVaultWriteFailed(String)
    case credentialVaultCryptoFailed(String)
    case credentialVaultKeyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingPassword(let profileID):
            "Missing saved VPN password for profile \(profileID)"
        case .invalidStoredValue(let kind):
            "Invalid \(kind) value in Keychain"
        case .keychainReadFailed(let kind, let status):
            "Failed to read \(kind) from Keychain: \(status)"
        case .keychainWriteFailed(let kind, let status):
            "Failed to write \(kind) to Keychain: \(status)"
        case .keychainDeleteFailed(let kind, let status):
            "Failed to delete \(kind) from Keychain: \(status)"
        case .keychainInteractionRequired(let kind):
            "Keychain blocks silent access to \(kind). Open Settings, enter the password again, and Save so the app owns the Keychain item."
        case .credentialVaultLocked:
            "VPN credential vault is locked. Use Touch ID to unlock it."
        case .credentialVaultReadFailed(let message):
            "Failed to read VPN credential vault: \(message)"
        case .credentialVaultWriteFailed(let message):
            "Failed to write VPN credential vault: \(message)"
        case .credentialVaultCryptoFailed(let message):
            "Failed to decrypt VPN credential vault: \(message)"
        case .credentialVaultKeyUnavailable(let message):
            "VPN credential vault key is unavailable: \(message)"
        }
    }
}
