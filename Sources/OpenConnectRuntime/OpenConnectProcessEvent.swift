import VPNCore

public enum ProcessOutputStream: String, Equatable, Sendable {
    case standardOutput
    case standardError
}

public enum OpenConnectProcessEvent: Equatable, Sendable {
    case started(processIdentifier: Int32)
    case output(stream: ProcessOutputStream, text: String)
    case serverCertificatePinSuggested(String)
    case stateChanged(ConnectionState)
    case exited(status: Int32)
}
