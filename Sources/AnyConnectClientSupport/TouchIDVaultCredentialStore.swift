import CryptoKit
import Foundation
import LocalAuthentication
import Security
import VPNCore

public protocol CredentialVaultKeyStore: Sendable {
    func keyData(allowUserInteraction: Bool, createIfMissing: Bool) throws -> Data?
    func deleteKey() throws
}

public struct CredentialVaultKeychainKeyStore: CredentialVaultKeyStore, Sendable {
    public static let defaultAccount = "credential-vault-key"

    public let service: String
    public let account: String

    public init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func keyData(allowUserInteraction: Bool, createIfMissing: Bool) throws -> Data? {
        if let data = try readKeyData(allowUserInteraction: allowUserInteraction) {
            return data
        }

        guard createIfMissing else {
            return nil
        }

        let data = try Self.randomKeyData()
        try addKeyData(data)
        return data
    }

    public func deleteKey() throws {
        for account in [account, applicationGatedAccount] {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                continue
            }
            throw CredentialStoreError.keychainDeleteFailed(kind: "credential vault key", status: status)
        }
    }

    private func readKeyData(allowUserInteraction: Bool) throws -> Data? {
        if let data = try readBiometricKeyData(allowUserInteraction: allowUserInteraction) {
            return data
        }
        return try readApplicationGatedKeyData(allowUserInteraction: allowUserInteraction)
    }

    private func readBiometricKeyData(allowUserInteraction: Bool) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let context = LAContext()
        context.localizedReason = "Unlock VPN credential vault"
        context.localizedCancelTitle = "Cancel"
        if !allowUserInteraction {
            context.interactionNotAllowed = true
        }
        query[kSecUseAuthenticationContext as String] = context

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw CredentialStoreError.credentialVaultLocked
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainReadFailed(kind: "credential vault key", status: status)
        }
        guard let data = result as? Data, data.count == 32 else {
            throw CredentialStoreError.credentialVaultKeyUnavailable("stored key has invalid size")
        }
        return data
    }

    private func addKeyData(_ data: Data) throws {
        let status = try addBiometricKeyData(data)
        if status == errSecSuccess || status == errSecDuplicateItem {
            return
        }

        if status == errSecMissingEntitlement || status == Self.missingEntitlementStatus {
            try addApplicationGatedKeyData(data)
            return
        }

        throw CredentialStoreError.keychainWriteFailed(kind: "credential vault key", status: status)
    }

    private func addBiometricKeyData(_ data: Data) throws -> OSStatus {
        let access = try makeAccessControl()
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = access

        return SecItemAdd(query as CFDictionary, nil)
    }

    private func readApplicationGatedKeyData(allowUserInteraction: Bool) throws -> Data? {
        var presenceQuery = baseQuery(account: applicationGatedAccount)
        presenceQuery[kSecReturnAttributes as String] = true
        presenceQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var presenceResult: AnyObject?
        let presenceStatus = SecItemCopyMatching(presenceQuery as CFDictionary, &presenceResult)
        if presenceStatus == errSecItemNotFound {
            return nil
        }
        guard presenceStatus == errSecSuccess else {
            throw CredentialStoreError.keychainReadFailed(kind: "credential vault key", status: presenceStatus)
        }
        guard allowUserInteraction else {
            throw CredentialStoreError.credentialVaultLocked
        }

        try authorizeApplicationGatedKeyRead()

        var query = baseQuery(account: applicationGatedAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainReadFailed(kind: "credential vault key", status: status)
        }
        guard let data = result as? Data, data.count == 32 else {
            throw CredentialStoreError.credentialVaultKeyUnavailable("stored key has invalid size")
        }
        return data
    }

    private func addApplicationGatedKeyData(_ data: Data) throws {
        var query = baseQuery(account: applicationGatedAccount)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }
        if status != errSecDuplicateItem {
            throw CredentialStoreError.keychainWriteFailed(kind: "credential vault key", status: status)
        }

        let updateStatus = SecItemUpdate(
            baseQuery(account: applicationGatedAccount) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        throw CredentialStoreError.keychainWriteFailed(kind: "credential vault key", status: updateStatus)
    }

    private func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &error
        ) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown access control error"
            throw CredentialStoreError.credentialVaultKeyUnavailable(message)
        }
        return access
    }

    private func authorizeApplicationGatedKeyRead() throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            let message = policyError?.localizedDescription ?? "Touch ID is unavailable"
            throw CredentialStoreError.credentialVaultKeyUnavailable(message)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = AuthorizationResult()
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock VPN credential vault"
        ) { success, error in
            result.set(success: success, error: error)
            semaphore.signal()
        }
        semaphore.wait()

        guard result.success else {
            throw result.error.map(Self.authorizationError) ?? CredentialStoreError.credentialVaultLocked
        }
    }

    private static func authorizationError(_ error: Error) -> CredentialStoreError {
        guard let laError = error as? LAError else {
            return .credentialVaultLocked
        }

        switch laError.code {
        case .userCancel, .userFallback, .appCancel, .systemCancel:
            return .credentialVaultLocked
        default:
            return .credentialVaultKeyUnavailable(laError.localizedDescription)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private var applicationGatedAccount: String {
        "\(account).application-gated"
    }

    private static func randomKeyData() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.credentialVaultKeyUnavailable("random key generation failed: \(status)")
        }
        return data
    }

    private static let missingEntitlementStatus: OSStatus = -34018
}

private final class AuthorizationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSuccess = false
    private var storedError: Error?

    var success: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedSuccess
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func set(success: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        storedSuccess = success
        storedError = error
    }
}

public final class TouchIDVaultCredentialStore: VPNCredentialStore, @unchecked Sendable {
    public static func defaultURL() -> URL {
        FileVPNProfileSettingsStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("credential-vault.json")
    }

    private let url: URL
    private let keyStore: any CredentialVaultKeyStore
    private let legacyStore: (any VPNCredentialStore)?
    private let lock = NSLock()
    private var cache: VaultCache?

    public init(
        url: URL = TouchIDVaultCredentialStore.defaultURL(),
        keyStore: any CredentialVaultKeyStore = CredentialVaultKeychainKeyStore(),
        legacyStore: (any VPNCredentialStore)? = KeychainCredentialStore()
    ) {
        self.url = url
        self.keyStore = keyStore
        self.legacyStore = legacyStore
    }

    public func password(for profileID: VPNProfileID) throws -> String {
        if let password = try document(allowUserInteraction: true).profiles[profileID.rawValue]?.password {
            return password
        }
        if let password = try migratePasswordIfAvailable(for: profileID, allowUserInteraction: true) {
            return password
        }
        throw CredentialStoreError.missingPassword(profileID: profileID.rawValue)
    }

    public func passwordWithoutUserInteraction(for profileID: VPNProfileID) throws -> String {
        if let password = try document(allowUserInteraction: false).profiles[profileID.rawValue]?.password {
            return password
        }
        if let password = try migratePasswordIfAvailable(for: profileID, allowUserInteraction: false) {
            return password
        }
        throw CredentialStoreError.missingPassword(profileID: profileID.rawValue)
    }

    public func savePassword(_ password: String, for profileID: VPNProfileID) throws {
        try update(allowUserInteraction: true) { document in
            var profile = document.profiles[profileID.rawValue] ?? CredentialVaultProfile()
            profile.password = password
            document.profiles[profileID.rawValue] = profile
        }
    }

    public func containsPassword(for profileID: VPNProfileID) throws -> Bool {
        try document(allowUserInteraction: false).profiles[profileID.rawValue]?.password != nil
    }

    public func deletePassword(for profileID: VPNProfileID) throws {
        try update(allowUserInteraction: true) { document in
            guard var profile = document.profiles[profileID.rawValue] else {
                return
            }
            profile.password = nil
            document.profiles[profileID.rawValue] = profile.isEmpty ? nil : profile
        }
    }

    public func serverCertificatePin(for profileID: VPNProfileID) throws -> String? {
        if let pin = try document(allowUserInteraction: true).profiles[profileID.rawValue]?.serverCertificatePin {
            return pin
        }
        return try migrateServerCertificatePinIfAvailable(for: profileID, allowUserInteraction: true)
    }

    public func serverCertificatePinWithoutUserInteraction(for profileID: VPNProfileID) throws -> String? {
        if let pin = try document(allowUserInteraction: false).profiles[profileID.rawValue]?.serverCertificatePin {
            return pin
        }
        return try migrateServerCertificatePinIfAvailable(for: profileID, allowUserInteraction: false)
    }

    public func saveServerCertificatePin(_ pin: String, for profileID: VPNProfileID) throws {
        try update(allowUserInteraction: true) { document in
            var profile = document.profiles[profileID.rawValue] ?? CredentialVaultProfile()
            profile.serverCertificatePin = pin
            document.profiles[profileID.rawValue] = profile
        }
    }

    public func containsServerCertificatePin(for profileID: VPNProfileID) throws -> Bool {
        try document(allowUserInteraction: false).profiles[profileID.rawValue]?.serverCertificatePin != nil
    }

    public func deleteServerCertificatePin(for profileID: VPNProfileID) throws {
        try update(allowUserInteraction: true) { document in
            guard var profile = document.profiles[profileID.rawValue] else {
                return
            }
            profile.serverCertificatePin = nil
            document.profiles[profileID.rawValue] = profile.isEmpty ? nil : profile
        }
    }

    public func deleteAllCredentials() throws {
        clearCache()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw CredentialStoreError.credentialVaultWriteFailed(error.localizedDescription)
            }
        }
        try keyStore.deleteKey()
        try legacyStore?.deleteAllCredentials()
    }

    private func document(allowUserInteraction: Bool) throws -> CredentialVaultDocument {
        if let cache = cachedVault() {
            return cache.document
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }

        guard let keyData = try keyStore.keyData(allowUserInteraction: allowUserInteraction, createIfMissing: false) else {
            throw CredentialStoreError.credentialVaultKeyUnavailable("vault key is missing")
        }
        let document = try readDocument(keyData: keyData)
        setCache(VaultCache(keyData: keyData, document: document))
        return document
    }

    private func update(
        allowUserInteraction: Bool,
        _ body: (inout CredentialVaultDocument) throws -> Void
    ) throws {
        let keyData = try keyDataForWrite(allowUserInteraction: allowUserInteraction)
        var document: CredentialVaultDocument
        if let cache = cachedVault(), cache.keyData == keyData {
            document = cache.document
        } else if FileManager.default.fileExists(atPath: url.path) {
            document = try readDocument(keyData: keyData)
        } else {
            document = .empty
        }

        try body(&document)
        try writeDocument(document, keyData: keyData)
        setCache(VaultCache(keyData: keyData, document: document))
    }

    private func keyDataForWrite(allowUserInteraction: Bool) throws -> Data {
        if let cache = cachedVault() {
            return cache.keyData
        }
        guard let keyData = try keyStore.keyData(allowUserInteraction: allowUserInteraction, createIfMissing: true) else {
            throw CredentialStoreError.credentialVaultKeyUnavailable("vault key was not created")
        }
        return keyData
    }

    private func readDocument(keyData: Data) throws -> CredentialVaultDocument {
        do {
            let encryptedData = try Data(contentsOf: url)
            let encrypted = try JSONDecoder().decode(EncryptedCredentialVaultFile.self, from: encryptedData)
            guard encrypted.version == 1, encrypted.algorithm == "AES.GCM.256" else {
                throw CredentialStoreError.credentialVaultReadFailed("unsupported vault format")
            }

            guard let nonceData = Data(base64Encoded: encrypted.nonce),
                  let ciphertext = Data(base64Encoded: encrypted.ciphertext),
                  let tag = Data(base64Encoded: encrypted.tag)
            else {
                throw CredentialStoreError.credentialVaultReadFailed("invalid base64 payload")
            }

            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            return try JSONDecoder().decode(CredentialVaultDocument.self, from: plaintext)
        } catch let error as CredentialStoreError {
            throw error
        } catch {
            throw CredentialStoreError.credentialVaultCryptoFailed(error.localizedDescription)
        }
    }

    private func writeDocument(_ document: CredentialVaultDocument, keyData: Data) throws {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let plaintext = try JSONEncoder().encode(document)
            let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
            let encrypted = EncryptedCredentialVaultFile(
                version: 1,
                algorithm: "AES.GCM.256",
                nonce: sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                ciphertext: sealed.ciphertext.base64EncodedString(),
                tag: sealed.tag.base64EncodedString()
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(encrypted)
            data.append(0x0A)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw CredentialStoreError.credentialVaultWriteFailed(error.localizedDescription)
        }
    }

    private func migratePasswordIfAvailable(
        for profileID: VPNProfileID,
        allowUserInteraction: Bool
    ) throws -> String? {
        guard let legacyStore else {
            return nil
        }

        do {
            let password = allowUserInteraction
                ? try legacyStore.password(for: profileID)
                : try legacyStore.passwordWithoutUserInteraction(for: profileID)
            try savePassword(password, for: profileID)
            try? legacyStore.deletePassword(for: profileID)
            return password
        } catch CredentialStoreError.missingPassword {
            return nil
        }
    }

    private func migrateServerCertificatePinIfAvailable(
        for profileID: VPNProfileID,
        allowUserInteraction: Bool
    ) throws -> String? {
        guard let legacyStore else {
            return nil
        }

        do {
            let pin = allowUserInteraction
                ? try legacyStore.serverCertificatePin(for: profileID)
                : try legacyStore.serverCertificatePinWithoutUserInteraction(for: profileID)
            guard let pin else {
                return nil
            }
            try saveServerCertificatePin(pin, for: profileID)
            try? legacyStore.deleteServerCertificatePin(for: profileID)
            return pin
        } catch CredentialStoreError.missingPassword {
            return nil
        }
    }

    private func cachedVault() -> VaultCache? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    private func setCache(_ cache: VaultCache) {
        lock.lock()
        defer { lock.unlock() }
        self.cache = cache
    }

    private func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
    }
}

private struct VaultCache: Sendable {
    var keyData: Data
    var document: CredentialVaultDocument
}

private struct EncryptedCredentialVaultFile: Codable, Equatable, Sendable {
    var version: Int
    var algorithm: String
    var nonce: String
    var ciphertext: String
    var tag: String
}

private struct CredentialVaultDocument: Codable, Equatable, Sendable {
    var version: Int
    var profiles: [String: CredentialVaultProfile]

    static let empty = CredentialVaultDocument(version: 1, profiles: [:])
}

private struct CredentialVaultProfile: Codable, Equatable, Sendable {
    var password: String?
    var serverCertificatePin: String?

    var isEmpty: Bool {
        password == nil && serverCertificatePin == nil
    }
}
