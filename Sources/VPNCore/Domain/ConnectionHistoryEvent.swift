import Foundation

public struct ConnectionHistoryEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case connectRequested
        case connected
        case reconnectScheduled
        case disconnected
        case failed
    }

    public let profileID: VPNProfileID
    public let timestamp: Date
    public let kind: Kind
    public let message: String?
    public let reconnectAttempt: Int?

    public init(
        profileID: VPNProfileID,
        timestamp: Date,
        kind: Kind,
        message: String? = nil,
        reconnectAttempt: Int? = nil
    ) {
        self.profileID = profileID
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.reconnectAttempt = reconnectAttempt
    }
}
