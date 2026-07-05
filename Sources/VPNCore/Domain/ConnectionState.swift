public enum ConnectionState: Equatable, Sendable {
    case stopped
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case disconnecting
    case failed(message: String)
}
