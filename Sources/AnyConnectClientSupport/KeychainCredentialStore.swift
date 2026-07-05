import Foundation
import LocalAuthentication
import Security
import VPNCore

public struct KeychainCredentialStore: VPNCredentialStore, Sendable {
    public static let defaultService = "AnyConnectClient"

    public let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func password(for profileID: VPNProfileID) throws -> String {
        guard let password = try read(kind: .password, profileID: profileID, allowUserInteraction: true) else {
            throw CredentialStoreError.missingPassword(profileID: profileID.rawValue)
        }
        return password
    }

    public func passwordWithoutUserInteraction(for profileID: VPNProfileID) throws -> String {
        guard let password = try read(kind: .password, profileID: profileID, allowUserInteraction: false) else {
            throw CredentialStoreError.missingPassword(profileID: profileID.rawValue)
        }
        return password
    }

    public func savePassword(_ password: String, for profileID: VPNProfileID) throws {
        try save(password, kind: .password, profileID: profileID)
    }

    public func containsPassword(for profileID: VPNProfileID) throws -> Bool {
        try contains(kind: .password, profileID: profileID)
    }

    public func deletePassword(for profileID: VPNProfileID) throws {
        try delete(kind: .password, profileID: profileID)
    }

    public func serverCertificatePin(for profileID: VPNProfileID) throws -> String? {
        try read(kind: .serverCertificatePin, profileID: profileID, allowUserInteraction: true)
    }

    public func serverCertificatePinWithoutUserInteraction(for profileID: VPNProfileID) throws -> String? {
        try read(kind: .serverCertificatePin, profileID: profileID, allowUserInteraction: false)
    }

    public func saveServerCertificatePin(_ pin: String, for profileID: VPNProfileID) throws {
        try save(pin, kind: .serverCertificatePin, profileID: profileID)
    }

    public func containsServerCertificatePin(for profileID: VPNProfileID) throws -> Bool {
        try contains(kind: .serverCertificatePin, profileID: profileID)
    }

    public func deleteServerCertificatePin(for profileID: VPNProfileID) throws {
        try delete(kind: .serverCertificatePin, profileID: profileID)
    }

    public func deleteAllCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw CredentialStoreError.keychainDeleteFailed(kind: "credentials", status: status)
    }

    public static func accountName(for profileID: VPNProfileID, kind: KeychainCredentialKind) -> String {
        "\(profileID.rawValue).\(kind.rawValue)"
    }

    private func read(
        kind: KeychainCredentialKind,
        profileID: VPNProfileID,
        allowUserInteraction: Bool
    ) throws -> String? {
        var query = baseQuery(kind: kind, profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if allowUserInteraction {
            query[kSecUseAuthenticationContext as String] = Self.interactiveContext(
                reason: kind.operationPrompt(profileID: profileID)
            )
        } else {
            query[kSecUseAuthenticationContext as String] = Self.nonInteractiveContext()
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw CredentialStoreError.keychainInteractionRequired(kind: kind.label)
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainReadFailed(kind: kind.label, status: status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidStoredValue(kind: kind.label)
        }
        return value
    }

    private func contains(kind: KeychainCredentialKind, profileID: VPNProfileID) throws -> Bool {
        var query = baseQuery(kind: kind, profileID: profileID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = Self.nonInteractiveContext()

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            return false
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw CredentialStoreError.keychainInteractionRequired(kind: kind.label)
        }
        throw CredentialStoreError.keychainReadFailed(kind: kind.label, status: status)
    }

    private func save(_ value: String, kind: KeychainCredentialKind, profileID: VPNProfileID) throws {
        let data = Data(value.utf8)
        let query = baseQuery(kind: kind, profileID: profileID)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus != errSecDuplicateItem {
            throw CredentialStoreError.keychainWriteFailed(kind: kind.label, status: addStatus)
        }

        let updateAttributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw CredentialStoreError.keychainWriteFailed(kind: kind.label, status: updateStatus)
        }
    }

    private func delete(kind: KeychainCredentialKind, profileID: VPNProfileID) throws {
        let status = SecItemDelete(baseQuery(kind: kind, profileID: profileID) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw CredentialStoreError.keychainDeleteFailed(kind: kind.label, status: status)
    }

    private func baseQuery(kind: KeychainCredentialKind, profileID: VPNProfileID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.accountName(for: profileID, kind: kind)
        ]
    }

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func interactiveContext(reason: String) -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedCancelTitle = "Cancel"
        return context
    }
}

public enum KeychainCredentialKind: String, Sendable {
    case password
    case serverCertificatePin = "servercert"

    var label: String {
        switch self {
        case .password:
            "password"
        case .serverCertificatePin:
            "server certificate pin"
        }
    }

    func operationPrompt(profileID: VPNProfileID) -> String {
        switch self {
        case .password:
            "Read VPN password for profile \(profileID.rawValue)"
        case .serverCertificatePin:
            "Read VPN server certificate pin for profile \(profileID.rawValue)"
        }
    }
}
