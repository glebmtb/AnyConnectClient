import Darwin
import XCTest
import VPNCore
@testable import OpenConnectRuntime

final class SocksHealthCheckTests: XCTestCase {
    func testHealthCheckSeesListeningEndpoint() async throws {
        let listener = try TestTCPListener()
        let endpoint = try SocksEndpoint(port: listener.port)

        let healthCheck = SocksHealthCheck(connectTimeoutMilliseconds: 100)
        let isListening = await healthCheck.isListening(endpoint: endpoint)

        XCTAssertTrue(isListening)
    }

    func testHealthCheckReportsClosedEndpoint() async throws {
        let listener = try TestTCPListener()
        let endpoint = try SocksEndpoint(port: listener.port)
        listener.close()

        let healthCheck = SocksHealthCheck(connectTimeoutMilliseconds: 100)
        let isListening = await healthCheck.isListening(endpoint: endpoint)

        XCTAssertFalse(isListening)
    }

    func testActiveEndpointRegistryRejectsDuplicateEndpoint() async throws {
        let endpoint = try SocksEndpoint(port: 11080)
        let registry = ActiveSocksEndpointRegistry()

        try await registry.reserve(endpoint)

        do {
            try await registry.reserve(endpoint)
            XCTFail("Expected duplicate endpoint reservation to fail.")
        } catch VPNConnectionError.socksPortUnavailable(let unavailableEndpoint) {
            XCTAssertEqual(unavailableEndpoint, endpoint)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await registry.release(endpoint)
        let containsEndpoint = await registry.contains(endpoint)
        XCTAssertFalse(containsEndpoint)
    }

    func testSharedRegistryAllowsDifferentSessionsAndReleasesIndependently() async throws {
        let firstEndpoint = try SocksEndpoint(port: 11991)
        let secondEndpoint = try SocksEndpoint(port: 11992)
        let executablePath = try makeExecutable(
            name: "connected-openconnect",
            body: """
            echo "CSTP connected" >&2
            sleep 5
            """
        )
        let runtimePaths = RuntimePaths(
            openConnectExecutablePath: executablePath,
            ocproxyExecutablePath: "/bin/cat"
        )
        let registry = ActiveSocksEndpointRegistry()
        let healthCheck = SequencedSocksHealthCheck()
        let configuration = OpenConnectSessionConfiguration(
            startupTimeoutNanoseconds: 2_000_000_000,
            pollIntervalNanoseconds: 10_000_000,
            stopGracePeriodNanoseconds: 10_000_000
        )
        let firstSession = OpenConnectSession(
            runtimePaths: runtimePaths,
            healthCheck: healthCheck,
            endpointRegistry: registry,
            configuration: configuration
        )
        let secondSession = OpenConnectSession(
            runtimePaths: runtimePaths,
            healthCheck: healthCheck,
            endpointRegistry: registry,
            configuration: configuration
        )

        var eventTasks: [Task<Void, Never>] = []
        defer {
            eventTasks.forEach { $0.cancel() }
        }

        let firstStart = try await firstSession.start(
            profile: makeProfile(id: "humo", endpoint: firstEndpoint),
            credentials: VPNCredentials(profileID: "humo", password: "first-password")
        )
        eventTasks.append(Task {
            for await _ in firstStart.events {}
        })

        let secondStart = try await secondSession.start(
            profile: makeProfile(id: "uz", endpoint: secondEndpoint),
            credentials: VPNCredentials(profileID: "uz", password: "second-password")
        )
        eventTasks.append(Task {
            for await _ in secondStart.events {}
        })

        let firstIsReserved = await registry.contains(firstEndpoint)
        let secondIsReserved = await registry.contains(secondEndpoint)
        XCTAssertTrue(firstIsReserved)
        XCTAssertTrue(secondIsReserved)

        await firstSession.stop()
        let firstStillReserved = await registry.contains(firstEndpoint)
        let secondIsStillReserved = await registry.contains(secondEndpoint)
        XCTAssertFalse(firstStillReserved)
        XCTAssertTrue(secondIsStillReserved)

        await secondSession.stop()
        let secondStillReserved = await registry.contains(secondEndpoint)
        XCTAssertFalse(secondStillReserved)
    }

    func testSessionRefusesToStartWhenSocksEndpointIsAlreadyListening() async throws {
        let listener = try TestTCPListener()
        let endpoint = try SocksEndpoint(port: listener.port)
        let profile = try VPNProfile(
            id: "humo",
            displayName: "Humo",
            server: "vpn.example.test",
            username: "test.user",
            authGroup: "RA-VPNS",
            socksEndpoint: endpoint,
            serverCertificatePin: "pin-sha256:FakePinValue123+/="
        )
        let credentials = VPNCredentials(profileID: profile.id, password: "test-password")
        let session = OpenConnectSession(
            runtimePaths: RuntimePaths(
                openConnectExecutablePath: "/bin/cat",
                ocproxyExecutablePath: "/bin/cat"
            ),
            configuration: OpenConnectSessionConfiguration(
                startupTimeoutNanoseconds: 50_000_000,
                pollIntervalNanoseconds: 10_000_000,
                stopGracePeriodNanoseconds: 10_000_000
            )
        )

        do {
            _ = try await session.start(profile: profile, credentials: credentials)
            XCTFail("Expected session start to fail on occupied SOCKS endpoint.")
        } catch VPNConnectionError.socksPortUnavailable(let unavailableEndpoint) {
            XCTAssertEqual(unavailableEndpoint, endpoint)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSessionReportsSocksReadinessTimeoutWhenEndpointNeverListens() async throws {
        let endpoint = try SocksEndpoint(port: 11990)
        let profile = try VPNProfile(
            id: "humo",
            displayName: "Humo",
            server: "vpn.example.test",
            username: "test.user",
            authGroup: "RA-VPNS",
            socksEndpoint: endpoint,
            serverCertificatePin: "pin-sha256:FakePinValue123+/="
        )
        let credentials = VPNCredentials(profileID: profile.id, password: "test-password")
        let sleepingExecutablePath = try makeSleepingExecutable()
        let session = OpenConnectSession(
            runtimePaths: RuntimePaths(
                openConnectExecutablePath: sleepingExecutablePath,
                ocproxyExecutablePath: "/bin/cat"
            ),
            configuration: OpenConnectSessionConfiguration(
                startupTimeoutNanoseconds: 50_000_000,
                pollIntervalNanoseconds: 10_000_000,
                stopGracePeriodNanoseconds: 10_000_000
            )
        )

        do {
            _ = try await session.start(profile: profile, credentials: credentials)
            XCTFail("Expected session start to fail when SOCKS endpoint never becomes ready.")
        } catch VPNConnectionError.socksReadinessTimedOut(let timedOutEndpoint) {
            XCTAssertEqual(timedOutEndpoint, endpoint)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSessionReportsServerCertificateChangedBeforeSocksTimeout() async throws {
        let listener = try TestTCPListener()
        let endpoint = try SocksEndpoint(port: listener.port)
        listener.close()

        let profile = try VPNProfile(
            id: "humo",
            displayName: "Humo",
            server: "vpn.example.test",
            username: "test.user",
            authGroup: "RA-VPNS",
            socksEndpoint: endpoint,
            serverCertificatePin: "pin-sha256:FakePinValue123+/="
        )
        let credentials = VPNCredentials(profileID: profile.id, password: "test-password")
        let failingExecutablePath = try makeExecutable(
            name: "certificate-changed-openconnect",
            body: """
            echo "None of the 1 fingerprint(s) specified via --servercert match server's certificate: pin-sha256:NewPinValue123+/=" >&2
            sleep 1
            exit 1
            """
        )
        let session = OpenConnectSession(
            runtimePaths: RuntimePaths(
                openConnectExecutablePath: failingExecutablePath,
                ocproxyExecutablePath: "/bin/cat"
            ),
            configuration: OpenConnectSessionConfiguration(
                startupTimeoutNanoseconds: 500_000_000,
                pollIntervalNanoseconds: 10_000_000,
                stopGracePeriodNanoseconds: 10_000_000
            )
        )

        do {
            _ = try await session.start(profile: profile, credentials: credentials)
            XCTFail("Expected session start to fail on server certificate pin mismatch.")
        } catch VPNConnectionError.serverCertificateChanged {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSessionCapturesSuggestedServerCertificatePin() async throws {
        let listener = try TestTCPListener()
        let endpoint = try SocksEndpoint(port: listener.port)
        listener.close()

        let pin = "pin-sha256:SuggestedPinValue123+/="
        let profile = try VPNProfile(
            id: "humo",
            displayName: "Humo",
            server: "vpn.example.test",
            username: "test.user",
            authGroup: "RA-VPNS",
            socksEndpoint: endpoint
        )
        let credentials = VPNCredentials(profileID: profile.id, password: "test-password")
        let failingExecutablePath = try makeExecutable(
            name: "certificate-required-openconnect",
            body: """
            echo "Server certificate verify failed: signer not found" >&2
            echo "To trust this server in future, perhaps add this to your command line:" >&2
            echo "--servercert \(pin)" >&2
            sleep 1
            exit 1
            """
        )
        let session = OpenConnectSession(
            runtimePaths: RuntimePaths(
                openConnectExecutablePath: failingExecutablePath,
                ocproxyExecutablePath: "/bin/cat"
            ),
            configuration: OpenConnectSessionConfiguration(
                startupTimeoutNanoseconds: 500_000_000,
                pollIntervalNanoseconds: 10_000_000,
                stopGracePeriodNanoseconds: 10_000_000
            )
        )

        do {
            _ = try await session.start(profile: profile, credentials: credentials)
            XCTFail("Expected session start to fail on missing server certificate pin.")
        } catch VPNConnectionError.serverCertificateChanged {
            let suggestedPin = await session.serverCertificatePinSuggestion()
            XCTAssertEqual(suggestedPin, pin)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class TestTCPListener {
    private var descriptor: Int32 = -1
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(0).bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        self.port = Int(UInt16(bigEndian: boundAddress.sin_port))
        descriptor = fd
    }

    func close() {
        guard descriptor >= 0 else {
            return
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        close()
    }
}

private actor SequencedSocksHealthCheck: SocksHealthChecking {
    private var callCounts: [SocksEndpoint: Int] = [:]

    func isListening(endpoint: SocksEndpoint) async -> Bool {
        let count = callCounts[endpoint, default: 0]
        callCounts[endpoint] = count + 1
        return count > 20
    }

    func waitUntilListening(
        endpoint: SocksEndpoint,
        timeoutNanoseconds: UInt64,
        pollIntervalNanoseconds: UInt64
    ) async -> Bool {
        await isListening(endpoint: endpoint)
    }
}

private func makeProfile(id: VPNProfileID, endpoint: SocksEndpoint) throws -> VPNProfile {
    try VPNProfile(
        id: id,
        displayName: id.rawValue,
        server: "vpn.example.test",
        username: "test.user",
        authGroup: "RA-VPNS",
        socksEndpoint: endpoint,
        serverCertificatePin: "pin-sha256:FakePinValue123+/="
    )
}

private func makeSleepingExecutable() throws -> String {
    try makeExecutable(
        name: "sleeping-process",
        body: "sleep 5"
    )
}

private func makeExecutable(name: String, body: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AnyConnectClientTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let script = directory.appendingPathComponent(name)
    try """
    #!/bin/sh
    \(body)
    """.write(to: script, atomically: true, encoding: .utf8)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script.path
}
