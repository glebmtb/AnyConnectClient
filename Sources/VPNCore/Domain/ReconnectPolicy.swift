public struct ReconnectPolicy: Codable, Equatable, Hashable, Sendable {
    public let reconnectOnNetworkChange: Bool
    public let reconnectOnWake: Bool
    public let maximumAttempts: Int
    public let initialDelaySeconds: Int

    public init(
        reconnectOnNetworkChange: Bool,
        reconnectOnWake: Bool,
        maximumAttempts: Int,
        initialDelaySeconds: Int
    ) {
        self.reconnectOnNetworkChange = reconnectOnNetworkChange
        self.reconnectOnWake = reconnectOnWake
        self.maximumAttempts = maximumAttempts
        self.initialDelaySeconds = initialDelaySeconds
    }

    public static let `default` = ReconnectPolicy(
        reconnectOnNetworkChange: true,
        reconnectOnWake: true,
        maximumAttempts: 0,
        initialDelaySeconds: 2
    )
}
