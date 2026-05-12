import XCTest
@testable import DJIImporter

final class ImportManifestStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testAppendsImportedItemsAsJsondAndKeepsMetadataSmall() throws {
        let manifestURL = temporaryDirectory.appendingPathComponent("import-manifest.json")
        let importedRecordsURL = temporaryDirectory.appendingPathComponent("imported-items.jsond")
        let store = ImportManifestStore(
            manifestURL: manifestURL,
            importedRecordsURL: importedRecordsURL
        )
        let sourceRoot = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        var manifest = try store.reset(sourceRoot: sourceRoot, sourceName: "source")
        let firstItem = importedItem(resumeKey: "DJI_0001.JPG|100|1")
        let secondItem = importedItem(resumeKey: "DJI_0002.MP4|200|2")

        try store.appendImportedItems([firstItem], to: &manifest)
        try store.appendImportedItems([secondItem], to: &manifest)

        let loadedManifest = try XCTUnwrap(store.loadMatching(sourceRoot: sourceRoot))
        XCTAssertEqual(loadedManifest.importedItems[firstItem.resumeKey], firstItem)
        XCTAssertEqual(loadedManifest.importedItems[secondItem.resumeKey], secondItem)

        let metadata = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertFalse(metadata.contains("importedItems"))

        let records = try String(contentsOf: importedRecordsURL, encoding: .utf8)
        XCTAssertEqual(records.split(separator: "\n").count, 2)
    }

    func testResetClearsImportedJsondRecords() throws {
        let manifestURL = temporaryDirectory.appendingPathComponent("import-manifest.json")
        let importedRecordsURL = temporaryDirectory.appendingPathComponent("imported-items.jsond")
        let store = ImportManifestStore(
            manifestURL: manifestURL,
            importedRecordsURL: importedRecordsURL
        )
        let sourceRoot = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        var manifest = try store.reset(sourceRoot: sourceRoot, sourceName: "source")

        try store.appendImportedItems([importedItem(resumeKey: "DJI_0001.JPG|100|1")], to: &manifest)
        manifest = try store.reset(sourceRoot: sourceRoot, sourceName: "source")

        let loadedManifest = try XCTUnwrap(store.loadMatching(sourceRoot: sourceRoot))
        XCTAssertEqual(manifest.importedItems, [:])
        XCTAssertEqual(loadedManifest.importedItems, [:])
    }

    func testIgnoresTrailingPartialJsondLine() throws {
        let manifestURL = temporaryDirectory.appendingPathComponent("import-manifest.json")
        let importedRecordsURL = temporaryDirectory.appendingPathComponent("imported-items.jsond")
        let store = ImportManifestStore(
            manifestURL: manifestURL,
            importedRecordsURL: importedRecordsURL
        )
        let sourceRoot = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        var manifest = try store.reset(sourceRoot: sourceRoot, sourceName: "source")
        let completeItem = importedItem(resumeKey: "DJI_0001.JPG|100|1")

        try store.appendImportedItems([completeItem], to: &manifest)
        let handle = try FileHandle(forWritingTo: importedRecordsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{".utf8))
        try handle.close()

        let loadedManifest = try XCTUnwrap(store.loadMatching(sourceRoot: sourceRoot))
        XCTAssertEqual(loadedManifest.importedItems, [completeItem.resumeKey: completeItem])
    }

    private func importedItem(resumeKey: String) -> ImportManifestItem {
        ImportManifestItem(
            resumeKey: resumeKey,
            relativePath: resumeKey.components(separatedBy: "|")[0],
            size: 100,
            modificationDate: Date(timeIntervalSince1970: 1),
            localIdentifier: "local-\(resumeKey)",
            importedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
