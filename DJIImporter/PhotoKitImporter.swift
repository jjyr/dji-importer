import Foundation
import Photos

enum PhotoKitImportError: LocalizedError {
    case accessDenied(PHAuthorizationStatus)
    case unsupportedMedia(MediaItem)
    case missingPlaceholder(MediaItem)
    case partialImport(expected: Int, actual: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .accessDenied(let status):
            return "Photos add permission was not granted (\(status))."
        case .unsupportedMedia(let media):
            return "Unsupported media type: \(media.relativePath)"
        case .missingPlaceholder(let media):
            return "Photos did not create an asset placeholder for \(media.relativePath)."
        case .partialImport(let expected, let actual):
            return "Photos reported a partial import: \(actual) of \(expected) assets."
        case .cancelled:
            return "Import cancelled."
        }
    }
}

enum PhotoKitImporter {
    static func requestAddPermission() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let requestedStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }

            guard requestedStatus == .authorized else {
                throw PhotoKitImportError.accessDenied(requestedStatus)
            }
        default:
            throw PhotoKitImportError.accessDenied(status)
        }
    }

    static func importBatch(_ mediaItems: [MediaItem]) async throws -> [PhotoKitImportedAsset] {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            var importedAssets: [PhotoKitImportedAsset] = []
            var setupError: PhotoKitImportError?

            PHPhotoLibrary.shared().performChanges {
                for media in mediaItems {
                    if Task.isCancelled {
                        setupError = .cancelled
                        return
                    }

                    let request: PHAssetChangeRequest?
                    switch media.kind {
                    case .photo:
                        request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: media.url)
                    case .video:
                        request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: media.url)
                    }

                    guard let request else {
                        setupError = .unsupportedMedia(media)
                        return
                    }

                    guard let localIdentifier = request.placeholderForCreatedAsset?.localIdentifier else {
                        setupError = .missingPlaceholder(media)
                        return
                    }

                    importedAssets.append(
                        PhotoKitImportedAsset(
                            resumeKey: media.resumeKey,
                            localIdentifier: localIdentifier
                        )
                    )
                }
            } completionHandler: { success, error in
                if let setupError {
                    continuation.resume(throwing: setupError)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard success else {
                    continuation.resume(throwing: PhotoKitImportError.partialImport(
                        expected: mediaItems.count,
                        actual: importedAssets.count
                    ))
                    return
                }

                guard importedAssets.count == mediaItems.count else {
                    continuation.resume(throwing: PhotoKitImportError.partialImport(
                        expected: mediaItems.count,
                        actual: importedAssets.count
                    ))
                    return
                }

                continuation.resume(returning: importedAssets)
            }
        }
    }
}
