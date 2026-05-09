import Foundation

struct VolumeCandidate: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let subtitle: String
    let isLikelyCameraVolume: Bool
    let totalCapacity: Int64?
    let availableCapacity: Int64?

    init(
        url: URL,
        name: String,
        subtitle: String? = nil,
        isLikelyCameraVolume: Bool = false,
        totalCapacity: Int64? = nil,
        availableCapacity: Int64? = nil
    ) {
        let standardizedURL = url.standardizedFileURL
        self.id = standardizedURL.path
        self.url = standardizedURL
        self.name = name
        self.subtitle = subtitle ?? standardizedURL.path
        self.isLikelyCameraVolume = isLikelyCameraVolume
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }
}

enum MediaKind: String, Hashable {
    case photo
    case video

    var title: String {
        switch self {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        }
    }

    var symbolName: String {
        switch self {
        case .photo:
            return "photo"
        case .video:
            return "video"
        }
    }
}

enum ImportState: Hashable {
    case pending
    case importing
    case finished(String?)
    case failed(String)

    var title: String {
        switch self {
        case .pending:
            return "Ready"
        case .importing:
            return "Importing"
        case .finished:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    var id: String { url.path }

    let url: URL
    let rootURL: URL
    let name: String
    let fileExtension: String
    let relativePath: String
    let size: Int64
    let kind: MediaKind
    var importState: ImportState = .pending
}

struct ImportProgressState: Equatable {
    var total: Int = 0
    var completed: Int = 0
    var succeeded: Int = 0
    var failed: Int = 0
    var currentFile: String?

    var fraction: Double {
        guard total > 0 else {
            return 0
        }
        return Double(completed) / Double(total)
    }

    static let empty = ImportProgressState()
}

struct PhotosImportResult: Equatable {
    let succeeded: Bool
    let message: String
}
