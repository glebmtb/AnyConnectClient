import Foundation

struct AppVersion: Equatable, Sendable {
    let name: String
    let marketingVersion: String
    let buildNumber: String

    static let current = AppVersion(
        name: "AnyConnectClient",
        marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    )

    var menuTitle: String {
        "\(name) \(marketingVersion) (build \(buildNumber))"
    }
}
