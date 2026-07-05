import Foundation

public struct RouteImportSnapshot: Equatable, Sendable {
    public let ipv4Includes: [String]
    public let ipv4Excludes: [String]
    public let ipv6Includes: [String]
    public let ipv6Excludes: [String]

    public init(
        ipv4Includes: [String] = [],
        ipv4Excludes: [String] = [],
        ipv6Includes: [String] = [],
        ipv6Excludes: [String] = []
    ) {
        self.ipv4Includes = ipv4Includes
        self.ipv4Excludes = ipv4Excludes
        self.ipv6Includes = ipv6Includes
        self.ipv6Excludes = ipv6Excludes
    }

    public var isEmpty: Bool {
        routeCount == 0
    }

    public var routeCount: Int {
        ipv4Includes.count + ipv4Excludes.count + ipv6Includes.count + ipv6Excludes.count
    }

    public var formattedText: String {
        var lines: [String] = []
        appendSection(title: "IPv4 include", values: ipv4Includes, to: &lines)
        appendSection(title: "IPv4 exclude", values: ipv4Excludes, to: &lines)
        appendSection(title: "IPv6 include", values: ipv6Includes, to: &lines)
        appendSection(title: "IPv6 exclude", values: ipv6Excludes, to: &lines)
        return lines.isEmpty ? "No split routes were reported by this VPN profile." : lines.joined(separator: "\n")
    }

    private func appendSection(title: String, values: [String], to lines: inout [String]) {
        guard !values.isEmpty else {
            return
        }

        if !lines.isEmpty {
            lines.append("")
        }
        lines.append("\(title):")
        lines.append(contentsOf: values.map { "  \($0)" })
    }
}

public struct RouteImportParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> RouteImportSnapshot {
        let values = parseEnvironmentValues(text)
        return RouteImportSnapshot(
            ipv4Includes: routes(prefix: "CISCO_SPLIT_INC", values: values, addressFamily: .ipv4),
            ipv4Excludes: routes(prefix: "CISCO_SPLIT_EXC", values: values, addressFamily: .ipv4),
            ipv6Includes: routes(prefix: "CISCO_IPV6_SPLIT_INC", values: values, addressFamily: .ipv6),
            ipv6Excludes: routes(prefix: "CISCO_IPV6_SPLIT_EXC", values: values, addressFamily: .ipv6)
        )
    }

    private func parseEnvironmentValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            values[key] = value
        }

        return values
    }

    private func routes(
        prefix: String,
        values: [String: String],
        addressFamily: RouteAddressFamily
    ) -> [String] {
        let indexes = routeIndexes(prefix: prefix, values: values)
        return indexes.compactMap { index in
            guard let address = values["\(prefix)_\(index)_ADDR"], !address.isEmpty else {
                return nil
            }

            let maskLength = values["\(prefix)_\(index)_MASKLEN"]
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                ?? values["\(prefix)_\(index)_MASK"].flatMap { addressFamily.maskLength(from: $0) }
            let route = maskLength.map { "\(address)/\($0)" } ?? address
            return routeAnnotation(prefix: prefix, index: index, values: values)
                .map { "\(route)  \($0)" }
                ?? route
        }
    }

    private func routeIndexes(prefix: String, values: [String: String]) -> [Int] {
        let discovered = values.keys.compactMap { key -> Int? in
            guard key.hasPrefix("\(prefix)_"), key.hasSuffix("_ADDR") else {
                return nil
            }

            let withoutPrefix = key.dropFirst(prefix.count + 1)
            let indexText = withoutPrefix.dropLast("_ADDR".count)
            return Int(indexText)
        }

        if !discovered.isEmpty {
            return discovered.sorted()
        }

        let count = values[prefix].flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        return count > 0 ? Array(0..<count) : []
    }

    private func routeAnnotation(prefix: String, index: Int, values: [String: String]) -> String? {
        let protocolValue = nonZero(values["\(prefix)_\(index)_PROTOCOL"])
        let sourcePort = nonZero(values["\(prefix)_\(index)_SPORT"])
        let destinationPort = nonZero(values["\(prefix)_\(index)_DPORT"])
        let parts = [
            protocolValue.map { "proto \($0)" },
            sourcePort.map { "sport \($0)" },
            destinationPort.map { "dport \($0)" }
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return nil
        }
        return "(\(parts.joined(separator: ", ")))"
    }

    private func nonZero(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "0" else {
            return nil
        }
        return trimmed
    }
}

private enum RouteAddressFamily {
    case ipv4
    case ipv6

    func maskLength(from mask: String) -> Int? {
        switch self {
        case .ipv4:
            return Self.ipv4MaskLength(from: mask)
        case .ipv6:
            return Int(mask.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func ipv4MaskLength(from mask: String) -> Int? {
        let octets = mask
            .split(separator: ".")
            .compactMap { UInt8($0) }
        guard octets.count == 4 else {
            return nil
        }

        let bits: [Bool] = octets.flatMap { octet -> [Bool] in
            (0..<8).reversed().map { bit in
                (octet & UInt8(1 << bit)) != 0
            }
        }
        guard let firstZero = bits.firstIndex(of: false) else {
            return bits.count
        }
        guard bits[firstZero...].allSatisfy({ !$0 }) else {
            return nil
        }
        return firstZero
    }
}
