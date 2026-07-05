import Foundation

struct ServerCertificatePinParser: Sendable {
    func pins(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"pin-sha256:[A-Za-z0-9+/=_:-]+"#) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        return regex.matches(in: text, range: range).compactMap { match in
            guard let pinRange = Range(match.range, in: text) else {
                return nil
            }
            let pin = String(text[pinRange])
            guard seen.insert(pin).inserted else {
                return nil
            }
            return pin
        }
    }
}
