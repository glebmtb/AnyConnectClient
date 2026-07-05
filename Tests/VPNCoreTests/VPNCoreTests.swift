import XCTest
@testable import VPNCore

final class VPNCoreTests: XCTestCase {
    func testSocksEndpointRejectsInvalidPort() {
        XCTAssertThrowsError(try SocksEndpoint(port: 0)) { error in
            XCTAssertEqual(error as? VPNProfileValidationError, .invalidSocksPort(0))
        }
    }

    func testProfileCatalogRejectsDuplicateSocksEndpoint() throws {
        let endpoint = try SocksEndpoint(port: 11080)
        let first = try makeProfile(id: "office", endpoint: endpoint)
        let second = try makeProfile(id: "dev", endpoint: endpoint)

        XCTAssertThrowsError(try VPNProfileCatalog(profiles: [first, second])) { error in
            XCTAssertEqual(error as? VPNProfileValidationError, .duplicateSocksEndpoint(endpoint))
        }
    }

    func testProfileCatalogAcceptsUniquePorts() throws {
        let first = try makeProfile(id: "office", endpoint: try SocksEndpoint(port: 11080))
        let second = try makeProfile(id: "dev", endpoint: try SocksEndpoint(port: 11081))

        let catalog = try VPNProfileCatalog(profiles: [first, second])

        XCTAssertEqual(catalog.profiles.map(\.id), ["office", "dev"])
    }

    func testRedactorMasksLiteralSecretsAndKnownPatterns() {
        let redactor = Redactor(literalSecrets: ["hunter2"])
        let input = """
        password=hunter2 token=abcdef Cookie: session-id
        --servercert=pin-sha256:AbCdEf123+/=
        """

        let output = redactor.redact(input)

        XCTAssertFalse(output.contains("hunter2"))
        XCTAssertFalse(output.contains("abcdef"))
        XCTAssertFalse(output.contains("session-id"))
        XCTAssertFalse(output.contains("AbCdEf123"))
        XCTAssertTrue(output.contains("password=<redacted>"))
        XCTAssertTrue(output.contains("token=<redacted>"))
        XCTAssertTrue(output.contains("--servercert=<redacted>"))
    }

    func testConnectionErrorsExposeUserFacingDescriptions() throws {
        let endpoint = try SocksEndpoint(port: 11080)
        let error = VPNConnectionError.socksReadinessTimedOut(endpoint)

        XCTAssertEqual(
            error.errorDescription,
            "SOCKS endpoint 127.0.0.1:11080 did not become ready after OpenConnect started."
        )

        XCTAssertEqual(
            VPNConnectionError.serverCertificateChanged.errorDescription,
            "Server certificate changed. Review and update the trusted server pin before reconnecting."
        )

        XCTAssertEqual(
            VPNConnectionError.vpnReadinessTimedOut(endpoint).errorDescription,
            "OpenConnect did not report a ready VPN tunnel for SOCKS endpoint 127.0.0.1:11080."
        )
    }

    private func makeProfile(id: VPNProfileID, endpoint: SocksEndpoint) throws -> VPNProfile {
        try VPNProfile(
            id: id,
            displayName: id.rawValue,
            server: "vpn.example.test",
            username: "user",
            authGroup: "RA-VPNS",
            socksEndpoint: endpoint
        )
    }
}
