import Foundation

public struct Redactor: Sendable {
    private let literalSecrets: [String]

    public init(literalSecrets: [String] = []) {
        self.literalSecrets = literalSecrets.filter { !$0.isEmpty }
    }

    public func redact(_ input: String) -> String {
        var output = input

        for secret in literalSecrets {
            output = output.replacingOccurrences(of: secret, with: "<redacted>")
        }

        for pattern in Self.defaultPatterns {
            output = Self.replace(pattern: pattern.pattern, in: output, with: pattern.template)
        }

        return output
    }

    public static let `default` = Redactor()

    private static let defaultPatterns: [(pattern: String, template: String)] = [
        (#"pin-sha256:[A-Za-z0-9+/=_:-]+"#, "pin-sha256:<redacted>"),
        (#"(?i)(--servercert=)[^\s]+"#, "$1<redacted>"),
        (#"(?i)(Cookie:\s*).+"#, "$1<redacted>"),
        (#"(?i)(Set-Cookie:\s*).+"#, "$1<redacted>"),
        (#"(?i)\b(password|passwd|token|secret|cookie)=([^\s]+)"#, "$1=<redacted>")
    ]

    private static func replace(pattern: String, in input: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }

        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }
}
