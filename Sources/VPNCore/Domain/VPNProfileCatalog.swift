public struct VPNProfileCatalog: Equatable, Sendable {
    public let profiles: [VPNProfile]

    public init(profiles: [VPNProfile]) throws {
        var seenIDs = Set<VPNProfileID>()
        var seenEndpoints = Set<SocksEndpoint>()

        for profile in profiles {
            guard seenIDs.insert(profile.id).inserted else {
                throw VPNProfileValidationError.duplicateProfileID(profile.id)
            }
            guard seenEndpoints.insert(profile.socksEndpoint).inserted else {
                throw VPNProfileValidationError.duplicateSocksEndpoint(profile.socksEndpoint)
            }
        }

        self.profiles = profiles
    }
}
