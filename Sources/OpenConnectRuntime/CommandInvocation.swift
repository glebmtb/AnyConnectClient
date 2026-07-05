import VPNCore

public struct CommandInvocation: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    public func redactedDescription(redactor: Redactor = .default) -> String {
        let command = ([executablePath] + arguments).map(Self.shellQuote).joined(separator: " ")
        return redactor.redact(command)
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("'") else {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
