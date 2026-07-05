import XCTest
import VPNCore
@testable import OpenConnectRuntime

final class OpenConnectCommandBuilderTests: XCTestCase {
    func testBuildsSmokeTestCommandShape() throws {
        let profile = try makeProfile()
        let invocation = OpenConnectCommandBuilder().build(
            profile: profile,
            runtimePaths: runtimePaths
        )

        XCTAssertEqual(invocation.executablePath, "/opt/AnyConnect Runtime/openconnect")
        XCTAssertEqual(invocation.arguments, [
            "--protocol=anyconnect",
            "--user=test.user",
            "--authgroup=RA-VPNS",
            "--passwd-on-stdin",
            "--servercert=pin-sha256:FakePinValue123+/=",
            "--script-tun",
            "--script='/opt/AnyConnect Runtime/ocproxy' -D 127.0.0.1:11080 -k 30",
            "--os=mac-intel",
            "vpn.example.test"
        ])
    }

    func testPasswordIsNotPartOfCommandArguments() throws {
        let profile = try makeProfile()
        let credentials = VPNCredentials(profileID: profile.id, password: "super-secret-password")

        let invocation = OpenConnectCommandBuilder().build(
            profile: profile,
            runtimePaths: runtimePaths
        )

        let argv = invocation.arguments.joined(separator: " ")
        XCTAssertFalse(argv.contains(credentials.password))
        XCTAssertTrue(argv.contains("--passwd-on-stdin"))
    }

    func testRedactedDescriptionMasksServerCertificatePin() throws {
        let profile = try makeProfile()
        let invocation = OpenConnectCommandBuilder().build(
            profile: profile,
            runtimePaths: runtimePaths
        )

        let description = invocation.redactedDescription()

        XCTAssertFalse(description.contains("FakePinValue123"))
        XCTAssertTrue(description.contains("--servercert=<redacted>"))
    }

    func testOptionalNetworkFlagsAreIncludedOnlyWhenRequested() throws {
        let profile = try makeProfile(serverCertificatePin: nil)
        let invocation = OpenConnectCommandBuilder().build(
            profile: profile,
            runtimePaths: runtimePaths,
            options: .init(
                disableIPv6: true,
                disableDTLS: true,
                caFilePath: "/tmp/ca.pem",
                resolveHost: "vpn.example.test:203.0.113.10",
                sniHost: "vpn.example.test"
            )
        )

        XCTAssertTrue(invocation.arguments.contains("--disable-ipv6"))
        XCTAssertTrue(invocation.arguments.contains("--no-dtls"))
        XCTAssertTrue(invocation.arguments.contains("--cafile=/tmp/ca.pem"))
        XCTAssertTrue(invocation.arguments.contains("--resolve=vpn.example.test:203.0.113.10"))
        XCTAssertTrue(invocation.arguments.contains("--sni=vpn.example.test"))
        XCTAssertFalse(invocation.arguments.contains { $0.hasPrefix("--servercert=") })
    }

    private var runtimePaths: RuntimePaths {
        RuntimePaths(
            openConnectExecutablePath: "/opt/AnyConnect Runtime/openconnect",
            ocproxyExecutablePath: "/opt/AnyConnect Runtime/ocproxy"
        )
    }

    private func makeProfile(
        serverCertificatePin: String? = "pin-sha256:FakePinValue123+/="
    ) throws -> VPNProfile {
        try VPNProfile(
            id: "humo",
            displayName: "Humo",
            server: "vpn.example.test",
            username: "test.user",
            authGroup: "RA-VPNS",
            socksEndpoint: try SocksEndpoint(port: 11080),
            serverCertificatePin: serverCertificatePin
        )
    }
}
