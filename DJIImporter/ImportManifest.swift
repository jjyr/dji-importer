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
    enum Status: String, Codable {
        case imported
        case skipped
    }

    var resumeKey: String
    var relativePath: String
    var size: Int64
    var modificationDate: Date?
    var localIdentifier: String?
    var importedAt: Date?
    var skippedAt: Date?
    var skippedReason: String?
    var status: Status

    init(
        resumeKey: String,
        relativePath: String,
        size: Int64,
        modificationDate: Date?,
        localIdentifier: String,
        importedAt: Date
    ) {
        self.resumeKey = resumeKey
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
        self.localIdentifier = localIdentifier
        self.importedAt = importedAt
        self.skippedAt = nil
        self.skippedReason = nil
        self.status = .imported
    }

    init(
        resumeKey: String,
        relativePath: String,
        size: Int64,
        modificationDate: Date?,
        skippedReason: String,
        skippedAt: Date
    ) {
        self.resumeKey = resumeKey
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
        self.localIdentifier = nil
        self.importedAt = nil
        self.skippedAt = skippedAt
        self.skippedReason = skippedReason
        self.status = .skipped
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resumeKey = try container.decode(String.self, forKey: .resumeKey)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        size = try container.decode(Int64.self, forKey: .size)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        localIdentifier = try container.decodeIfPresent(String.self, forKey: .localIdentifier)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        skippedAt = try container.decodeIfPresent(Date.self, forKey: .skippedAt)
        skippedReason = try container.decodeIfPresent(String.self, forKey: .skippedReason)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .imported
    }
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
    private static let readChunkSize = 64 * 1024

    private let fileManager: FileManager
    private let manifestURL: URL
    private let importedRecordsURL: URL
    private let encoder: JSONEncoder
    private let recordEncoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileManager: FileManager = .default,
        manifestURL: URL? = nil,
        importedRecordsURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.manifestURL = manifestURL ?? Self.defaultManifestURL(fileManager: fileManager)
        self.importedRecordsURL = importedRecordsURL ?? self.manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("imported-items.jsond")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let recordEncoder = JSONEncoder()
        recordEncoder.outputFormatting = [.sortedKeys]
        recordEncoder.dateEncodingStrategy = .iso8601
        self.recordEncoder = recordEncoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> ImportManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        let metadata = try decoder.decode(ImportManifestMetadata.self, from: data)
        var importedItems = try loadImportedItems()

        if importedItems.isEmpty {
            importedItems = legacyImportedItems(from: data)
        }

        return ImportManifest(
            sourceRoot: metadata.sourceRoot,
            sourceName: metadata.sourceName,
            startedAt: metadata.startedAt,
            updatedAt: metadata.updatedAt,
            importedItems: importedItems
        )
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

        let metadata = ImportManifestMetadata(
            sourceRoot: manifest.sourceRoot,
            sourceName: manifest.sourceName,
            startedAt: manifest.startedAt,
            updatedAt: Date()
        )
        let data = try encoder.encode(metadata)
        try data.write(to: manifestURL, options: .atomic)
    }

    func appendImportedItems(
        _ importedItems: [ImportManifestItem],
        to manifest: inout ImportManifest
    ) throws {
        guard !importedItems.isEmpty else {
            return
        }

        try fileManager.createDirectory(
            at: importedRecordsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !fileManager.fileExists(atPath: importedRecordsURL.path) {
            fileManager.createFile(atPath: importedRecordsURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: importedRecordsURL)
        defer {
            try? handle.close()
        }

        try handle.seekToEnd()

        for item in importedItems {
            var line = try recordEncoder.encode(item)
            line.append(0x0A)
            try handle.write(contentsOf: line)
            manifest.importedItems[item.resumeKey] = item
        }

        manifest.updatedAt = Date()
        try save(manifest)
    }

    func reset(sourceRoot: URL, sourceName: String) throws -> ImportManifest {
        let manifest = ImportManifest.fresh(sourceRoot: sourceRoot, sourceName: sourceName)
        if fileManager.fileExists(atPath: importedRecordsURL.path) {
            try fileManager.removeItem(at: importedRecordsURL)
        }
        try save(manifest)
        return manifest
    }

    private func loadImportedItems() throws -> [String: ImportManifestItem] {
        guard fileManager.fileExists(atPath: importedRecordsURL.path) else {
            return [:]
        }

        let handle = try FileHandle(forReadingFrom: importedRecordsURL)
        defer {
            try? handle.close()
        }

        var importedItems: [String: ImportManifestItem] = [:]
        var buffer = Data()

        while true {
            let chunk = try handle.read(upToCount: Self.readChunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }

            buffer.append(chunk)
            try decodeCompleteLines(from: &buffer, into: &importedItems)
        }

        if !buffer.isEmpty, let item = try? decodeImportedItemLine(buffer) {
            importedItems[item.resumeKey] = item
        }

        return importedItems
    }

    private func decodeCompleteLines(
        from buffer: inout Data,
        into importedItems: inout [String: ImportManifestItem]
    ) throws {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            if let item = try decodeImportedItemLine(Data(line)) {
                importedItems[item.resumeKey] = item
            }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
    }

    private func decodeImportedItemLine(_ lineData: Data) throws -> ImportManifestItem? {
        var line = lineData
        while let last = line.last, last == 0x0D || last == 0x0A {
            line.removeLast()
        }

        guard !line.isEmpty else {
            return nil
        }

        return try decoder.decode(ImportManifestItem.self, from: line)
    }

    private func legacyImportedItems(from data: Data) -> [String: ImportManifestItem] {
        guard let legacyManifest = try? decoder.decode(LegacyImportManifest.self, from: data) else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: legacyManifest.importedItems.map { resumeKey, item in
                (
                    resumeKey,
                    ImportManifestItem(
                        resumeKey: resumeKey,
                        relativePath: item.relativePath,
                        size: item.size,
                        modificationDate: item.modificationDate,
                        localIdentifier: item.localIdentifier,
                        importedAt: item.importedAt
                    )
                )
            }
        )
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

private struct ImportManifestMetadata: Codable {
    var sourceRoot: String
    var sourceName: String
    var startedAt: Date
    var updatedAt: Date
}

private struct LegacyImportManifest: Decodable {
    var importedItems: [String: LegacyImportManifestItem]
}

private struct LegacyImportManifestItem: Decodable {
    var relativePath: String
    var size: Int64
    var modificationDate: Date?
    var localIdentifier: String
    var importedAt: Date
}
