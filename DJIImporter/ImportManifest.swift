import Foundation

struct ImportManifest: Codable, Equatable {
    var sourceRoot: String
    var sourceName: String
    var startedAt: Date
    var updatedAt: Date
    var importedItems: [String: ImportManifestItem]

    static func fresh(sourceRoot: URL, sourceName: String) -> ImportManifest {
        let now = Date()
        return ImportManifest(
            sourceRoot: sourceRoot.standardizedFileURL.path,
            sourceName: sourceName,
            startedAt: now,
            updatedAt: now,
            importedItems: [:]
        )
    }
}

struct ImportManifestItem: Codable, Equatable {
    var relativePath: String
    var size: Int64
    var modificationDate: Date?
    var localIdentifier: String
    var importedAt: Date
}

enum ImportManifestError: LocalizedError {
    case missingApplicationSupportDirectory

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            return "Could not locate Application Support."
        }
    }
}

final class ImportManifestStore {
    private let fileManager: FileManager
    private let manifestURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, manifestURL: URL? = nil) {
        self.fileManager = fileManager
        self.manifestURL = manifestURL ?? Self.defaultManifestURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> ImportManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(ImportManifest.self, from: data)
    }

    func loadMatching(sourceRoot: URL) throws -> ImportManifest? {
        guard let manifest = try load() else {
            return nil
        }

        guard manifest.sourceRoot == sourceRoot.standardizedFileURL.path else {
            return nil
        }

        return manifest
    }

    func save(_ manifest: ImportManifest) throws {
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var updatedManifest = manifest
        updatedManifest.updatedAt = Date()
        let data = try encoder.encode(updatedManifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    func reset(sourceRoot: URL, sourceName: String) throws -> ImportManifest {
        let manifest = ImportManifest.fresh(sourceRoot: sourceRoot, sourceName: sourceName)
        try save(manifest)
        return manifest
    }

    private static func defaultManifestURL(fileManager: FileManager) -> URL {
        if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return applicationSupport
                .appendingPathComponent("DJIImporter", isDirectory: true)
                .appendingPathComponent("import-manifest.json")
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DJIImporter", isDirectory: true)
            .appendingPathComponent("import-manifest.json")
    }
}
