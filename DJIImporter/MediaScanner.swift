import Foundation

enum MediaScannerError: LocalizedError {
    case missingDirectory(URL)
    case notDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .missingDirectory(let url):
            return "Source not found: \(url.path)"
        case .notDirectory(let url):
            return "Source is not a folder: \(url.path)"
        }
    }
}

enum MediaScanner {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "mp4"]

    static func scan(rootURL: URL) throws -> [MediaItem] {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw MediaScannerError.missingDirectory(root)
        }

        guard isDirectory.boolValue else {
            throw MediaScannerError.notDirectory(root)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var items: [MediaItem] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else {
                continue
            }

            let size = Int64(values?.fileSize ?? 0)
            let kind: MediaKind = ext == "mp4" ? .video : .photo
            let standardizedFileURL = fileURL.standardizedFileURL

            items.append(
                MediaItem(
                    url: standardizedFileURL,
                    rootURL: root,
                    name: standardizedFileURL.lastPathComponent,
                    fileExtension: ext,
                    relativePath: relativePath(for: standardizedFileURL, root: root),
                    size: size,
                    kind: kind
                )
            )
        }

        return items.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    static func summary(for items: [MediaItem]) -> String {
        let photos = items.filter { $0.kind == .photo }.count
        let videos = items.filter { $0.kind == .video }.count
        let totalSize = items.reduce(Int64(0)) { $0 + $1.size }

        guard !items.isEmpty else {
            return "No supported media found"
        }

        return "\(items.count) files, \(photos) photos, \(videos) videos, \(totalSize.fileSizeText)"
    }

    private static func relativePath(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }

        return fileURL.lastPathComponent
    }
}
