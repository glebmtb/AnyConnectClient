public struct SocksEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw VPNProfileValidationError.emptySocksHost
        }
        guard normalizedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw VPNProfileValidationError.invalidSocksHost(host)
        }
        guard (1...65535).contains(port) else {
            throw VPNProfileValidationError.invalidSocksPort(port)
        }

        self.host = normalizedHost
        self.port = port
    }

    public var address: String {
        "\(host):\(port)"
    }
}
