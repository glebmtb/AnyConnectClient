import XCTest
import VPNCore
@testable import OpenConnectRuntime

final class OpenConnectProcessTests: XCTestCase {
    func testLaunchesExecutableAndStreamsOutput() async throws {
        let process = OpenConnectProcess()
        let stream = try await process.start(
            invocation: CommandInvocation(
                executablePath: "/bin/echo",
                arguments: ["Usage:", "--protocol=anyconnect"]
            )
        )

        let events = await collect(stream)
        let output = joinedOutput(events)

        XCTAssertTrue(events.contains { event in
            if case .started = event { return true }
            return false
        })
        XCTAssertTrue(output.contains("Usage:"))
        XCTAssertTrue(output.contains("--protocol=anyconnect"))
        XCTAssertTrue(events.contains(.exited(status: 0)))
    }

    func testWritesStandardInputAndStreamsRedactedOutput() async throws {
        let process = OpenConnectProcess()
        let stream = try await process.start(
            invocation: CommandInvocation(executablePath: "/bin/cat", arguments: []),
            standardInput: "hello-runner secret-password",
            redactor: Redactor(literalSecrets: ["secret-password"])
        )

        let events = await collect(stream)
        let output = joinedOutput(events)

        XCTAssertTrue(output.contains("hello-runner"))
        XCTAssertTrue(output.contains("<redacted>"))
        XCTAssertFalse(output.contains("secret-password"))
        XCTAssertTrue(events.contains(.exited(status: 0)))
    }

    func testEmitsServerCertificatePinSuggestionWithoutLeakingToOutput() async throws {
        let pin = "pin-sha256:SecretPin123+/="
        let process = OpenConnectProcess()
        let stream = try await process.start(
            invocation: CommandInvocation(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "echo 'To trust this server, add --servercert \(pin)' >&2; exit 1"
                ]
            )
        )

        let events = await collect(stream)
        let output = joinedOutput(events)

        XCTAssertTrue(events.contains(.serverCertificatePinSuggested(pin)))
        XCTAssertTrue(output.contains("pin-sha256:<redacted>"))
        XCTAssertFalse(output.contains(pin))
    }

    func testStopTerminatesRunningProcess() async throws {
        let process = OpenConnectProcess()
        let stream = try await process.start(
            invocation: CommandInvocation(executablePath: "/bin/sleep", arguments: ["30"])
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        await process.stop(gracePeriodNanoseconds: 50_000_000)

        let events = await collect(stream)

        XCTAssertTrue(events.contains { event in
            if case .exited = event { return true }
            return false
        })
        let isRunning = await process.isRunning
        XCTAssertFalse(isRunning)
    }

    func testLogParserMapsOpenConnectLinesToStates() {
        let parser = OpenConnectLogParser()

        XCTAssertEqual(
            parser.parseLine("Please enter your username and password."),
            .authenticating
        )
        XCTAssertEqual(
            parser.parseLine("CSTP connected. DPD 30, Keepalive 20"),
            .connected
        )
        XCTAssertEqual(
            parser.parseLine("Established DTLS connection (using GnuTLS)."),
            .connected
        )
        XCTAssertEqual(
            parser.parseLine("Login failed."),
            .failed(message: "Authentication failed")
        )
        XCTAssertEqual(
            parser.parseLine("None of the 1 fingerprint(s) specified via --servercert match server's certificate: pin-sha256:<redacted>"),
            .failed(message: "Server certificate changed; update trusted pin to connect.")
        )
        XCTAssertEqual(
            parser.parseLine("ocproxy: VPN connection has terminated"),
            .stopped
        )
    }

    private func collect(
        _ stream: AsyncStream<OpenConnectProcessEvent>
    ) async -> [OpenConnectProcessEvent] {
        var events: [OpenConnectProcessEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private func joinedOutput(_ events: [OpenConnectProcessEvent]) -> String {
        events.compactMap { event in
            if case let .output(_, text) = event {
                return text
            }
            return nil
        }
        .joined()
    }
}
