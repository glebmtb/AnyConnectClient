import CryptoKit
import Foundation
import VPNCore

public final class UnsafeLocalCredentialStore: VPNCredentialStore, @unchecked Sendable {
    public static func defaultURL() -> URL {
        FileVPNProfileSettingsStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("unsafe-credential-vault.json")
    }

    private let url: URL
    private let lock = NSLock()
    private var cache: UnsafeCredentialDocument?

    public init(url: URL = UnsafeLocalCredentialStore.defaultURL()) {
        self.url = url
    }

    public func password(for profileID: VPNProfileID) throws -> String {
        guard let password = try document().profiles[profileID.rawValue]?.password else {
            throw CredentialStoreError.missingPassword(profileID: profileID.rawValue)
        }
        return password
    }

    public func passwordWithoutUserInteraction(for profileID: VPNProfileID) throws -> String {
        try password(for: profileID)
    }

    public func savePassword(_ password: String, for profileID: VPNProfileID) throws {
        try update { document in
            var profile = document.profiles[profileID.rawValue] ?? UnsafeCredentialProfile()
            profile.password = password
            document.profiles[profileID.rawValue] = profile
        }
    }

    public func containsPassword(for profileID: VPNProfileID) throws -> Bool {
        try document().profiles[profileID.rawValue]?.password != nil
    }

    public func deletePassword(for profileID: VPNProfileID) throws {
        try update { document in
            guard var profile = document.profiles[profileID.rawValue] else {
                return
            }
            profile.password = nil
            document.profiles[profileID.rawValue] = profile.isEmpty ? nil : profile
        }
    }

    public func serverCertificatePin(for profileID: VPNProfileID) throws -> String? {
        try document().profiles[profileID.rawValue]?.serverCertificatePin
    }

    public func serverCertificatePinWithoutUserInteraction(for profileID: VPNProfileID) throws -> String? {
        try serverCertificatePin(for: profileID)
    }

    public func saveServerCertificatePin(_ pin: String, for profileID: VPNProfileID) throws {
        try update { document in
            var profile = document.profiles[profileID.rawValue] ?? UnsafeCredentialProfile()
            profile.serverCertificatePin = pin
            document.profiles[profileID.rawValue] = profile
        }
    }

    public func containsServerCertificatePin(for profileID: VPNProfileID) throws -> Bool {
        try document().profiles[profileID.rawValue]?.serverCertificatePin != nil
    }

    public func deleteServerCertificatePin(for profileID: VPNProfileID) throws {
        try update { document in
            guard var profile = document.profiles[profileID.rawValue] else {
                return
            }
            profile.serverCertificatePin = nil
            document.profiles[profileID.rawValue] = profile.isEmpty ? nil : profile
        }
    }

    public func deleteAllCredentials() throws {
        clearCache()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CredentialStoreError.credentialVaultWriteFailed(error.localizedDescription)
        }
    }

    private func document() throws -> UnsafeCredentialDocument {
        if let cache = cachedDocument() {
            return cache
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }

        let document = try readDocument()
        setCache(document)
        return document
    }

    private func update(_ body: (inout UnsafeCredentialDocument) throws -> Void) throws {
        var document = try self.document()
        try body(&document)
        try writeDocument(document)
        setCache(document)
    }

    private func readDocument() throws -> UnsafeCredentialDocument {
        do {
            let encryptedData = try Data(contentsOf: url)
            let encrypted = try JSONDecoder().decode(UnsafeEncryptedCredentialFile.self, from: encryptedData)
            guard encrypted.version == 1, encrypted.algorithm == "AES.GCM.256.app-key" else {
                throw CredentialStoreError.credentialVaultReadFailed("unsupported unsafe vault format")
            }

            guard let nonceData = Data(base64Encoded: encrypted.nonce),
                  let ciphertext = Data(base64Encoded: encrypted.ciphertext),
                  let tag = Data(base64Encoded: encrypted.tag)
            else {
                throw CredentialStoreError.credentialVaultReadFailed("invalid unsafe vault payload")
            }

            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: Self.appKey)
            return try JSONDecoder().decode(UnsafeCredentialDocument.self, from: plaintext)
        } catch let error as CredentialStoreError {
            throw error
        } catch {
            throw CredentialStoreError.credentialVaultCryptoFailed(error.localizedDescription)
        }
    }

    private func writeDocument(_ document: UnsafeCredentialDocument) throws {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let plaintext = try JSONEncoder().encode(document)
            let sealed = try AES.GCM.seal(plaintext, using: Self.appKey)
            let encrypted = UnsafeEncryptedCredentialFile(
                version: 1,
                algorithm: "AES.GCM.256.app-key",
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

    private func cachedDocument() -> UnsafeCredentialDocument? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    private func setCache(_ document: UnsafeCredentialDocument) {
        lock.lock()
        defer { lock.unlock() }
        cache = document
    }

    private func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
    }

    private static let appKey = SymmetricKey(
        data: Data(SHA256.hash(data: Data("AnyConnectClient unsafe local credential storage v1".utf8)))
    )
}

private struct UnsafeEncryptedCredentialFile: Codable, Equatable, Sendable {
    var version: Int
    var algorithm: String
    var nonce: String
    var ciphertext: String
    var tag: String
}

private struct UnsafeCredentialDocument: Codable, Equatable, Sendable {
    var version: Int
    var profiles: [String: UnsafeCredentialProfile]

    static let empty = UnsafeCredentialDocument(version: 1, profiles: [:])
}

private struct UnsafeCredentialProfile: Codable, Equatable, Sendable {
    var password: String?
    var serverCertificatePin: String?

    var isEmpty: Bool {
        password == nil && serverCertificatePin == nil
    }
}
