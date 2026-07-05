import Foundation
import VPNCore

struct RuntimeRecoveryDocument: Codable, Equatable, Sendable {
    var version: Int
    var entries: [RuntimeRecoveryEntry]

    init(version: Int = 1, entries: [RuntimeRecoveryEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

struct RuntimeRecoveryEntry: Codable, Equatable, Sendable {
    var profileID: VPNProfileID
    var socksPort: Int
    var openConnectProcessIdentifier: Int32
    var ocproxyProcessIdentifier: Int32?
    var updatedAt: Date
}

struct RuntimeRecoveryRegistry: Sendable {
    let fileURL: URL

    init(fileURL: URL = RuntimeRecoveryRegistry.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() -> RuntimeRecoveryDocument {
        guard let data = try? Data(contentsOf: fileURL) else {
            return RuntimeRecoveryDocument()
        }

        do {
            return try decoder.decode(RuntimeRecoveryDocument.self, from: data)
        } catch {
            return RuntimeRecoveryDocument()
        }
    }

    func save(_ document: RuntimeRecoveryDocument) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic])
    }

    func upsert(_ entry: RuntimeRecoveryEntry) throws {
        var document = load()
        document.entries.removeAll { $0.profileID == entry.profileID }
        document.entries.append(entry)
        try save(document)
    }

    func remove(profileID: VPNProfileID) throws {
        var document = load()
        document.entries.removeAll { $0.profileID == profileID }
        if document.entries.isEmpty {
            try removeAll()
        } else {
            try save(document)
        }
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("AnyConnectClient", isDirectory: true)
            .appendingPathComponent("runtime-registry.json")
    }
}
