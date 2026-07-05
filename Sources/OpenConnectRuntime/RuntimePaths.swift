public struct RuntimePaths: Equatable, Sendable {
    public let openConnectExecutablePath: String
    public let ocproxyExecutablePath: String

    public init(openConnectExecutablePath: String, ocproxyExecutablePath: String) {
        self.openConnectExecutablePath = openConnectExecutablePath
        self.ocproxyExecutablePath = ocproxyExecutablePath
    }
}
