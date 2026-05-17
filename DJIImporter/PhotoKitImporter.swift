import AppKit
import Foundation
import Photos

enum PhotoKitImportError: LocalizedError {
    case accessDenied(PhotosAuthorizationSnapshot)
    case invalidPrivacyAuthorization
    case unsupportedMedia(MediaItem)
    case missingPlaceholder(MediaItem)
    case partialImport(expected: Int, actual: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .accessDenied(let status):
            return Self.accessDeniedMessage(for: status)
        case .invalidPrivacyAuthorization:
            return "Photos privacy authorization is invalid. Reinstall a signed app, then enable DJI Importer in System Settings > Privacy & Security > Photos."
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

    private static func accessDeniedMessage(for snapshot: PhotosAuthorizationSnapshot) -> String {
        if snapshot.addOnly == .restricted || snapshot.readWrite == .restricted {
            return "Photos access is restricted by macOS policy, so DJI Importer cannot add media to Photos. \(snapshot.summary)"
        }

        if snapshot.addOnly == .denied || snapshot.readWrite == .denied {
            return "Photos permission is denied. Quit DJI Importer, use Reset Photos Permission, then relaunch and approve the macOS prompt. \(snapshot.summary)"
        }

        return "Photos permission was not granted. Relaunch DJI Importer and approve the macOS prompt. \(snapshot.summary)"
    }
}

extension PhotoKitImporter {
    @MainActor
    static func requestAddPermission() async throws {
        NSApp.activate(ignoringOtherApps: true)

        let initialAddOnlyStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if initialAddOnlyStatus == .authorized {
            return
        }

        if initialAddOnlyStatus == .notDetermined {
            let requestedAddOnlyStatus = await requestAuthorization(for: .addOnly)
            if requestedAddOnlyStatus == .authorized {
                return
            }
        }

        let initialReadWriteStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if Self.allowsImport(readWriteStatus: initialReadWriteStatus) {
            return
        }

        if initialReadWriteStatus == .notDetermined {
            let requestedReadWriteStatus = await requestAuthorization(for: .readWrite)
            if Self.allowsImport(readWriteStatus: requestedReadWriteStatus) {
                return
            }
        }

        throw PhotoKitImportError.accessDenied(PhotosAuthorizationSnapshot.current())
    }

    @MainActor
    private static func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: accessLevel) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func allowsImport(readWriteStatus: PHAuthorizationStatus) -> Bool {
        switch readWriteStatus {
        case .authorized, .limited:
            return true
        case .notDetermined, .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

struct PhotosAuthorizationSnapshot {
    let addOnly: PHAuthorizationStatus
    let readWrite: PHAuthorizationStatus
    let bundleIdentifier: String
    let bundlePath: String

    var summary: String {
        "Status: add-only=\(addOnly.diagnosticText), read-write=\(readWrite.diagnosticText), bundle=\(bundleIdentifier), path=\(bundlePath)"
    }

    static func current() -> PhotosAuthorizationSnapshot {
        PhotosAuthorizationSnapshot(
            addOnly: PHPhotoLibrary.authorizationStatus(for: .addOnly),
            readWrite: PHPhotoLibrary.authorizationStatus(for: .readWrite),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundleURL.path
        )
    }
}

private extension PHAuthorizationStatus {
    var diagnosticText: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .limited:
            return "limited"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}

enum PhotoKitImporter {
    private static let unsupportedAssetErrorCode = 3302

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
                    if isInvalidTCCAuthorization(error) {
                        continuation.resume(throwing: PhotoKitImportError.invalidPrivacyAuthorization)
                    } else {
                        continuation.resume(throwing: error)
                    }
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

    static func isSkippableImportError(_ error: Error) -> Bool {
        photosError(in: error, matchingCode: unsupportedAssetErrorCode) != nil
    }

    static func skippableImportReason(for error: Error) -> String {
        guard let photosError = photosError(in: error, matchingCode: unsupportedAssetErrorCode)
            ?? photosError(in: error) else {
            return "Photos rejected this file: \(error.localizedDescription)"
        }

        return "Photos rejected this file with PHPhotosErrorDomain error \(photosError.code): \(photosError.localizedDescription)"
    }

    private static func isInvalidTCCAuthorization(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        return message.contains("tcc authorization")
            || message.contains("valid tcc")
            || message.contains("privacy authorization")
    }

    private static func photosError(in error: Error, matchingCode code: Int? = nil) -> NSError? {
        let error = error as NSError

        if error.domain == PHPhotosErrorDomain && (code == nil || error.code == code) {
            return error
        }

        for key in [NSUnderlyingErrorKey, NSMultipleUnderlyingErrorsKey, NSDetailedErrorsKey] {
            if let underlyingError = error.userInfo[key] as? Error,
               let photosError = photosError(in: underlyingError, matchingCode: code) {
                return photosError
            }

            if let underlyingErrors = error.userInfo[key] as? [Error] {
                for underlyingError in underlyingErrors {
                    if let photosError = photosError(in: underlyingError, matchingCode: code) {
                        return photosError
                    }
                }
            }
        }

        return nil
    }
}
