import AnyConnectClientSupport
import Foundation
import OpenConnectRuntime
import VPNCore

@main
struct AnyConnectCredentialTool {
    private static let legacyProfilePathEnvironmentKey = "ANYCONNECTCLIENT_LEGACY_PROFILE_PATH"
    private static let legacyPathNotConfigured = "not configured"

    static func main() async {
        do {
            let command = CommandLine.arguments.dropFirst().first ?? "status"
            if command == "smoke" {
                try await runSmoke()
            } else if command == "diagnose" {
                try await runDiagnose()
            } else if command == "migrate" {
                try runMigration()
            } else {
                try runStatus()
            }
        } catch {
            printError(error)
            exit(1)
        }
    }

    private static func runMigration() throws {
        let loader = ProfileConfigurationLoader(legacyProfilePath: try legacyProfilePath())
        let loaded = try loader.load()
        print("profile=\(loaded.profile.displayName)")
        print("endpoint=\(loaded.profile.socksEndpoint.address)")
        print("settings=ready")
        print("vault_password=present")
        print("vault_servercert=\(loaded.profile.serverCertificatePin == nil ? "missing" : "present")")
        print("legacy_password_imported=\(loaded.migration.importedPassword)")
        print("legacy_servercert_imported=\(loaded.migration.importedServerCertificatePin)")
        print("legacy_secret_fields_removed=\(loaded.migration.removedLegacySecretFields)")
    }

    private static func runStatus() throws {
        let settingsStore = FileVPNProfileSettingsStore()

        guard let document = try settingsStore.loadProfileSettingsDocument() else {
            print("settings=missing")
            print("legacy_import=available_via_migrate")
            return
        }

        print("settings=ready")
        print("selected_profile=\(document.selectedProfileID.rawValue)")
        print("profile_count=\(document.profiles.count)")

        for (index, settings) in document.profiles.sortedForStatus().enumerated() {
            let credentialStore = credentialStore(for: settings)
            print("profile[\(index)].id=\(settings.id.rawValue)")
            print("profile[\(index)].name=\(settings.displayName)")
            print("profile[\(index)].selected=\(settings.id == document.selectedProfileID)")
            print("profile[\(index)].endpoint=\(settings.socksHost):\(settings.socksPort)")
            print("profile[\(index)].auto_start=\(settings.autoStartOnLaunch)")
            print("profile[\(index)].vault_password=\(credentialStatus { try credentialStore.containsPassword(for: settings.id) })")
            print("profile[\(index)].vault_servercert=\(credentialStatus { try credentialStore.containsServerCertificatePin(for: settings.id) })")
        }
    }

    private static func runSmoke() async throws {
        let settingsStore = FileVPNProfileSettingsStore()
        guard let settings = try settingsStore.loadSelectedProfileSettings() else {
            throw ProfileConfigurationLoaderError.missingProfileSettings(
                settingsPath: FileVPNProfileSettingsStore.defaultURL().path,
                legacyPath: legacyPathNotConfigured
            )
        }
        let credentialStore = credentialStore(for: settings)
        let password = try credentialStore.password(for: settings.id)
        let runtimePaths = RuntimePaths(
            openConnectExecutablePath: "\(FileManager.default.currentDirectoryPath)/ThirdParty/openconnect-9.21/openconnect",
            ocproxyExecutablePath: "\(FileManager.default.currentDirectoryPath)/ThirdParty/ocproxy/ocproxy"
        )
        var session = OpenConnectSession(
            runtimePaths: runtimePaths,
            configuration: OpenConnectSessionConfiguration(startupTimeoutNanoseconds: 45_000_000_000)
        )
        var pin = try credentialStore.serverCertificatePin(for: settings.id)
        var profile = try settings.makeProfile(serverCertificatePin: pin)
        let credentials = VPNCredentials(profileID: profile.id, password: password)
        var secrets = [credentials.password, profile.serverCertificatePin].compactMap { $0 }

        let started: OpenConnectSessionStart
        do {
            started = try await session.start(
                profile: profile,
                credentials: credentials,
                redactor: Redactor(literalSecrets: secrets)
            )
        } catch {
            guard let suggestedPin = await session.serverCertificatePinSuggestion() else {
                throw error
            }

            await session.stop()
            try credentialStore.saveServerCertificatePin(suggestedPin, for: settings.id)
            print("servercert=stored_from_openconnect")

            pin = suggestedPin
            profile = try settings.makeProfile(serverCertificatePin: pin)
            secrets = [credentials.password, profile.serverCertificatePin].compactMap { $0 }
            session = OpenConnectSession(
                runtimePaths: runtimePaths,
                configuration: OpenConnectSessionConfiguration(startupTimeoutNanoseconds: 45_000_000_000)
            )
            started = try await session.start(
                profile: profile,
                credentials: credentials,
                redactor: Redactor(literalSecrets: secrets)
            )
        }
        let cleanupSession = session
        defer {
            Task { await cleanupSession.stop() }
        }

        print("ready=true endpoint=\(started.socksEndpoint.address)")
        let positiveURLs = smokeURLs(from: "ANYCONNECTCLIENT_SMOKE_POSITIVE_URLS")
        let negativeURLs = smokeURLs(from: "ANYCONNECTCLIENT_SMOKE_NEGATIVE_URLS")
        if positiveURLs.isEmpty && negativeURLs.isEmpty {
            print("smoke_urls=not_configured")
        }
        for (index, url) in positiveURLs.enumerated() {
            let result = runCurlCheck(endpoint: started.socksEndpoint, url: url)
            print("positive[\(index)]=\(result.label)")
        }
        for (index, url) in negativeURLs.enumerated() {
            let result = runCurlCheck(endpoint: started.socksEndpoint, url: url)
            print("negative[\(index)]=\(result.exitCode == 0 ? "unexpected_success_http_\(result.httpCode)" : "failed_as_expected")")
        }

        await cleanupSession.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let closed = await !SocksHealthCheck().isListening(endpoint: started.socksEndpoint)
        print("cleanup=\(closed ? "port_closed" : "port_still_open")")
        if !closed {
            exit(22)
        }
    }

    private static func runDiagnose() async throws {
        let settingsStore = FileVPNProfileSettingsStore()
        guard let settings = try settingsStore.loadSelectedProfileSettings() else {
            throw ProfileConfigurationLoaderError.missingProfileSettings(
                settingsPath: FileVPNProfileSettingsStore.defaultURL().path,
                legacyPath: legacyPathNotConfigured
            )
        }

        let credentialStore = credentialStore(for: settings)
        let password = try credentialStore.password(for: settings.id)
        let pin = try credentialStore.serverCertificatePin(for: settings.id)
        let profile = try settings.makeProfile(serverCertificatePin: pin)
        let credentials = VPNCredentials(profileID: profile.id, password: password)
        let runtimePaths = RuntimePaths(
            openConnectExecutablePath: "\(FileManager.default.currentDirectoryPath)/ThirdParty/openconnect-9.21/openconnect",
            ocproxyExecutablePath: "\(FileManager.default.currentDirectoryPath)/ThirdParty/ocproxy/ocproxy"
        )
        let redactor = Redactor(literalSecrets: [
            credentials.password,
            profile.serverCertificatePin,
            settings.server,
            settings.username,
            settings.authGroup
        ].compactMap { $0 })
        let ocproxyWrapper = try OcproxyScriptWrapper.install(
            realExecutablePath: runtimePaths.ocproxyExecutablePath
        )
        defer {
            Task { await ocproxyWrapper.stop(gracePeriodNanoseconds: 500_000_000) }
        }

        let invocation = OpenConnectCommandBuilder().build(
            profile: profile,
            runtimePaths: ocproxyWrapper.runtimePaths(from: runtimePaths)
        )
        let process = OpenConnectProcess()
        let events = try await process.start(
            invocation: invocation,
            standardInput: credentials.password,
            redactor: redactor
        )

        print("diagnose_profile=\(settings.displayName)")
        print("diagnose_endpoint=\(settings.socksHost):\(settings.socksPort)")

        let collector = DiagnosticCollector()
        let collectorTask = Task {
            for await event in events {
                await collector.record(event)
            }
        }

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if await collector.exitStatus() != nil {
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let exitStatus = await collector.exitStatus()
        if exitStatus == nil {
            await process.stop()
        }
        collectorTask.cancel()

        let states = await collector.states()
        let outputLines = await collector.outputLines()
        for state in states {
            print("state=\(state)")
        }
        print("exit_status=\(exitStatus.map(String.init) ?? "timeout")")
        let summary = diagnoseSummary(from: outputLines)
        print("summary=\(summary)")
        print("recent_output:")
        for line in outputLines.suffix(20) {
            print("- \(line)")
        }
    }

    private static func credentialStatus(_ operation: () throws -> Bool) -> String {
        do {
            return try operation() ? "present" : "missing"
        } catch CredentialStoreError.credentialVaultLocked {
            return "locked"
        } catch CredentialStoreError.keychainInteractionRequired {
            return "locked"
        } catch {
            return "error"
        }
    }

    private static func credentialStore(for settings: VPNProfileSettings) -> any VPNCredentialStore {
        switch settings.credentialStorageMode {
        case .touchIDVault:
            TouchIDVaultCredentialStore()
        case .unsafeLocal:
            UnsafeLocalCredentialStore()
        }
    }

    private static func legacyProfilePath() throws -> String {
        let value = ProcessInfo.processInfo.environment[legacyProfilePathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            throw CredentialToolError.missingLegacyProfilePath(legacyProfilePathEnvironmentKey)
        }
        return value
    }

    private static func diagnoseSummary(from lines: [String]) -> String {
        let text = lines.joined(separator: "\n").lowercased()
        if text.contains("server certificate verify failed")
            || text.contains("certificate from vpn server")
            || text.contains("--servercert")
            || text.contains("fingerprint") {
            return "server_certificate_pin_required_or_changed"
        }
        if text.contains("login failed") || text.contains("authentication failed") {
            return "authentication_failed"
        }
        if text.contains("authgroup") || text.contains("group") {
            return "authgroup_or_group_selection"
        }
        if text.contains("failed to open tun") || text.contains("script") || text.contains("ocproxy") {
            return "script_or_ocproxy_failed"
        }
        return "unknown_openconnect_exit"
    }

    private static func smokeURLs(from environmentKey: String) -> [String] {
        guard let value = ProcessInfo.processInfo.environment[environmentKey] else {
            return []
        }

        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func runCurlCheck(endpoint: SocksEndpoint, url: String) -> CurlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--noproxy", "",
            "-sS",
            "--socks5-hostname", endpoint.address,
            "--connect-timeout", "12",
            "--max-time", "35",
            "-o", "/dev/null",
            "-w", "%{http_code}",
            url
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CurlResult(exitCode: 127, httpCode: "000", errorText: String(describing: error))
        }

        let codeData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let code = String(data: codeData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "000"
        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        return CurlResult(exitCode: process.terminationStatus, httpCode: code, errorText: errorText)
    }

    private static func printError(_ error: Error) {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            fputs("error=\(description)\n", stderr)
        } else {
            fputs("error=\(String(describing: error))\n", stderr)
        }
    }
}

private enum CredentialToolError: Error, LocalizedError {
    case missingLegacyProfilePath(String)

    var errorDescription: String? {
        switch self {
        case .missingLegacyProfilePath(let key):
            "Legacy migration requires \(key) to point to a local profile file."
        }
    }
}

private extension Array where Element == VPNProfileSettings {
    func sortedForStatus() -> [VPNProfileSettings] {
        sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

private struct CurlResult {
    let exitCode: Int32
    let httpCode: String
    let errorText: String

    var label: String {
        if exitCode == 0 {
            return "http_\(httpCode)"
        }
        if errorText.localizedCaseInsensitiveContains("Could not resolve host") {
            return "failed_exit_\(exitCode)_dns_resolution_failed"
        }
        if errorText.localizedCaseInsensitiveContains("SOCKS") || errorText.localizedCaseInsensitiveContains("proxy") {
            return "failed_exit_\(exitCode)_socks_or_proxy_failed"
        }
        if errorText.localizedCaseInsensitiveContains("timed out") {
            return "failed_exit_\(exitCode)_timeout"
        }
        return "failed_exit_\(exitCode)_curl_failed"
    }
}

private actor DiagnosticCollector {
    private var storedOutputLines: [String] = []
    private var storedStates: [ConnectionState] = []
    private var storedExitStatus: Int32?

    func record(_ event: OpenConnectProcessEvent) {
        switch event {
        case .output(_, let text):
            for line in text.split(whereSeparator: \.isNewline).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    storedOutputLines.append(trimmed)
                }
            }
        case .serverCertificatePinSuggested:
            storedStates.append(.failed(message: "Server certificate pin required or changed."))
        case .stateChanged(let state):
            storedStates.append(state)
        case .exited(let status):
            storedExitStatus = status
        case .started:
            break
        }
    }

    func outputLines() -> [String] {
        storedOutputLines
    }

    func states() -> [ConnectionState] {
        storedStates
    }

    func exitStatus() -> Int32? {
        storedExitStatus
    }
}
