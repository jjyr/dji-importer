import Photos
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

    func testAppendsSkippedItemsAsJsondAndLoadsReason() throws {
        let manifestURL = temporaryDirectory.appendingPathComponent("import-manifest.json")
        let importedRecordsURL = temporaryDirectory.appendingPathComponent("imported-items.jsond")
        let store = ImportManifestStore(
            manifestURL: manifestURL,
            importedRecordsURL: importedRecordsURL
        )
        let sourceRoot = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        var manifest = try store.reset(sourceRoot: sourceRoot, sourceName: "source")
        let skippedItem = skippedItem(resumeKey: "DJI_0003.MP4|300|3")

        try store.appendImportedItems([skippedItem], to: &manifest)

        let loadedManifest = try XCTUnwrap(store.loadMatching(sourceRoot: sourceRoot))
        XCTAssertEqual(loadedManifest.importedItems[skippedItem.resumeKey], skippedItem)
        XCTAssertEqual(loadedManifest.importedItems[skippedItem.resumeKey]?.status, .skipped)
        XCTAssertNil(loadedManifest.importedItems[skippedItem.resumeKey]?.localIdentifier)

        let records = try String(contentsOf: importedRecordsURL, encoding: .utf8)
        XCTAssertTrue(records.contains(#""status":"skipped""#))
        XCTAssertTrue(records.contains(#""skippedReason":"Photos rejected this file""#))
    }

    func testLegacyJsondRecordWithoutStatusDecodesAsImported() throws {
        let manifestURL = temporaryDirectory.appendingPathComponent("import-manifest.json")
        let importedRecordsURL = temporaryDirectory.appendingPathComponent("imported-items.jsond")
        let store = ImportManifestStore(
            manifestURL: manifestURL,
            importedRecordsURL: importedRecordsURL
        )
        let sourceRoot = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        _ = try store.reset(sourceRoot: sourceRoot, sourceName: "source")

        try """
        {"importedAt":"1970-01-01T00:00:02Z","localIdentifier":"legacy-local","modificationDate":"1970-01-01T00:00:01Z","relativePath":"DJI_0001.JPG","resumeKey":"DJI_0001.JPG|100|1000","size":100}

        """.write(to: importedRecordsURL, atomically: true, encoding: .utf8)

        let loadedManifest = try XCTUnwrap(store.loadMatching(sourceRoot: sourceRoot))
        let loadedItem = try XCTUnwrap(loadedManifest.importedItems["DJI_0001.JPG|100|1000"])
        XCTAssertEqual(loadedItem.status, .imported)
        XCTAssertEqual(loadedItem.localIdentifier, "legacy-local")
        XCTAssertNil(loadedItem.skippedReason)
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

    func testPhotoKitError3302IsSkippable() {
        let photosError = NSError(domain: PHPhotosErrorDomain, code: 3302)
        let wrappedError = NSError(
            domain: "DJIImporterTests",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: photosError]
        )
        let detailedError = NSError(
            domain: PHPhotosErrorDomain,
            code: -1,
            userInfo: [NSDetailedErrorsKey: [photosError]]
        )

        XCTAssertTrue(PhotoKitImporter.isSkippableImportError(photosError))
        XCTAssertTrue(PhotoKitImporter.isSkippableImportError(wrappedError))
        XCTAssertTrue(PhotoKitImporter.isSkippableImportError(detailedError))
        XCTAssertFalse(PhotoKitImporter.isSkippableImportError(NSError(domain: PHPhotosErrorDomain, code: 3301)))
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

    private func skippedItem(resumeKey: String) -> ImportManifestItem {
        ImportManifestItem(
            resumeKey: resumeKey,
            relativePath: resumeKey.components(separatedBy: "|")[0],
            size: 100,
            modificationDate: Date(timeIntervalSince1970: 1),
            skippedReason: "Photos rejected this file",
            skippedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
