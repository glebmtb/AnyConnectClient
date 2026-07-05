import XCTest
@testable import OpenConnectRuntime

final class OcproxyScriptWrapperTests: XCTestCase {
    func testWrapperStopsExecedOcproxyProcess() async throws {
        let fakeOcproxyPath = try makeFakeOcproxy()
        let wrapper = try OcproxyScriptWrapper.install(realExecutablePath: fakeOcproxyPath)
        let process = Process()

        process.executableURL = URL(fileURLWithPath: wrapper.executablePath)
        process.arguments = ["-D", "127.0.0.1:11999", "-k", "30"]
        try process.run()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(process.isRunning)

        await wrapper.stop(gracePeriodNanoseconds: 50_000_000)
        process.waitUntilExit()

        XCTAssertFalse(process.isRunning)
    }

    func testWrapperCapturesRouteImportEnvironmentOnly() async throws {
        let fakeOcproxyPath = try makeFakeOcproxy()
        let wrapper = try OcproxyScriptWrapper.install(realExecutablePath: fakeOcproxyPath)
        let process = Process()

        process.executableURL = URL(fileURLWithPath: wrapper.executablePath)
        process.arguments = ["-D", "127.0.0.1:11999", "-k", "30"]
        process.environment = [
            "CISCO_SPLIT_INC": "2",
            "CISCO_SPLIT_INC_0_ADDR": "10.0.0.0",
            "CISCO_SPLIT_INC_0_MASK": "255.0.0.0",
            "CISCO_SPLIT_INC_1_ADDR": "192.168.10.0",
            "CISCO_SPLIT_INC_1_MASKLEN": "24",
            "CISCO_SPLIT_EXC": "1",
            "CISCO_SPLIT_EXC_0_ADDR": "172.16.0.0",
            "CISCO_SPLIT_EXC_0_MASKLEN": "12",
            "COOKIE": "secret-cookie",
            "INTERNAL_IP4_DNS": "192.0.2.53"
        ]
        try process.run()

        let rawSnapshot = try await waitForRouteImportFile(wrapper.routeImportFilePath)
        let snapshot = wrapper.routeImportSnapshot()

        await wrapper.stop(gracePeriodNanoseconds: 50_000_000)
        process.waitUntilExit()

        XCTAssertFalse(rawSnapshot.contains("secret-cookie"))
        XCTAssertFalse(rawSnapshot.contains("192.0.2.53"))
        XCTAssertEqual(snapshot.ipv4Includes, ["10.0.0.0/8", "192.168.10.0/24"])
        XCTAssertEqual(snapshot.ipv4Excludes, ["172.16.0.0/12"])
        XCTAssertFalse(snapshot.formattedText.contains("secret-cookie"))
        XCTAssertFalse(snapshot.formattedText.contains("192.0.2.53"))
    }

    func testRouteImportParserFormatsIPv6AndPortAnnotations() {
        let snapshot = RouteImportParser().parse(
            """
            CISCO_IPV6_SPLIT_INC=1
            CISCO_IPV6_SPLIT_INC_0_ADDR=fd00:1234::0
            CISCO_IPV6_SPLIT_INC_0_MASKLEN=64
            CISCO_SPLIT_INC=1
            CISCO_SPLIT_INC_0_ADDR=203.0.113.10
            CISCO_SPLIT_INC_0_MASKLEN=32
            CISCO_SPLIT_INC_0_PROTOCOL=6
            CISCO_SPLIT_INC_0_DPORT=443
            """
        )

        XCTAssertEqual(snapshot.ipv6Includes, ["fd00:1234::0/64"])
        XCTAssertEqual(snapshot.ipv4Includes, ["203.0.113.10/32  (proto 6, dport 443)"])
        XCTAssertEqual(snapshot.routeCount, 2)
    }

    private func makeFakeOcproxy() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyConnectClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = directory.appendingPathComponent("fake-ocproxy")
        try """
        #!/bin/sh
        /bin/sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func waitForRouteImportFile(_ path: String) async throws -> String {
        for _ in 0..<20 {
            if let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty {
                return content
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
