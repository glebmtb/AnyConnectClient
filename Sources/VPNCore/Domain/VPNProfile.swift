public struct VPNProfile: Codable, Equatable, Hashable, Sendable {
    public let id: VPNProfileID
    public let displayName: String
    public let vpnProtocol: VPNProtocol
    public let server: String
    public let username: String
    public let authGroup: String?
    public let socksEndpoint: SocksEndpoint
    public let serverCertificatePin: String?
    public let reconnectPolicy: ReconnectPolicy

    public init(
        id: VPNProfileID,
        displayName: String,
        vpnProtocol: VPNProtocol = .anyconnect,
        server: String,
        username: String,
        authGroup: String? = nil,
        socksEndpoint: SocksEndpoint,
        serverCertificatePin: String? = nil,
        reconnectPolicy: ReconnectPolicy = .default
    ) throws {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAuthGroup = authGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPin = serverCertificatePin?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedDisplayName.isEmpty else {
            throw VPNProfileValidationError.emptyDisplayName
        }
        guard !normalizedServer.isEmpty else {
            throw VPNProfileValidationError.emptyServer
        }
        guard !normalizedUsername.isEmpty else {
            throw VPNProfileValidationError.emptyUsername
        }

        self.id = id
        self.displayName = normalizedDisplayName
        self.vpnProtocol = vpnProtocol
        self.server = normalizedServer
        self.username = normalizedUsername
        self.authGroup = normalizedAuthGroup?.isEmpty == true ? nil : normalizedAuthGroup
        self.socksEndpoint = socksEndpoint
        self.serverCertificatePin = normalizedPin?.isEmpty == true ? nil : normalizedPin
        self.reconnectPolicy = reconnectPolicy
    }
}
