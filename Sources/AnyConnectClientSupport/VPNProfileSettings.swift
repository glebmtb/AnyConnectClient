import Foundation
import VPNCore

public struct VPNProfileSettings: Codable, Equatable, Sendable {
    public var id: VPNProfileID
    public var displayName: String
    public var server: String
    public var username: String
    public var authGroup: String?
    public var socksHost: String
    public var socksPort: Int
    public var autoStartOnLaunch: Bool
    public var credentialStorageMode: CredentialStorageMode

    public init(
        id: VPNProfileID,
        displayName: String,
        server: String,
        username: String,
        authGroup: String?,
        socksHost: String,
        socksPort: Int,
        autoStartOnLaunch: Bool = false,
        credentialStorageMode: CredentialStorageMode = .touchIDVault
    ) {
        self.id = id
        self.displayName = displayName
        self.server = server
        self.username = username
        self.authGroup = authGroup
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.autoStartOnLaunch = autoStartOnLaunch
        self.credentialStorageMode = credentialStorageMode
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case server
        case username
        case authGroup
        case socksHost
        case socksPort
        case autoStartOnLaunch
        case credentialStorageMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(VPNProfileID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        server = try container.decode(String.self, forKey: .server)
        username = try container.decode(String.self, forKey: .username)
        authGroup = try container.decodeIfPresent(String.self, forKey: .authGroup)
        socksHost = try container.decode(String.self, forKey: .socksHost)
        socksPort = try container.decode(Int.self, forKey: .socksPort)
        autoStartOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoStartOnLaunch) ?? false
        credentialStorageMode = try container.decodeIfPresent(
            CredentialStorageMode.self,
            forKey: .credentialStorageMode
        ) ?? .touchIDVault
    }

    public static var emptyDefault: VPNProfileSettings {
        VPNProfileSettings(
            id: "humo",
            displayName: "humo",
            server: "",
            username: "",
            authGroup: nil,
            socksHost: "127.0.0.1",
            socksPort: 11084
        )
    }

    public func makeProfile(serverCertificatePin: String?) throws -> VPNProfile {
        try VPNProfile(
            id: id,
            displayName: displayName,
            vpnProtocol: .anyconnect,
            server: server,
            username: username,
            authGroup: authGroup,
            socksEndpoint: SocksEndpoint(host: socksHost, port: socksPort),
            serverCertificatePin: serverCertificatePin
        )
    }
}

public enum CredentialStorageMode: String, Codable, Equatable, Sendable {
    case touchIDVault
    case unsafeLocal
}

public protocol VPNProfileSettingsStore: Sendable {
    func loadProfileSettingsDocument() throws -> VPNProfileSettingsDocument?
    func saveProfileSettingsDocument(_ document: VPNProfileSettingsDocument) throws
    func loadSelectedProfileSettings() throws -> VPNProfileSettings?
    func saveSelectedProfileSettings(_ settings: VPNProfileSettings) throws
    func selectProfile(id: VPNProfileID) throws
}

public enum ProfileSettingsStoreError: Error, LocalizedError, Equatable {
    case invalidDocument(String)
    case duplicateProfileID(VPNProfileID)
    case duplicateSocksEndpoint(SocksEndpoint)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let path):
            "Invalid profile settings document: \(path)"
        case .duplicateProfileID(let profileID):
            "Profile id \(profileID.rawValue) is already used."
        case .duplicateSocksEndpoint(let endpoint):
            endpoint.host == "127.0.0.1"
                ? "SOCKS port \(endpoint.port) is already used by another profile. Choose another port."
                : "SOCKS endpoint \(endpoint.address) is already used by another profile. Choose another endpoint."
        case .writeFailed(let path):
            "Failed to write profile settings document: \(path)"
        }
    }
}

public struct FileVPNProfileSettingsStore: VPNProfileSettingsStore, Sendable {
    public let url: URL

    public init(url: URL = Self.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AnyConnectClient", isDirectory: true)
            .appendingPathComponent("profile-settings.json")
    }

    public func loadSelectedProfileSettings() throws -> VPNProfileSettings? {
        guard let document = try loadProfileSettingsDocument() else {
            return nil
        }
        if document.profiles.isEmpty {
            return nil
        }
        guard let selected = document.selectedProfile else {
            throw ProfileSettingsStoreError.invalidDocument(url.path)
        }
        return selected
    }

    public func saveSelectedProfileSettings(_ settings: VPNProfileSettings) throws {
        var document = try loadProfileSettingsDocument() ?? VPNProfileSettingsDocument(
            selectedProfileID: settings.id,
            profiles: []
        )

        if let index = document.profiles.firstIndex(where: { $0.id == settings.id }) {
            document.profiles[index] = settings
        } else {
            document.profiles.append(settings)
        }
        document.selectedProfileID = settings.id
        try saveProfileSettingsDocument(document)
    }

    public func selectProfile(id: VPNProfileID) throws {
        guard var document = try loadProfileSettingsDocument(),
              document.profiles.contains(where: { $0.id == id }) else {
            throw ProfileSettingsStoreError.invalidDocument(url.path)
        }

        document.selectedProfileID = id
        try saveProfileSettingsDocument(document)
    }

    public func loadProfileSettingsDocument() throws -> VPNProfileSettingsDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(VPNProfileSettingsDocument.self, from: data)
        try document.validate(context: url.path)
        return document
    }

    public func saveProfileSettingsDocument(_ document: VPNProfileSettingsDocument) throws {
        try document.validate(context: url.path)

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(document)
            data.append(0x0A)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ProfileSettingsStoreError.writeFailed(url.path)
        }
    }
}

public struct VPNProfileSettingsDocument: Codable, Equatable, Sendable {
    public var selectedProfileID: VPNProfileID
    public var profiles: [VPNProfileSettings]

    public init(selectedProfileID: VPNProfileID, profiles: [VPNProfileSettings]) {
        self.selectedProfileID = selectedProfileID
        self.profiles = profiles
    }

    public var selectedProfile: VPNProfileSettings? {
        profiles.first { $0.id == selectedProfileID }
    }

    func validate(context: String) throws {
        guard profiles.isEmpty || selectedProfile != nil else {
            throw ProfileSettingsStoreError.invalidDocument("\(context): selected profile is missing")
        }

        var ids: Set<VPNProfileID> = []
        var endpoints: Set<SocksEndpoint> = []

        for profile in profiles {
            guard ids.insert(profile.id).inserted else {
                throw ProfileSettingsStoreError.duplicateProfileID(profile.id)
            }

            let endpoint = try SocksEndpoint(host: profile.socksHost, port: profile.socksPort)
            guard endpoints.insert(endpoint).inserted else {
                throw ProfileSettingsStoreError.duplicateSocksEndpoint(endpoint)
            }
        }
    }
}
