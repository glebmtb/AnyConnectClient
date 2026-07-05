import Dispatch
import VPNCore

public struct OpenConnectSessionConfiguration: Equatable, Sendable {
    public let startupTimeoutNanoseconds: UInt64
    public let pollIntervalNanoseconds: UInt64
    public let stopGracePeriodNanoseconds: UInt64

    public init(
        startupTimeoutNanoseconds: UInt64 = 15_000_000_000,
        pollIntervalNanoseconds: UInt64 = 200_000_000,
        stopGracePeriodNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.startupTimeoutNanoseconds = startupTimeoutNanoseconds
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.stopGracePeriodNanoseconds = stopGracePeriodNanoseconds
    }
}

public struct OpenConnectSessionStart: Sendable {
    public let profileID: VPNProfileID
    public let socksEndpoint: SocksEndpoint
    public let events: AsyncStream<OpenConnectProcessEvent>
}

public struct OpenConnectSessionRuntimeSnapshot: Equatable, Sendable {
    public let openConnectProcessIdentifier: Int32?
    public let ocproxyProcessIdentifier: Int32?
    public let activeEndpoint: SocksEndpoint?
}

public actor OpenConnectSession {
    private let runtimePaths: RuntimePaths
    private let commandBuilder: OpenConnectCommandBuilder
    private let process: OpenConnectProcess
    private let healthCheck: any SocksHealthChecking
    private let endpointRegistry: ActiveSocksEndpointRegistry
    private let configuration: OpenConnectSessionConfiguration

    private var activeEndpoint: SocksEndpoint?
    private var relayTask: Task<Void, Never>?
    private var ocproxyWrapper: OcproxyScriptWrapper?
    private var startupFailure: VPNConnectionError?
    private var startupExitStatus: Int32?
    private var startupReachedConnected = false
    private var startupSuggestedServerCertificatePin: String?

    public init(
        runtimePaths: RuntimePaths,
        commandBuilder: OpenConnectCommandBuilder = OpenConnectCommandBuilder(),
        process: OpenConnectProcess = OpenConnectProcess(),
        healthCheck: any SocksHealthChecking = SocksHealthCheck(),
        endpointRegistry: ActiveSocksEndpointRegistry = ActiveSocksEndpointRegistry(),
        configuration: OpenConnectSessionConfiguration = OpenConnectSessionConfiguration()
    ) {
        self.runtimePaths = runtimePaths
        self.commandBuilder = commandBuilder
        self.process = process
        self.healthCheck = healthCheck
        self.endpointRegistry = endpointRegistry
        self.configuration = configuration
    }

    public func start(
        profile: VPNProfile,
        credentials: VPNCredentials,
        options: OpenConnectCommandBuilder.Options = OpenConnectCommandBuilder.Options(),
        redactor: Redactor = .default
    ) async throws -> OpenConnectSessionStart {
        guard credentials.profileID == profile.id else {
            throw VPNConnectionError.authenticationFailed
        }

        guard await !healthCheck.isListening(endpoint: profile.socksEndpoint) else {
            throw VPNConnectionError.socksPortUnavailable(profile.socksEndpoint)
        }

        try await endpointRegistry.reserve(profile.socksEndpoint)

        do {
            startupFailure = nil
            startupExitStatus = nil
            startupReachedConnected = false
            startupSuggestedServerCertificatePin = nil

            let ocproxyWrapper = try OcproxyScriptWrapper.install(
                realExecutablePath: runtimePaths.ocproxyExecutablePath
            )
            self.ocproxyWrapper = ocproxyWrapper

            let invocation = commandBuilder.build(
                profile: profile,
                runtimePaths: ocproxyWrapper.runtimePaths(from: runtimePaths),
                options: options
            )

            let processEvents = try await process.start(
                invocation: invocation,
                standardInput: credentials.password,
                redactor: redactor
            )

            let relay = relay(processEvents, endpoint: profile.socksEndpoint)
            activeEndpoint = profile.socksEndpoint

            let becameReady = try await waitForSocksReadiness(endpoint: profile.socksEndpoint)

            guard becameReady else {
                await stop()
                throw VPNConnectionError.socksReadinessTimedOut(profile.socksEndpoint)
            }

            return OpenConnectSessionStart(
                profileID: profile.id,
                socksEndpoint: profile.socksEndpoint,
                events: relay
            )
        } catch {
            await stop()
            await endpointRegistry.release(profile.socksEndpoint)
            activeEndpoint = nil
            throw error
        }
    }

    public func stop() async {
        await process.stop(gracePeriodNanoseconds: configuration.stopGracePeriodNanoseconds)
        await ocproxyWrapper?.stop(gracePeriodNanoseconds: configuration.stopGracePeriodNanoseconds)
        ocproxyWrapper = nil

        relayTask?.cancel()
        relayTask = nil

        if let activeEndpoint {
            await endpointRegistry.release(activeEndpoint)
            self.activeEndpoint = nil
        }
    }

    public func isActive(endpoint: SocksEndpoint) async -> Bool {
        await endpointRegistry.contains(endpoint)
    }

    public func serverCertificatePinSuggestion() -> String? {
        startupSuggestedServerCertificatePin
    }

    public func runtimeSnapshot() async -> OpenConnectSessionRuntimeSnapshot {
        OpenConnectSessionRuntimeSnapshot(
            openConnectProcessIdentifier: await process.processIdentifier(),
            ocproxyProcessIdentifier: ocproxyWrapper?.processIdentifier(),
            activeEndpoint: activeEndpoint
        )
    }

    public func routeImportSnapshot() -> RouteImportSnapshot {
        ocproxyWrapper?.routeImportSnapshot() ?? RouteImportSnapshot()
    }

    private func relay(
        _ processEvents: AsyncStream<OpenConnectProcessEvent>,
        endpoint: SocksEndpoint
    ) -> AsyncStream<OpenConnectProcessEvent> {
        let streamPair = AsyncStream<OpenConnectProcessEvent>.makeStream()
        let continuation = streamPair.continuation

        relayTask?.cancel()
        relayTask = Task { [endpointRegistry] in
            for await event in processEvents {
                self.recordStartupEvent(event)
                continuation.yield(event)
                if case .exited = event {
                    await self.cleanupAfterProcessExit(endpoint: endpoint)
                    continuation.finish()
                    return
                }
            }
            await endpointRegistry.release(endpoint)
            continuation.finish()
        }

        continuation.onTermination = { @Sendable _ in
            Task { await self.stop() }
        }

        return streamPair.stream
    }

    private func waitForSocksReadiness(endpoint: SocksEndpoint) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + configuration.startupTimeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let endpointIsListening = await healthCheck.isListening(endpoint: endpoint)
            if endpointIsListening, startupReachedConnected {
                return true
            }
            if let startupFailure {
                throw startupFailure
            }
            if let startupExitStatus {
                try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                if let startupFailure {
                    throw startupFailure
                }
                throw VPNConnectionError.processExited(startupExitStatus)
            }
            try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
        }

        let endpointIsListening = await healthCheck.isListening(endpoint: endpoint)
        if endpointIsListening, startupReachedConnected {
            return true
        }
        if endpointIsListening {
            throw VPNConnectionError.vpnReadinessTimedOut(endpoint)
        }
        if let startupFailure {
            throw startupFailure
        }
        if let startupExitStatus {
            try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
            if let startupFailure {
                throw startupFailure
            }
            throw VPNConnectionError.processExited(startupExitStatus)
        }

        return false
    }

    private func recordStartupEvent(_ event: OpenConnectProcessEvent) {
        switch event {
        case .serverCertificatePinSuggested(let pin):
            startupSuggestedServerCertificatePin = pin
            startupFailure = .serverCertificateChanged
        case .stateChanged(.failed(let message)):
            let lowercased = message.lowercased()
            if lowercased.contains("server certificate changed") {
                startupFailure = .serverCertificateChanged
            } else if lowercased.contains("authentication failed") {
                startupFailure = .authenticationFailed
            }
        case .stateChanged(.connected):
            startupReachedConnected = true
        case .exited(let status):
            startupExitStatus = status
        case .started, .output, .stateChanged:
            break
        }
    }

    private func cleanupAfterProcessExit(endpoint: SocksEndpoint) async {
        await endpointRegistry.release(endpoint)

        if activeEndpoint == endpoint {
            activeEndpoint = nil
        }

        await ocproxyWrapper?.stop(gracePeriodNanoseconds: configuration.stopGracePeriodNanoseconds)
        ocproxyWrapper = nil
    }
}
