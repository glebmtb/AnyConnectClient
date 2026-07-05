import Foundation

public enum OpenConnectProcessError: Error, Equatable, Sendable {
    case alreadyRunning
    case executableNotFound(String)
    case launchFailed(String)
}

extension OpenConnectProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "OpenConnect process is already running."
        case .executableNotFound(let path):
            "Executable is missing or not executable: \(path)"
        case .launchFailed(let message):
            "Failed to launch OpenConnect process: \(message)"
        }
    }
}
