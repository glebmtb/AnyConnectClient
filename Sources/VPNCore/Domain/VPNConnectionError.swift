import Foundation

public enum VPNConnectionError: Error, Equatable, Sendable {
    case invalidProfile(VPNProfileValidationError)
    case runtimeNotFound(String)
    case authenticationFailed
    case serverCertificateChanged
    case socksPortUnavailable(SocksEndpoint)
    case socksReadinessTimedOut(SocksEndpoint)
    case vpnReadinessTimedOut(SocksEndpoint)
    case processExited(Int32)
    case cancelled
    case unknown(String)
}

extension VPNConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let validationError):
            "Invalid VPN profile: \(validationError.localizedDescription)"
        case .runtimeNotFound(let path):
            "Runtime executable is missing or not executable: \(path)"
        case .authenticationFailed:
            "Authentication failed. Check the profile username, password, and auth group."
        case .serverCertificateChanged:
            "Server certificate changed. Review and update the trusted server pin before reconnecting."
        case .socksPortUnavailable(let endpoint):
            "SOCKS endpoint \(endpoint.address) is already in use."
        case .socksReadinessTimedOut(let endpoint):
            "SOCKS endpoint \(endpoint.address) did not become ready after OpenConnect started."
        case .vpnReadinessTimedOut(let endpoint):
            "OpenConnect did not report a ready VPN tunnel for SOCKS endpoint \(endpoint.address)."
        case .processExited(let status):
            "OpenConnect exited with status \(status)."
        case .cancelled:
            "Connection was cancelled."
        case .unknown(let message):
            message
        }
    }
}
