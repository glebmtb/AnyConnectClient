import VPNCore

public actor ActiveSocksEndpointRegistry {
    private var endpoints = Set<SocksEndpoint>()

    public init() {}

    public func reserve(_ endpoint: SocksEndpoint) throws {
        guard endpoints.insert(endpoint).inserted else {
            throw VPNConnectionError.socksPortUnavailable(endpoint)
        }
    }

    public func release(_ endpoint: SocksEndpoint) {
        endpoints.remove(endpoint)
    }

    public func contains(_ endpoint: SocksEndpoint) -> Bool {
        endpoints.contains(endpoint)
    }
}
