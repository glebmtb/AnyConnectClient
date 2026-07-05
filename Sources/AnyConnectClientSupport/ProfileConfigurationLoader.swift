import Foundation
import VPNCore

public struct LoadedVPNProfile: Sendable {
    public let profile: VPNProfile
    public let credentials: VPNCredentials
    public let migration: CredentialMigrationSummary

    public init(profile: VPNProfile, credentials: VPNCredentials, migration: CredentialMigrationSummary) {
        self.profile = profile
        self.credentials = credentials
        self.migration = migration
    }
}

public struct CredentialMigrationSummary: Equatable, Sendable {
    public let importedPassword: Bool
    public let importedServerCertificatePin: Bool
    public let wroteProfileSettings: Bool
    public let removedLegacySecretFields: Bool

    public static let none = CredentialMigrationSummary(
        importedPassword: false,
        importedServerCertificatePin: false,
        wroteProfileSettings: false,
        removedLegacySecretFields: false
    )
}

public enum ProfileConfigurationLoaderError: Error, LocalizedError, Equatable {
    case missingProfileSettings(settingsPath: String, legacyPath: String)
    case missingField(String)
    case emptyField(String)
    case invalidPort(String)
    case failedToSanitizeLegacyProfile(String)

    public var errorDescription: String? {
        switch self {
        case .missingProfileSettings(let settingsPath, let legacyPath):
            "Profile settings are missing. Create settings in the app or import legacy profile: \(legacyPath). Settings path: \(settingsPath)"
        case .missingField(let field):
            "Profile field is missing: \(field)"
        case .emptyField(let field):
            "Profile field is empty: \(field)"
        case .invalidPort(let value):
            "Invalid SOCKS port: \(value)"
        case .failedToSanitizeLegacyProfile(let path):
            "Failed to remove legacy secret fields from profile: \(path)"
        }
    }
}

public struct ProfileConfigurationLoader: Sendable {
    public let legacyProfilePath: String
    public let settingsStore: any VPNProfileSettingsStore

    private let touchIDCredentialStore: any VPNCredentialStore
    private let unsafeCredentialStore: any VPNCredentialStore
    private let migrateLegacySecrets: Bool

    public init(
        legacyProfilePath: String = "",
        settingsStore: any VPNProfileSettingsStore = FileVPNProfileSettingsStore(),
        credentialStore: any VPNCredentialStore = TouchIDVaultCredentialStore(),
        unsafeCredentialStore: any VPNCredentialStore = UnsafeLocalCredentialStore(),
        migrateLegacySecrets: Bool = true
    ) {
        self.legacyProfilePath = legacyProfilePath
        self.settingsStore = settingsStore
        self.touchIDCredentialStore = credentialStore
        self.unsafeCredentialStore = unsafeCredentialStore
        self.migrateLegacySecrets = migrateLegacySecrets
    }

    public func load() throws -> LoadedVPNProfile {
        try load(allowUserInteraction: true)
    }

    public func loadWithoutUserInteraction() throws -> LoadedVPNProfile {
        try load(allowUserInteraction: false)
    }

    public func loadWithoutUserInteraction(profileID: VPNProfileID) throws -> LoadedVPNProfile {
        try load(profileID: profileID, allowUserInteraction: false)
    }

    public func load(profileID: VPNProfileID) throws -> LoadedVPNProfile {
        try load(profileID: profileID, allowUserInteraction: true)
    }

    private func load(allowUserInteraction: Bool) throws -> LoadedVPNProfile {
        let loadedSettings = try loadOrImportProfileSettings()
        return try load(settings: loadedSettings.settings, migration: loadedSettings.migration, allowUserInteraction: allowUserInteraction)
    }

    private func load(profileID: VPNProfileID, allowUserInteraction: Bool) throws -> LoadedVPNProfile {
        _ = try loadOrImportProfileSettings()
        guard let settings = try settingsStore.loadProfileSettingsDocument()?.profiles.first(where: { $0.id == profileID }) else {
            throw ProfileConfigurationLoaderError.missingProfileSettings(
                settingsPath: settingsPathDescription(),
                legacyPath: legacyPathDescription()
            )
        }

        return try load(settings: settings, migration: .none, allowUserInteraction: allowUserInteraction)
    }

    private func load(
        settings: VPNProfileSettings,
        migration: CredentialMigrationSummary,
        allowUserInteraction: Bool
    ) throws -> LoadedVPNProfile {
        let credentialStore = credentialStore(for: settings)
        let password = if allowUserInteraction {
            try credentialStore.password(for: settings.id)
        } else {
            try credentialStore.passwordWithoutUserInteraction(for: settings.id)
        }
        let pin = if allowUserInteraction {
            try credentialStore.serverCertificatePin(for: settings.id)
        } else {
            try credentialStore.serverCertificatePinWithoutUserInteraction(for: settings.id)
        }
        let profile = try settings.makeProfile(serverCertificatePin: pin)
        let credentials = VPNCredentials(profileID: profile.id, password: password)

        return LoadedVPNProfile(profile: profile, credentials: credentials, migration: migration)
    }

    public func loadEditableSettings() throws -> VPNProfileSettings {
        if let document = try settingsStore.loadProfileSettingsDocument() {
            return document.selectedProfile ?? .emptyDefault
        }
        if let loaded = try? loadOrImportProfileSettings() {
            return loaded.settings
        }
        return try loadLegacyProfileSettingsList().first?.settings ?? .emptyDefault
    }

    public func loadAllProfileSettings() throws -> [VPNProfileSettings] {
        if let document = try settingsStore.loadProfileSettingsDocument() {
            return document.profiles
        }
        return try loadLegacyProfileSettingsList().map(\.settings)
    }

    public func selectProfile(id: VPNProfileID) throws -> VPNProfileSettings {
        try settingsStore.selectProfile(id: id)
        guard let settings = try settingsStore.loadSelectedProfileSettings() else {
            throw ProfileConfigurationLoaderError.missingProfileSettings(
                settingsPath: settingsPathDescription(),
                legacyPath: legacyPathDescription()
            )
        }
        return settings
    }

    public func selectedProfilePassword() throws -> String {
        let settings = try loadEditableSettings()
        return try credentialStore(for: settings).password(for: settings.id)
    }

    public func saveServerCertificatePin(_ pin: String, for profileID: VPNProfileID) throws {
        let normalizedPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPin.isEmpty else {
            throw ProfileConfigurationLoaderError.emptyField("VPN_SERVERCERT_PIN")
        }
        let settings = try profileSettings(id: profileID)
        try credentialStore(for: settings).saveServerCertificatePin(normalizedPin, for: profileID)
    }

    public func updateProfileSettings(
        server: String,
        username: String,
        socksPort: Int,
        password: String?,
        autoStartOnLaunch: Bool? = nil,
        credentialStorageMode: CredentialStorageMode? = nil
    ) throws -> LoadedVPNProfile {
        _ = try saveProfileSettings(
            server: server,
            username: username,
            socksPort: socksPort,
            password: password,
            autoStartOnLaunch: autoStartOnLaunch,
            credentialStorageMode: credentialStorageMode
        )
        return try load()
    }

    public func saveProfileSettings(
        server: String,
        username: String,
        socksPort: Int,
        password: String?,
        autoStartOnLaunch: Bool? = nil,
        credentialStorageMode: CredentialStorageMode? = nil
    ) throws -> VPNProfileSettings {
        let originalSettings = try loadEditableSettings()
        var settings = originalSettings
        let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedServer.isEmpty else {
            throw ProfileConfigurationLoaderError.emptyField("VPN_SERVER")
        }
        guard !normalizedUsername.isEmpty else {
            throw ProfileConfigurationLoaderError.emptyField("VPN_USERNAME")
        }
        _ = try SocksEndpoint(host: settings.socksHost, port: socksPort)

        settings.server = normalizedServer
        settings.username = normalizedUsername
        settings.socksPort = socksPort
        if let autoStartOnLaunch {
            settings.autoStartOnLaunch = autoStartOnLaunch
        }
        if let credentialStorageMode {
            settings.credentialStorageMode = credentialStorageMode
        }

        let storageModeChanged = settings.credentialStorageMode != originalSettings.credentialStorageMode
        let sourceCredentialStore = credentialStore(for: originalSettings)
        let targetCredentialStore = credentialStore(for: settings)

        if let password = nonEmpty(password) {
            try targetCredentialStore.savePassword(password, for: settings.id)
        } else if storageModeChanged {
            let existingPassword = try sourceCredentialStore.password(for: settings.id)
            try targetCredentialStore.savePassword(existingPassword, for: settings.id)
        }

        if storageModeChanged, let pin = try sourceCredentialStore.serverCertificatePin(for: settings.id) {
            try targetCredentialStore.saveServerCertificatePin(pin, for: settings.id)
        }

        try settingsStore.saveSelectedProfileSettings(settings)
        if storageModeChanged {
            try? sourceCredentialStore.deleteCredentials(for: settings.id)
        }
        return settings
    }

    public func createProfileSettings(
        displayName: String,
        server: String,
        username: String,
        authGroup: String?,
        socksHost: String = "127.0.0.1",
        socksPort: Int,
        password: String,
        credentialStorageMode: CredentialStorageMode = .touchIDVault
    ) throws -> VPNProfileSettings {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedDisplayName.isEmpty else {
            throw ProfileConfigurationLoaderError.emptyField("PROFILE_NAME")
        }
        guard !normalizedServer.isEmpty else {
            throw ProfileConfigurationLoaderError.emptyField("VPN_SERVER")
        }
        guard !normalizedUsername.isEmpty else {
            throw ProfileConfigurationLoaderError.emptyField("VPN_USERNAME")
        }
        guard let normalizedPassword = nonEmpty(password) else {
            throw ProfileConfigurationLoaderError.emptyField("VPN_PASSWORD")
        }

        let endpoint = try SocksEndpoint(host: socksHost, port: socksPort)
        _ = try? loadOrImportProfileSettings()
        var document = try settingsStore.loadProfileSettingsDocument() ?? VPNProfileSettingsDocument(
            selectedProfileID: "default",
            profiles: []
        )
        var reservedIDs = Set(document.profiles.map(\.id))
        let profileID = uniqueProfileID(
            profileName: normalizedDisplayName,
            socksPort: endpoint.port,
            reserved: &reservedIDs
        )
        let settings = VPNProfileSettings(
            id: profileID,
            displayName: normalizedDisplayName,
            server: normalizedServer,
            username: normalizedUsername,
            authGroup: nonEmpty(authGroup),
            socksHost: endpoint.host,
            socksPort: endpoint.port,
            credentialStorageMode: credentialStorageMode
        )

        document.profiles.append(settings)
        document.selectedProfileID = settings.id
        try document.validate(context: settingsPathDescription())

        do {
            try credentialStore(for: settings).savePassword(normalizedPassword, for: settings.id)
            try settingsStore.saveProfileSettingsDocument(document)
        } catch {
            try? deleteCredentialsEverywhere(for: settings.id)
            throw error
        }

        return settings
    }

    public func deleteProfile(id: VPNProfileID) throws -> VPNProfileSettingsDocument {
        guard var document = try settingsStore.loadProfileSettingsDocument(),
              let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileConfigurationLoaderError.missingProfileSettings(
                settingsPath: settingsPathDescription(),
                legacyPath: legacyPathDescription()
            )
        }

        document.profiles.remove(at: index)
        if document.selectedProfileID == id {
            document.selectedProfileID = document.profiles.first?.id ?? "default"
        }
        try settingsStore.saveProfileSettingsDocument(document)
        try deleteCredentialsEverywhere(for: id)
        return document
    }

    public func resetAllData() throws {
        try settingsStore.saveProfileSettingsDocument(
            VPNProfileSettingsDocument(
                selectedProfileID: "default",
                profiles: []
            )
        )
        try touchIDCredentialStore.deleteAllCredentials()
        try unsafeCredentialStore.deleteAllCredentials()
    }

    private func loadOrImportProfileSettings() throws -> LoadedProfileSettings {
        if let document = try settingsStore.loadProfileSettingsDocument() {
            guard !document.profiles.isEmpty else {
                throw ProfileConfigurationLoaderError.missingProfileSettings(
                    settingsPath: settingsPathDescription(),
                    legacyPath: legacyPathDescription()
                )
            }

            guard let selected = document.selectedProfile else {
                throw ProfileConfigurationLoaderError.missingProfileSettings(
                    settingsPath: settingsPathDescription(),
                    legacyPath: legacyPathDescription()
                )
            }
            return LoadedProfileSettings(
                settings: selected,
                migration: .none
            )
        }

        let legacyProfiles = try loadLegacyProfileSettingsList()
        if !legacyProfiles.isEmpty {
            let document = try buildDocument(from: legacyProfiles)
            try settingsStore.saveProfileSettingsDocument(document)
            let removedLegacyFields = if migrateLegacySecrets, legacyProfiles.contains(where: \.containsLegacySecretFields) {
                try sanitizeLegacyProfileFile(content: legacyProfiles.first?.content ?? "")
            } else {
                false
            }
            guard let selected = document.selectedProfile else {
                throw ProfileConfigurationLoaderError.missingProfileSettings(
                    settingsPath: settingsPathDescription(),
                    legacyPath: legacyPathDescription()
                )
            }
            return LoadedProfileSettings(
                settings: selected,
                migration: CredentialMigrationSummary(
                    importedPassword: migrateLegacySecrets && legacyProfiles.contains { $0.password != nil },
                    importedServerCertificatePin: migrateLegacySecrets && legacyProfiles.contains { $0.serverCertificatePin != nil },
                    wroteProfileSettings: true,
                    removedLegacySecretFields: removedLegacyFields
                )
            )
        }

        throw ProfileConfigurationLoaderError.missingProfileSettings(
            settingsPath: settingsPathDescription(),
            legacyPath: legacyPathDescription()
        )
    }

    private func importLegacySecretsIfNeeded(_ legacy: LegacyProfileSettings) throws -> Bool {
        guard migrateLegacySecrets else {
            return false
        }
        var imported = false
        let credentialStore = credentialStore(for: legacy.settings)
        if let password = legacy.password {
            try credentialStore.savePassword(password, for: legacy.settings.id)
            imported = true
        }
        if let pin = legacy.serverCertificatePin {
            try credentialStore.saveServerCertificatePin(pin, for: legacy.settings.id)
            imported = true
        }
        return imported
    }

    private func credentialStore(for settings: VPNProfileSettings) -> any VPNCredentialStore {
        credentialStore(for: settings.credentialStorageMode)
    }

    private func credentialStore(for storageMode: CredentialStorageMode) -> any VPNCredentialStore {
        switch storageMode {
        case .touchIDVault:
            touchIDCredentialStore
        case .unsafeLocal:
            unsafeCredentialStore
        }
    }

    private func deleteCredentialsEverywhere(for profileID: VPNProfileID) throws {
        var firstError: Error?
        for store in [touchIDCredentialStore, unsafeCredentialStore] {
            do {
                try store.deleteCredentials(for: profileID)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func profileSettings(id profileID: VPNProfileID) throws -> VPNProfileSettings {
        _ = try loadOrImportProfileSettings()
        guard let settings = try settingsStore.loadProfileSettingsDocument()?.profiles.first(where: { $0.id == profileID }) else {
            throw ProfileConfigurationLoaderError.missingProfileSettings(
                settingsPath: settingsPathDescription(),
                legacyPath: legacyPathDescription()
            )
        }
        return settings
    }

    private func loadLegacyProfileSettingsList() throws -> [LegacyProfileSettings] {
        guard !legacyProfilePath.isEmpty,
              FileManager.default.fileExists(atPath: legacyProfilePath) else {
            return []
        }

        let content = try String(contentsOfFile: legacyProfilePath, encoding: .utf8)
        let blocks = parseProfileBlocks(content)
        var reservedIDs: Set<VPNProfileID> = []

        return try blocks.map { values in
            let profileName = try required("PROFILE_NAME", in: values)
            let server = try required("VPN_SERVER", in: values)
            let username = try required("VPN_USERNAME", in: values)
            let socksHost = values["SOCKS_HOST"] ?? "127.0.0.1"
            let socksPortValue = values["SOCKS_PORT"] ?? "11080"

            guard let socksPort = Int(socksPortValue) else {
                throw ProfileConfigurationLoaderError.invalidPort(socksPortValue)
            }
            _ = try SocksEndpoint(host: socksHost, port: socksPort)

            let profileID = uniqueProfileID(profileName: profileName, socksPort: socksPort, reserved: &reservedIDs)
            let displayName = profileID.rawValue == stableProfileID(from: profileName)
                ? profileName
                : "\(profileName) \(socksPort)"
            let settings = VPNProfileSettings(
                id: profileID,
                displayName: displayName,
                server: server,
                username: username,
                authGroup: values["VPN_AUTHGROUP"],
                socksHost: socksHost,
                socksPort: socksPort
            )

            return LegacyProfileSettings(
                settings: settings,
                password: nonEmpty(values["VPN_PASSWORD"]),
                serverCertificatePin: nonEmpty(values["VPN_SERVERCERT_PIN"]),
                containsLegacySecretFields: containsLegacySecretFields(in: content),
                content: content
            )
        }
    }

    private func buildDocument(from legacyProfiles: [LegacyProfileSettings]) throws -> VPNProfileSettingsDocument {
        for legacy in legacyProfiles {
            _ = try importLegacySecretsIfNeeded(legacy)
        }

        let profiles = legacyProfiles.map(\.settings)
        return VPNProfileSettingsDocument(
            selectedProfileID: profiles.first?.id ?? .init(rawValue: "default"),
            profiles: profiles
        )
    }

    private func parseProfileBlocks(_ content: String) -> [[String: String]] {
        var blocks: [[String: String]] = []
        var current: [String: String] = [:]

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else {
                continue
            }

            if key == "PROFILE_NAME", !current.isEmpty {
                blocks.append(current)
                current = [:]
            }
            current[key] = unquote(value)
        }

        if !current.isEmpty {
            blocks.append(current)
        }

        return blocks
    }

    private func required(_ field: String, in values: [String: String]) throws -> String {
        guard let value = values[field], !value.isEmpty else {
            throw ProfileConfigurationLoaderError.missingField(field)
        }
        return value
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if value.first == "'", value.last == "'" {
            let inner = value.dropFirst().dropLast()
            return inner.replacingOccurrences(of: "'\\''", with: "'")
        }

        if value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    private func stableProfileID(from name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.map { character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "default" : collapsed
    }

    private func uniqueProfileID(
        profileName: String,
        socksPort: Int,
        reserved: inout Set<VPNProfileID>
    ) -> VPNProfileID {
        let base = stableProfileID(from: profileName)
        let baseID = VPNProfileID(rawValue: base)
        if !reserved.contains(baseID) {
            reserved.insert(baseID)
            return baseID
        }

        let portID = VPNProfileID(rawValue: "\(base)-\(socksPort)")
        if !reserved.contains(portID) {
            reserved.insert(portID)
            return portID
        }

        var suffix = 2
        while true {
            let candidate = VPNProfileID(rawValue: "\(base)-\(socksPort)-\(suffix)")
            if !reserved.contains(candidate) {
                reserved.insert(candidate)
                return candidate
            }
            suffix += 1
        }
    }

    private func containsLegacySecretFields(in content: String) -> Bool {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { isLegacySecretAssignment(String($0)) }
    }

    private func sanitizeLegacyProfileFile(content: String) throws -> Bool {
        let sanitized = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isLegacySecretAssignment($0) }
            .joined(separator: "\n")

        guard sanitized != content else {
            return false
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: legacyProfilePath)
        do {
            try sanitized.write(toFile: legacyProfilePath, atomically: true, encoding: .utf8)
            if let permissions = attributes?[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: legacyProfilePath)
            }
        } catch {
            throw ProfileConfigurationLoaderError.failedToSanitizeLegacyProfile(legacyPathDescription())
        }
        return true
    }

    private func isLegacySecretAssignment(_ rawLine: String) -> Bool {
        guard let key = assignmentKey(rawLine) else { return false }
        return Self.legacySecretKeys.contains(key)
    }

    private func assignmentKey(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
            return nil
        }

        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private func settingsPathDescription() -> String {
        if let fileStore = settingsStore as? FileVPNProfileSettingsStore {
            return fileStore.url.path
        }
        return "configured profile settings store"
    }

    private func legacyPathDescription() -> String {
        legacyProfilePath.isEmpty ? "not configured" : legacyProfilePath
    }

    private static let legacySecretKeys: Set<String> = [
        "VPN_PASSWORD",
        "VPN_SERVERCERT_PIN",
        "VPN_COOKIE",
        "VPN_TOKEN",
        "VPN_TOKEN_SECRET",
        "VPN_OTP"
    ]
}

private struct LoadedProfileSettings: Sendable {
    var settings: VPNProfileSettings
    var migration: CredentialMigrationSummary
}

private struct LegacyProfileSettings: Sendable {
    var settings: VPNProfileSettings
    var password: String?
    var serverCertificatePin: String?
    var containsLegacySecretFields: Bool
    var content: String
}
