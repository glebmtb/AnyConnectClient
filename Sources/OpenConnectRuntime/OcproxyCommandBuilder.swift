import VPNCore

public struct OcproxyCommandBuilder: Sendable {
    public struct Options: Equatable, Sendable {
        public let keepaliveSeconds: Int

        public init(keepaliveSeconds: Int = 30) {
            self.keepaliveSeconds = keepaliveSeconds
        }
    }

    public init() {}

    public func buildScriptCommand(
        executablePath: String,
        endpoint: SocksEndpoint,
        options: Options = Options()
    ) -> String {
        [
            Self.shellQuote(executablePath),
            "-D",
            endpoint.address,
            "-k",
            String(options.keepaliveSeconds)
        ].joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("'") else {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
