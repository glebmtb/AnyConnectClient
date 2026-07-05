public struct VPNCredentials: Equatable, Sendable {
    public let profileID: VPNProfileID
    public let password: String

    public init(profileID: VPNProfileID, password: String) {
        self.profileID = profileID
        self.password = password
    }
}
