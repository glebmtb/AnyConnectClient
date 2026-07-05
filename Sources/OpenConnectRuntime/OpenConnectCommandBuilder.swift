import VPNCore

public struct OpenConnectCommandBuilder: Sendable {
    public struct Options: Equatable, Sendable {
        public let reportedOS: String
        public let ocproxyKeepaliveSeconds: Int
        public let disableIPv6: Bool
        public let disableDTLS: Bool
        public let caFilePath: String?
        public let resolveHost: String?
        public let sniHost: String?

        public init(
            reportedOS: String = "mac-intel",
            ocproxyKeepaliveSeconds: Int = 30,
            disableIPv6: Bool = false,
            disableDTLS: Bool = false,
            caFilePath: String? = nil,
            resolveHost: String? = nil,
            sniHost: String? = nil
        ) {
            self.reportedOS = reportedOS
            self.ocproxyKeepaliveSeconds = ocproxyKeepaliveSeconds
            self.disableIPv6 = disableIPv6
            self.disableDTLS = disableDTLS
            self.caFilePath = caFilePath
            self.resolveHost = resolveHost
            self.sniHost = sniHost
        }
    }

    private let ocproxyCommandBuilder: OcproxyCommandBuilder

    public init(ocproxyCommandBuilder: OcproxyCommandBuilder = OcproxyCommandBuilder()) {
        self.ocproxyCommandBuilder = ocproxyCommandBuilder
    }

    public func build(
        profile: VPNProfile,
        runtimePaths: RuntimePaths,
        options: Options = Options()
    ) -> CommandInvocation {
        let ocproxyScript = ocproxyCommandBuilder.buildScriptCommand(
            executablePath: runtimePaths.ocproxyExecutablePath,
            endpoint: profile.socksEndpoint,
            options: .init(keepaliveSeconds: options.ocproxyKeepaliveSeconds)
        )

        var arguments: [String] = [
            "--protocol=\(profile.vpnProtocol.rawValue)",
            "--user=\(profile.username)"
        ]

        if let authGroup = profile.authGroup {
            arguments.append("--authgroup=\(authGroup)")
        }

        arguments.append("--passwd-on-stdin")

        if let serverCertificatePin = profile.serverCertificatePin {
            arguments.append("--servercert=\(serverCertificatePin)")
        }

        arguments.append(contentsOf: [
            "--script-tun",
            "--script=\(ocproxyScript)",
            "--os=\(options.reportedOS)"
        ])

        if options.disableIPv6 {
            arguments.append("--disable-ipv6")
        }

        if options.disableDTLS {
            arguments.append("--no-dtls")
        }

        if let caFilePath = options.caFilePath {
            arguments.append("--cafile=\(caFilePath)")
        }

        if let resolveHost = options.resolveHost {
            arguments.append("--resolve=\(resolveHost)")
        }

        if let sniHost = options.sniHost {
            arguments.append("--sni=\(sniHost)")
        }

        arguments.append(profile.server)

        return CommandInvocation(
            executablePath: runtimePaths.openConnectExecutablePath,
            arguments: arguments
        )
    }
}
