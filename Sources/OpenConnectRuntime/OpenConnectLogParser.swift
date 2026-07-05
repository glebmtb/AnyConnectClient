import VPNCore

public struct OpenConnectLogParser: Sendable {
    public init() {}

    public func parseLine(_ line: String) -> ConnectionState? {
        let lowercased = line.lowercased()

        if lowercased.contains("fingerprint(s) specified via --servercert match server's certificate")
            || lowercased.contains("could not check server's certificate against") {
            return .failed(message: "Server certificate changed; update trusted pin to connect.")
        }

        if lowercased.contains("login failed") || lowercased.contains("authentication failed") {
            return .failed(message: "Authentication failed")
        }

        if lowercased.contains("failed to") || lowercased.contains("error") {
            return .failed(message: line.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if lowercased.contains("reconnect") || lowercased.contains("reconnecting") {
            return .reconnecting(attempt: 0)
        }

        if lowercased.contains("please enter your username and password")
            || lowercased.contains("password:") {
            return .authenticating
        }

        if lowercased.contains("cstp connected")
            || lowercased.contains("configured as")
            || lowercased.contains("established dtls connection") {
            return .connected
        }

        if lowercased.contains("connected to ")
            || lowercased.contains("ssl negotiation")
            || lowercased.contains("got connect response") {
            return .connecting
        }

        if lowercased.contains("vpn connection has terminated") {
            return .stopped
        }

        return nil
    }
}
