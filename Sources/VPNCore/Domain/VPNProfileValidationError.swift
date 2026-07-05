import Foundation

public enum VPNProfileValidationError: Error, Equatable, Sendable {
    case emptyDisplayName
    case emptyServer
    case emptyUsername
    case emptySocksHost
    case invalidSocksHost(String)
    case invalidSocksPort(Int)
    case duplicateProfileID(VPNProfileID)
    case duplicateSocksEndpoint(SocksEndpoint)
}

extension VPNProfileValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyDisplayName:
            "display name is empty"
        case .emptyServer:
            "VPN server is empty"
        case .emptyUsername:
            "VPN username is empty"
        case .emptySocksHost:
            "SOCKS host is empty"
        case .invalidSocksHost(let host):
            "SOCKS host is invalid: \(host)"
        case .invalidSocksPort(let port):
            "SOCKS port is invalid: \(port)"
        case .duplicateProfileID(let profileID):
            "profile id is duplicated: \(profileID.rawValue)"
        case .duplicateSocksEndpoint(let endpoint):
            "SOCKS endpoint is duplicated: \(endpoint.address)"
        }
    }
}
