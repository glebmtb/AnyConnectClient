import AnyConnectClientSupport
import Foundation
import VPNCore
import XCTest

final class ProfileConfigurationLoaderTests: XCTestCase {
    func testImportsLegacyDotenvToSettingsAndKeychainThenLoadsWithoutDotenv() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let legacyURL = tempDirectory.appendingPathComponent(".vpn_access_profile")
        try legacyProfileContent().write(to: legacyURL, atomically: true, encoding: .utf8)

        let credentialStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore()
        let loader = ProfileConfigurationLoader(
            legacyProfilePath: legacyURL.path,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let loaded = try loader.load()

        XCTAssertEqual(loaded.profile.id.rawValue, "humo")
        XCTAssertEqual(loaded.profile.server, "vpn.example.test")
        XCTAssertEqual(loaded.profile.username, "test.user")
        XCTAssertEqual(loaded.profile.socksEndpoint.port, 11084)
        XCTAssertEqual(loaded.credentials.password, "legacy-password")
        XCTAssertEqual(loaded.profile.serverCertificatePin, "pin-sha256:LegacyPin")
        XCTAssertEqual(try credentialStore.password(for: "humo"), "legacy-password")
        XCTAssertEqual(try credentialStore.serverCertificatePin(for: "humo"), "pin-sha256:LegacyPin")
        XCTAssertEqual(settingsStore.savedDocument?.selectedProfile?.server, "vpn.example.test")
        XCTAssertTrue(loaded.migration.importedPassword)
        XCTAssertTrue(loaded.migration.importedServerCertificatePin)
        XCTAssertTrue(loaded.migration.wroteProfileSettings)
        XCTAssertTrue(loaded.migration.removedLegacySecretFields)

        let sanitized = try String(contentsOf: legacyURL, encoding: .utf8)
        XCTAssertFalse(sanitized.contains("VPN_PASSWORD="))
        XCTAssertFalse(sanitized.contains("VPN_SERVERCERT_PIN="))
        XCTAssertTrue(sanitized.contains("VPN_SERVER="))

        try FileManager.default.removeItem(at: legacyURL)
        let loadedAfterLegacyRemoval = try loader.load()
        XCTAssertEqual(loadedAfterLegacyRemoval.profile.server, "vpn.example.test")
        XCTAssertEqual(loadedAfterLegacyRemoval.credentials.password, "legacy-password")
        XCTAssertEqual(loadedAfterLegacyRemoval.migration, .none)
    }

    func testUpdatesSettingsAndStoresNewPasswordInKeychain() throws {
        let credentialStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore(
            settings: VPNProfileSettings(
                id: "humo",
                displayName: "humo",
                server: "old.example.test",
                username: "old.user",
                authGroup: "employees",
                socksHost: "127.0.0.1",
                socksPort: 11084
            )
        )
        try credentialStore.savePassword("old-password", for: "humo")

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let loaded = try loader.updateProfileSettings(
            server: "new.example.test",
            username: "new.user",
            socksPort: 12084,
            password: "new-password",
            autoStartOnLaunch: true
        )

        XCTAssertEqual(settingsStore.savedDocument?.selectedProfile?.server, "new.example.test")
        XCTAssertEqual(settingsStore.savedDocument?.selectedProfile?.username, "new.user")
        XCTAssertEqual(settingsStore.savedDocument?.selectedProfile?.socksPort, 12084)
        XCTAssertEqual(settingsStore.savedDocument?.selectedProfile?.autoStartOnLaunch, true)
        XCTAssertEqual(try credentialStore.password(for: "humo"), "new-password")
        XCTAssertEqual(loaded.profile.server, "new.example.test")
        XCTAssertEqual(loaded.credentials.password, "new-password")
    }

    func testProfileSettingsDecodeMissingAutoStartAsFalse() throws {
        let data = Data(
            """
            {
              "selectedProfileID": "humo",
              "profiles": [
                {
                  "id": "humo",
                  "displayName": "humo",
                  "server": "vpn.example.test",
                  "username": "test.user",
                  "authGroup": "employees",
                  "socksHost": "127.0.0.1",
                  "socksPort": 11084
                }
              ]
            }
            """.utf8
        )

        let document = try JSONDecoder().decode(VPNProfileSettingsDocument.self, from: data)

        XCTAssertEqual(document.selectedProfile?.autoStartOnLaunch, false)
        XCTAssertEqual(document.selectedProfile?.credentialStorageMode, .touchIDVault)
    }

    func testSwitchesProfileToUnsafeStorageAndMigratesCredentials() throws {
        let touchIDStore = InMemoryCredentialStore()
        let unsafeStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore(
            settings: VPNProfileSettings(
                id: "humo",
                displayName: "humo",
                server: "stored.example.test",
                username: "stored.user",
                authGroup: "employees",
                socksHost: "127.0.0.1",
                socksPort: 11084
            )
        )
        try touchIDStore.savePassword("stored-password", for: "humo")
        try touchIDStore.saveServerCertificatePin("pin-sha256:StoredPin", for: "humo")

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: touchIDStore,
            unsafeCredentialStore: unsafeStore
        )

        let updated = try loader.saveProfileSettings(
            server: "stored.example.test",
            username: "stored.user",
            socksPort: 11084,
            password: nil,
            credentialStorageMode: .unsafeLocal
        )

        XCTAssertEqual(updated.credentialStorageMode, .unsafeLocal)
        XCTAssertEqual(settingsStore.savedDocument?.selectedProfile?.credentialStorageMode, .unsafeLocal)
        XCTAssertEqual(try unsafeStore.password(for: "humo"), "stored-password")
        XCTAssertEqual(try unsafeStore.serverCertificatePin(for: "humo"), "pin-sha256:StoredPin")
        XCTAssertFalse(try touchIDStore.containsPassword(for: "humo"))
        XCTAssertFalse(try touchIDStore.containsServerCertificatePin(for: "humo"))
        XCTAssertEqual(try loader.load().credentials.password, "stored-password")
    }

    func testSelectedProfilePasswordReadsFromCredentialStore() throws {
        let credentialStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore(
            settings: VPNProfileSettings(
                id: "humo",
                displayName: "humo",
                server: "stored.example.test",
                username: "stored.user",
                authGroup: "employees",
                socksHost: "127.0.0.1",
                socksPort: 11084
            )
        )
        try credentialStore.savePassword("stored-password", for: "humo")

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        XCTAssertEqual(try loader.selectedProfilePassword(), "stored-password")
    }

    func testDoesNotTouchLegacyDotenvWhenSettingsAlreadyExist() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let legacyURL = tempDirectory.appendingPathComponent(".vpn_access_profile")
        let legacyContent = legacyProfileContent()
        try legacyContent.write(to: legacyURL, atomically: true, encoding: .utf8)

        let credentialStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore(
            settings: VPNProfileSettings(
                id: "humo",
                displayName: "humo",
                server: "stored.example.test",
                username: "stored.user",
                authGroup: "employees",
                socksHost: "127.0.0.1",
                socksPort: 11084
            )
        )
        try credentialStore.savePassword("stored-password", for: "humo")

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: legacyURL.path,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let loaded = try loader.load()

        XCTAssertEqual(loaded.profile.server, "stored.example.test")
        XCTAssertEqual(loaded.credentials.password, "stored-password")
        XCTAssertEqual(loaded.migration, .none)
        XCTAssertEqual(try String(contentsOf: legacyURL, encoding: .utf8), legacyContent)
    }

    func testDoesNotMergeLegacyProfilesWhenSettingsAlreadyExist() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let legacyURL = tempDirectory.appendingPathComponent(".vpn_access_profile")
        try multiProfileLegacyContent().write(to: legacyURL, atomically: true, encoding: .utf8)

        let credentialStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore(
            settings: VPNProfileSettings(
                id: "humo",
                displayName: "humo",
                server: "vpn-one.example.test",
                username: "first.user",
                authGroup: "employees",
                socksHost: "127.0.0.1",
                socksPort: 11084
            )
        )
        try credentialStore.savePassword("first-password", for: "humo")

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: legacyURL.path,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let loaded = try loader.load()

        XCTAssertEqual(loaded.profile.id.rawValue, "humo")
        XCTAssertEqual(loaded.profile.server, "vpn-one.example.test")
        XCTAssertEqual(settingsStore.savedDocument?.profiles.map(\.id.rawValue), ["humo"])
        XCTAssertEqual(settingsStore.savedDocument?.profiles.map(\.socksPort), [11084])
        XCTAssertThrowsError(try credentialStore.password(for: "humo-12084"))
        XCTAssertEqual(loaded.migration, .none)

        XCTAssertEqual(try String(contentsOf: legacyURL, encoding: .utf8), multiProfileLegacyContent())
    }

    func testCreatesProfileAndStoresPassword() throws {
        let credentialStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore(
            settings: VPNProfileSettings(
                id: "humo",
                displayName: "humo",
                server: "vpn-one.example.test",
                username: "first.user",
                authGroup: "employees",
                socksHost: "127.0.0.1",
                socksPort: 11084
            )
        )

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let created = try loader.createProfileSettings(
            displayName: "uz",
            server: "vpn-two.example.test",
            username: "second.user",
            authGroup: nil,
            socksPort: 11085,
            password: "second-password"
        )

        XCTAssertEqual(created.id.rawValue, "uz")
        XCTAssertEqual(settingsStore.savedDocument?.selectedProfileID.rawValue, "uz")
        XCTAssertEqual(settingsStore.savedDocument?.profiles.map(\.id.rawValue).sorted(), ["humo", "uz"])
        XCTAssertEqual(try credentialStore.password(for: "uz"), "second-password")
    }

    func testCreatesProfileWithUnsafeStorage() throws {
        let touchIDStore = InMemoryCredentialStore()
        let unsafeStore = InMemoryCredentialStore()
        let settingsStore = InMemoryProfileSettingsStore()
        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: touchIDStore,
            unsafeCredentialStore: unsafeStore
        )

        let created = try loader.createProfileSettings(
            displayName: "unsafe",
            server: "vpn-unsafe.example.test",
            username: "unsafe.user",
            authGroup: nil,
            socksPort: 11111,
            password: "unsafe-password",
            credentialStorageMode: .unsafeLocal
        )

        XCTAssertEqual(created.credentialStorageMode, .unsafeLocal)
        XCTAssertEqual(try unsafeStore.password(for: created.id), "unsafe-password")
        XCTAssertFalse(try touchIDStore.containsPassword(for: created.id))
    }

    func testDeletesProfileAndCredentials() throws {
        let credentialStore = InMemoryCredentialStore()
        let first = VPNProfileSettings(
            id: "humo",
            displayName: "humo",
            server: "vpn-one.example.test",
            username: "first.user",
            authGroup: "employees",
            socksHost: "127.0.0.1",
            socksPort: 11084
        )
        let second = VPNProfileSettings(
            id: "uz",
            displayName: "uz",
            server: "vpn-two.example.test",
            username: "second.user",
            authGroup: nil,
            socksHost: "127.0.0.1",
            socksPort: 11085
        )
        let settingsStore = InMemoryProfileSettingsStore()
        try settingsStore.saveProfileSettingsDocument(
            VPNProfileSettingsDocument(selectedProfileID: second.id, profiles: [first, second])
        )
        try credentialStore.savePassword("first-password", for: first.id)
        try credentialStore.savePassword("second-password", for: second.id)
        try credentialStore.saveServerCertificatePin("pin-sha256:SecondPin", for: second.id)

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let document = try loader.deleteProfile(id: second.id)

        XCTAssertEqual(document.selectedProfileID, first.id)
        XCTAssertEqual(document.profiles.map(\.id), [first.id])
        XCTAssertFalse(try credentialStore.containsPassword(for: second.id))
        XCTAssertFalse(try credentialStore.containsServerCertificatePin(for: second.id))
        XCTAssertTrue(try credentialStore.containsPassword(for: first.id))
    }

    func testDeletesLastProfileAndCredentials() throws {
        let credentialStore = InMemoryCredentialStore()
        let settings = VPNProfileSettings(
            id: "humo",
            displayName: "humo",
            server: "vpn-one.example.test",
            username: "first.user",
            authGroup: "employees",
            socksHost: "127.0.0.1",
            socksPort: 11084
        )
        let settingsStore = InMemoryProfileSettingsStore(settings: settings)
        try credentialStore.savePassword("first-password", for: settings.id)
        try credentialStore.saveServerCertificatePin("pin-sha256:FirstPin", for: settings.id)

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let document = try loader.deleteProfile(id: settings.id)

        XCTAssertEqual(document.selectedProfileID.rawValue, "default")
        XCTAssertTrue(document.profiles.isEmpty)
        XCTAssertFalse(try credentialStore.containsPassword(for: settings.id))
        XCTAssertFalse(try credentialStore.containsServerCertificatePin(for: settings.id))
        XCTAssertTrue(try loader.loadAllProfileSettings().isEmpty)
    }

    func testDeleteDoesNotResurrectLegacyProfiles() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let legacyURL = tempDirectory.appendingPathComponent(".vpn_access_profile")
        try multiProfileLegacyContent().write(to: legacyURL, atomically: true, encoding: .utf8)

        let credentialStore = InMemoryCredentialStore()
        let settings = VPNProfileSettings(
            id: "humo",
            displayName: "humo",
            server: "vpn-one.example.test",
            username: "first.user",
            authGroup: "employees",
            socksHost: "127.0.0.1",
            socksPort: 11084
        )
        let settingsStore = InMemoryProfileSettingsStore(settings: settings)
        try credentialStore.savePassword("first-password", for: settings.id)

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: legacyURL.path,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        let document = try loader.deleteProfile(id: settings.id)

        XCTAssertTrue(document.profiles.isEmpty)
        XCTAssertEqual(settingsStore.savedDocument?.profiles, [])
        XCTAssertFalse(try credentialStore.containsPassword(for: settings.id))
    }

    func testResetAllDataClearsProfilesAndCredentials() throws {
        let credentialStore = InMemoryCredentialStore()
        let first = VPNProfileSettings(
            id: "humo",
            displayName: "humo",
            server: "vpn-one.example.test",
            username: "first.user",
            authGroup: "employees",
            socksHost: "127.0.0.1",
            socksPort: 11084
        )
        let second = VPNProfileSettings(
            id: "uz",
            displayName: "uz",
            server: "vpn-two.example.test",
            username: "second.user",
            authGroup: nil,
            socksHost: "127.0.0.1",
            socksPort: 11085
        )
        let settingsStore = InMemoryProfileSettingsStore()
        try settingsStore.saveProfileSettingsDocument(
            VPNProfileSettingsDocument(selectedProfileID: first.id, profiles: [first, second])
        )
        try credentialStore.savePassword("first-password", for: first.id)
        try credentialStore.savePassword("second-password", for: second.id)
        try credentialStore.saveServerCertificatePin("pin-sha256:SecondPin", for: second.id)

        let loader = ProfileConfigurationLoader(
            legacyProfilePath: "/tmp/missing-anyconnect-test-profile",
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            unsafeCredentialStore: InMemoryCredentialStore()
        )

        try loader.resetAllData()

        XCTAssertEqual(settingsStore.savedDocument?.selectedProfileID.rawValue, "default")
        XCTAssertEqual(settingsStore.savedDocument?.profiles, [])
        XCTAssertFalse(try credentialStore.containsPassword(for: first.id))
        XCTAssertFalse(try credentialStore.containsPassword(for: second.id))
        XCTAssertFalse(try credentialStore.containsServerCertificatePin(for: second.id))
    }

    func testTouchIDVaultEncryptsSecretsAndCachesAfterUnlock() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let vaultURL = tempDirectory.appendingPathComponent("credential-vault.json")
        let keyStore = InMemoryVaultKeyStore()
        let store = TouchIDVaultCredentialStore(
            url: vaultURL,
            keyStore: keyStore,
            legacyStore: nil
        )

        try store.savePassword("vault-password", for: "humo")
        try store.saveServerCertificatePin("pin-sha256:VaultPin", for: "humo")

        let encryptedText = try String(contentsOf: vaultURL, encoding: .utf8)
        XCTAssertFalse(encryptedText.contains("vault-password"))
        XCTAssertFalse(encryptedText.contains("VaultPin"))

        let coldStore = TouchIDVaultCredentialStore(
            url: vaultURL,
            keyStore: keyStore,
            legacyStore: nil
        )
        XCTAssertThrowsError(try coldStore.passwordWithoutUserInteraction(for: "humo")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .credentialVaultLocked)
        }

        XCTAssertEqual(try coldStore.password(for: "humo"), "vault-password")
        XCTAssertEqual(try coldStore.serverCertificatePinWithoutUserInteraction(for: "humo"), "pin-sha256:VaultPin")
        XCTAssertEqual(try coldStore.passwordWithoutUserInteraction(for: "humo"), "vault-password")
    }

    func testTouchIDVaultMigratesLegacyCredentialsLazily() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let legacyStore = InMemoryCredentialStore()
        try legacyStore.savePassword("legacy-password", for: "humo")
        try legacyStore.saveServerCertificatePin("pin-sha256:LegacyPin", for: "humo")

        let store = TouchIDVaultCredentialStore(
            url: tempDirectory.appendingPathComponent("credential-vault.json"),
            keyStore: InMemoryVaultKeyStore(),
            legacyStore: legacyStore
        )

        XCTAssertEqual(try store.password(for: "humo"), "legacy-password")
        XCTAssertEqual(try store.serverCertificatePin(for: "humo"), "pin-sha256:LegacyPin")
        XCTAssertFalse(try legacyStore.containsPassword(for: "humo"))
        XCTAssertFalse(try legacyStore.containsServerCertificatePin(for: "humo"))
    }

    func testUnsafeLocalStoreDoesNotWriteSecretsAsPlainText() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let url = tempDirectory.appendingPathComponent("unsafe-credential-vault.json")
        let store = UnsafeLocalCredentialStore(url: url)

        try store.savePassword("unsafe-password", for: "humo")
        try store.saveServerCertificatePin("pin-sha256:UnsafePin", for: "humo")

        let storedText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(storedText.contains("unsafe-password"))
        XCTAssertFalse(storedText.contains("UnsafePin"))

        let coldStore = UnsafeLocalCredentialStore(url: url)
        XCTAssertEqual(try coldStore.passwordWithoutUserInteraction(for: "humo"), "unsafe-password")
        XCTAssertEqual(try coldStore.serverCertificatePinWithoutUserInteraction(for: "humo"), "pin-sha256:UnsafePin")
    }

    func testFileSettingsStoreRejectsDuplicateSocksEndpoints() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = FileVPNProfileSettingsStore(url: tempDirectory.appendingPathComponent("profile-settings.json"))
        let first = VPNProfileSettings(
            id: "humo",
            displayName: "humo",
            server: "vpn-one.example.test",
            username: "first.user",
            authGroup: nil,
            socksHost: "127.0.0.1",
            socksPort: 11084
        )
        let second = VPNProfileSettings(
            id: "humo-dev",
            displayName: "humo dev",
            server: "vpn-two.example.test",
            username: "second.user",
            authGroup: nil,
            socksHost: "127.0.0.1",
            socksPort: 11084
        )

        let document = VPNProfileSettingsDocument(selectedProfileID: first.id, profiles: [first, second])

        XCTAssertThrowsError(try store.saveProfileSettingsDocument(document)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertEqual(
                message,
                "SOCKS port 11084 is already used by another profile. Choose another port."
            )
            XCTAssertFalse(message.contains("profile-settings.json"))
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyConnectClientSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func legacyProfileContent() -> String {
        """
        PROFILE_NAME=humo
        VPN_SERVER=vpn.example.test
        VPN_USERNAME=test.user
        VPN_PASSWORD=legacy-password
        VPN_AUTHGROUP=employees
        VPN_SERVERCERT_PIN=pin-sha256:LegacyPin
        SOCKS_HOST=127.0.0.1
        SOCKS_PORT=11084
        """
    }

    private func multiProfileLegacyContent() -> String {
        """
        PROFILE_NAME=humo
        VPN_SERVER=vpn-one.example.test
        VPN_USERNAME=first.user
        VPN_AUTHGROUP=employees
        SOCKS_HOST=127.0.0.1
        SOCKS_PORT=11084

        PROFILE_NAME=humo
        VPN_SERVER=vpn-two.example.test
        VPN_USERNAME=second.user
        VPN_PASSWORD=second-password
        SOCKS_HOST=127.0.0.1
        SOCKS_PORT=12084
        """
    }
}

private final class InMemoryVaultKeyStore: CredentialVaultKeyStore, @unchecked Sendable {
    private var storedKeyData: Data?

    func keyData(allowUserInteraction: Bool, createIfMissing: Bool) throws -> Data? {
        if let storedKeyData {
            if allowUserInteraction {
                return storedKeyData
            }
            throw CredentialStoreError.credentialVaultLocked
        }

        guard createIfMissing else {
            return nil
        }

        let keyData = Data(repeating: 7, count: 32)
        storedKeyData = keyData
        return keyData
    }

    func deleteKey() throws {
        storedKeyData = nil
    }
}

private final class InMemoryCredentialStore: VPNCredentialStore, @unchecked Sendable {
    private var passwords: [String: String] = [:]
    private var pins: [String: String] = [:]

    func password(for profileID: VPNProfileID) throws -> String {
        guard let password = passwords[profileID.rawValue] else {
            throw CredentialStoreError.missingPassword(profileID: profileID.rawValue)
        }
        return password
    }

    func passwordWithoutUserInteraction(for profileID: VPNProfileID) throws -> String {
        try password(for: profileID)
    }

    func savePassword(_ password: String, for profileID: VPNProfileID) throws {
        passwords[profileID.rawValue] = password
    }

    func containsPassword(for profileID: VPNProfileID) throws -> Bool {
        passwords[profileID.rawValue] != nil
    }

    func deletePassword(for profileID: VPNProfileID) throws {
        passwords.removeValue(forKey: profileID.rawValue)
    }

    func serverCertificatePin(for profileID: VPNProfileID) throws -> String? {
        pins[profileID.rawValue]
    }

    func serverCertificatePinWithoutUserInteraction(for profileID: VPNProfileID) throws -> String? {
        try serverCertificatePin(for: profileID)
    }

    func saveServerCertificatePin(_ pin: String, for profileID: VPNProfileID) throws {
        pins[profileID.rawValue] = pin
    }

    func containsServerCertificatePin(for profileID: VPNProfileID) throws -> Bool {
        pins[profileID.rawValue] != nil
    }

    func deleteServerCertificatePin(for profileID: VPNProfileID) throws {
        pins.removeValue(forKey: profileID.rawValue)
    }

    func deleteAllCredentials() throws {
        passwords.removeAll()
        pins.removeAll()
    }
}

private final class InMemoryProfileSettingsStore: VPNProfileSettingsStore, @unchecked Sendable {
    private(set) var savedDocument: VPNProfileSettingsDocument?

    init(settings: VPNProfileSettings? = nil) {
        if let settings {
            self.savedDocument = VPNProfileSettingsDocument(selectedProfileID: settings.id, profiles: [settings])
        }
    }

    func loadProfileSettingsDocument() throws -> VPNProfileSettingsDocument? {
        savedDocument
    }

    func saveProfileSettingsDocument(_ document: VPNProfileSettingsDocument) throws {
        savedDocument = document
    }

    func loadSelectedProfileSettings() throws -> VPNProfileSettings? {
        savedDocument?.selectedProfile
    }

    func saveSelectedProfileSettings(_ settings: VPNProfileSettings) throws {
        if var document = savedDocument {
            if let index = document.profiles.firstIndex(where: { $0.id == settings.id }) {
                document.profiles[index] = settings
            } else {
                document.profiles.append(settings)
            }
            document.selectedProfileID = settings.id
            savedDocument = document
        } else {
            savedDocument = VPNProfileSettingsDocument(selectedProfileID: settings.id, profiles: [settings])
        }
    }

    func selectProfile(id: VPNProfileID) throws {
        guard var document = savedDocument, document.profiles.contains(where: { $0.id == id }) else {
            throw ProfileSettingsStoreError.invalidDocument("memory")
        }
        document.selectedProfileID = id
        savedDocument = document
    }
}
