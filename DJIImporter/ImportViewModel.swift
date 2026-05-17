import AppKit
import Foundation

@MainActor
final class ImportViewModel: ObservableObject {
    enum ImportMode {
        case resume
        case startOver
    }

    @Published private(set) var volumes: [VolumeCandidate] = []
    @Published var selectedVolumeID: VolumeCandidate.ID?
    @Published private(set) var mediaFiles: [MediaItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isImporting = false
    @Published private(set) var canResumeImport = false
    @Published private(set) var progress = ImportProgressState.empty
    @Published private(set) var statusMessage = "Connect DJI Pocket 3 or choose a folder."
    @Published private(set) var lastError: String?
    @Published private(set) var canOpenPhotosSettings = false
    @Published private(set) var canResetPhotosPermission = false
    @Published private(set) var isResettingPhotosPermission = false
    @Published var deleteSourceFilesAfterImport = false

    private let manifestStore = ImportManifestStore()
    private var activeManifest: ImportManifest?
    private var scanTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    var selectedVolume: VolumeCandidate? {
        guard let selectedVolumeID else {
            return nil
        }
        return volumes.first { $0.id == selectedVolumeID }
    }

    var mediaSummary: String {
        MediaScanner.summary(for: mediaFiles)
    }

    var primaryImportTitle: String {
        canResumeImport ? "Resume Import" : "Import All"
    }

    var primaryImportSymbolName: String {
        canResumeImport ? "arrow.clockwise.circle" : "square.and.arrow.down"
    }

    init() {
        refreshVolumes()
    }

    func refreshVolumes() {
        guard !isImporting else {
            return
        }

        let detectedVolumes = VolumeScanner.mountedVolumes()
        volumes = mergeCustomSelection(with: detectedVolumes)

        if let selectedVolumeID, volumes.contains(where: { $0.id == selectedVolumeID }) {
            scanSelectedVolume()
            return
        }

        selectedVolumeID = volumes.first?.id

        if selectedVolumeID == nil {
            mediaFiles = []
            statusMessage = "No external volumes found. Choose a folder manually."
        } else {
            scanSelectedVolume()
        }
    }

    func selectVolume(id: VolumeCandidate.ID?) {
        guard !isImporting else {
            return
        }

        selectedVolumeID = id
        scanSelectedVolume()
    }

    func chooseFolder() {
        guard !isImporting else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose DJI media folder"
        panel.message = "Select the DJI Pocket 3 volume or a folder containing JPG, JPEG, and MP4 files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let customVolume = VolumeScanner.customVolume(for: url)
        if !volumes.contains(where: { $0.id == customVolume.id }) {
            volumes.insert(customVolume, at: 0)
        }
        selectedVolumeID = customVolume.id
        scanSelectedVolume()
    }

    func scanSelectedVolume() {
        guard !isImporting else {
            return
        }

        scanTask?.cancel()
        progress = .empty
        canResumeImport = false
        activeManifest = nil
        clearPhotosPermissionActions()

        guard let selectedVolume else {
            mediaFiles = []
            statusMessage = "Choose a source to scan."
            return
        }

        let rootURL = selectedVolume.url
        isScanning = true
        lastError = nil
        mediaFiles = []
        statusMessage = "Scanning \(selectedVolume.name)..."

        scanTask = Task { [weak self] in
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try MediaScanner.scan(rootURL: rootURL)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                self?.mediaFiles = items
                self?.applyResumeManifestIfAvailable(for: items, rootURL: rootURL)
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self?.mediaFiles = []
                self?.lastError = error.localizedDescription
                self?.clearPhotosPermissionActions()
                self?.statusMessage = "Scan failed."
            }

            self?.isScanning = false
        }
    }

    func startPrimaryImport() {
        startImport(mode: canResumeImport ? .resume : .startOver)
    }

    func startOverImport() {
        startImport(mode: .startOver)
    }

    func cancelImport() {
        importTask?.cancel()
        statusMessage = "Cancelling after the current batch..."
    }

    func openPhotosSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func openFile(_ media: MediaItem) {
        guard NSWorkspace.shared.open(media.url) else {
            lastError = "Could not open \(media.relativePath)."
            return
        }

        lastError = nil
    }

    func openContainingFolder(_ media: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([media.url])
        lastError = nil
    }

    func resetPhotosPermission() {
        guard !isResettingPhotosPermission else {
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jjy.DJIImporter"
        isResettingPhotosPermission = true
        lastError = nil
        statusMessage = "Resetting Photos permission..."

        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try PhotosPermissionResetter.reset(bundleIdentifier: bundleIdentifier)
                }.value

                self?.statusMessage = "Photos permission was reset. Start import again and approve the macOS prompt."
                self?.clearPhotosPermissionActions()
            } catch {
                self?.lastError = error.localizedDescription
                self?.statusMessage = "Photos permission reset failed."
                self?.canOpenPhotosSettings = true
                self?.canResetPhotosPermission = true
            }

            self?.isResettingPhotosPermission = false
        }
    }

    private func startImport(mode: ImportMode) {
        guard !isScanning, !isImporting, !mediaFiles.isEmpty else {
            return
        }

        importTask = Task { [weak self] in
            await self?.importAll(mode: mode)
        }
    }

    private func importAll(mode: ImportMode) async {
        guard let selectedVolume else {
            return
        }

        isImporting = true
        lastError = nil
        clearPhotosPermissionActions()

        do {
            var manifest = try manifest(for: mode, selectedVolume: selectedVolume)
            activeManifest = manifest

            if mode == .startOver {
                resetImportStates()
                canResumeImport = false
            } else {
                applyManifest(manifest)
            }

            let skipped = mediaFiles.filter { $0.importState.isSkipped }.count
            progress = ImportProgressState(
                total: mediaFiles.count,
                completed: skipped,
                succeeded: 0,
                skipped: skipped,
                failed: 0,
                currentFile: nil
            )

            let pendingCount = mediaFiles.count - skipped
            if pendingCount == 0 {
                statusMessage = "Nothing left to import."
            } else {
                try await PhotoKitImporter.requestAddPermission()

                var tuner = BatchTuner()
                statusMessage = "Starting PhotoKit import..."

                while !Task.isCancelled {
                    let pendingIndexes = mediaFiles.indices.filter { index in
                        if case .pending = mediaFiles[index].importState {
                            return true
                        }
                        return false
                    }

                    guard !pendingIndexes.isEmpty else {
                        break
                    }

                    let batchIndexes = nextBatchIndexes(from: pendingIndexes, limits: tuner.limits)
                    guard !batchIndexes.isEmpty else {
                        break
                    }

                    for index in batchIndexes {
                        mediaFiles[index].importState = .importing
                    }

                    let batch = batchIndexes.map { mediaFiles[$0] }
                    progress.currentFile = batch.first?.relativePath
                    statusMessage = "Importing batch of \(batch.count) files..."

                    let startedAt = Date()
                    do {
                        let importedAssets = try await PhotoKitImporter.importBatch(batch)
                        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                        let importedBytes = batch.reduce(Int64(0)) { $0 + $1.size }

                        let localIdentifiersByKey = Dictionary(
                            uniqueKeysWithValues: importedAssets.map { ($0.resumeKey, $0.localIdentifier) }
                        )
                        var importedManifestItems: [ImportManifestItem] = []

                        for index in batchIndexes {
                            let media = mediaFiles[index]
                            guard let localIdentifier = localIdentifiersByKey[media.resumeKey] else {
                                continue
                            }

                            mediaFiles[index].importState = .finished(localIdentifier)
                            importedManifestItems.append(importedManifestItem(for: media, localIdentifier: localIdentifier))
                        }

                        try manifestStore.appendImportedItems(importedManifestItems, to: &manifest)
                        activeManifest = manifest

                        progress.completed += batch.count
                        progress.succeeded += batch.count
                        progress.currentFile = nil

                        tuner.observe(bytes: importedBytes, seconds: elapsed)
                        statusMessage = batchStatus(
                            fileCount: batch.count,
                            bytes: importedBytes,
                            elapsed: elapsed,
                            limits: tuner.limits
                        )
                    } catch {
                        guard PhotoKitImporter.isSkippableImportError(error) else {
                            throw error
                        }

                        for index in batchIndexes {
                            mediaFiles[index].importState = .pending
                        }

                        statusMessage = "Photos rejected one file in this batch. Retrying \(batch.count) files one by one..."
                        let result = try await importBatchOneByOneSkippingRejectedFiles(
                            batchIndexes,
                            manifest: &manifest
                        )
                        activeManifest = manifest
                        progress.currentFile = nil

                        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                        statusMessage = fallbackBatchStatus(
                            importedCount: result.importedCount,
                            skippedCount: result.skippedCount,
                            elapsed: elapsed
                        )
                    }
                }
            }

            if Task.isCancelled {
                statusMessage = "Import cancelled. Resume Import will skip completed batches."
                canResumeImport = hasUnfinishedManifest(manifest, mediaFiles: mediaFiles)
            } else if deleteSourceFilesAfterImport {
                let deletionResult = deleteImportedSourceFiles(using: manifest)
                progress.deleted += deletionResult.successfulCount
                progress.failed += deletionResult.failures.count
                statusMessage = deletionStatus(for: deletionResult)
                lastError = deletionResult.errorMessage
                clearPhotosPermissionActions()
                canResumeImport = false
            } else {
                statusMessage = importCompletionStatus()
                clearPhotosPermissionActions()
                canResumeImport = false
            }
        } catch {
            for index in mediaFiles.indices where mediaFiles[index].importState == .importing {
                mediaFiles[index].importState = .failed(error.localizedDescription)
            }
            progress.failed = mediaFiles.filter { $0.importState.isFailed }.count
            lastError = error.localizedDescription
            let isPhotosAuthorizationError = Self.isPhotosAuthorizationError(error)
            canOpenPhotosSettings = isPhotosAuthorizationError
            canResetPhotosPermission = isPhotosAuthorizationError
            statusMessage = "Import failed. Resume Import will retry unfinished files."

            if let activeManifest {
                canResumeImport = hasUnfinishedManifest(activeManifest, mediaFiles: mediaFiles)
            }
        }

        progress.currentFile = nil
        isImporting = false
        importTask = nil
    }

    private func manifest(for mode: ImportMode, selectedVolume: VolumeCandidate) throws -> ImportManifest {
        switch mode {
        case .startOver:
            return try manifestStore.reset(
                sourceRoot: selectedVolume.url,
                sourceName: selectedVolume.name
            )
        case .resume:
            if let manifest = activeManifest {
                return manifest
            }
            if let manifest = try manifestStore.loadMatching(sourceRoot: selectedVolume.url) {
                return manifest
            }
            return try manifestStore.reset(
                sourceRoot: selectedVolume.url,
                sourceName: selectedVolume.name
            )
        }
    }

    private func importBatchOneByOneSkippingRejectedFiles(
        _ batchIndexes: [Array<MediaItem>.Index],
        manifest: inout ImportManifest
    ) async throws -> OneByOneImportResult {
        var result = OneByOneImportResult()

        for index in batchIndexes {
            try Task.checkCancellation()

            mediaFiles[index].importState = .importing
            let media = mediaFiles[index]
            progress.currentFile = media.relativePath

            do {
                let importedAssets = try await PhotoKitImporter.importBatch([media])
                guard let importedAsset = importedAssets.first else {
                    throw PhotoKitImportError.partialImport(expected: 1, actual: 0)
                }

                mediaFiles[index].importState = .finished(importedAsset.localIdentifier)
                try manifestStore.appendImportedItems(
                    [importedManifestItem(for: media, localIdentifier: importedAsset.localIdentifier)],
                    to: &manifest
                )
                activeManifest = manifest

                result.importedCount += 1
                progress.completed += 1
                progress.succeeded += 1
            } catch {
                guard PhotoKitImporter.isSkippableImportError(error) else {
                    throw error
                }

                let reason = PhotoKitImporter.skippableImportReason(for: error)
                mediaFiles[index].importState = .skipped(reason)
                try manifestStore.appendImportedItems(
                    [skippedManifestItem(for: media, reason: reason)],
                    to: &manifest
                )
                activeManifest = manifest

                result.skippedCount += 1
                progress.completed += 1
                progress.skipped += 1
            }
        }

        return result
    }

    private func importedManifestItem(for media: MediaItem, localIdentifier: String) -> ImportManifestItem {
        ImportManifestItem(
            resumeKey: media.resumeKey,
            relativePath: media.relativePath,
            size: media.size,
            modificationDate: media.modificationDate,
            localIdentifier: localIdentifier,
            importedAt: Date()
        )
    }

    private func skippedManifestItem(for media: MediaItem, reason: String) -> ImportManifestItem {
        ImportManifestItem(
            resumeKey: media.resumeKey,
            relativePath: media.relativePath,
            size: media.size,
            modificationDate: media.modificationDate,
            skippedReason: reason,
            skippedAt: Date()
        )
    }

    private func applyResumeManifestIfAvailable(for items: [MediaItem], rootURL: URL) {
        guard !items.isEmpty else {
            statusMessage = "No supported media found."
            return
        }

        do {
            guard let manifest = try manifestStore.loadMatching(sourceRoot: rootURL) else {
                statusMessage = "Scan complete."
                return
            }

            activeManifest = manifest
            applyManifest(manifest)
            canResumeImport = hasUnfinishedManifest(manifest, mediaFiles: mediaFiles)

            let recordedCount = mediaFiles.filter { $0.importState.isSkipped }.count
            let rejectedCount = rejectedSkippedCount()
            if canResumeImport {
                statusMessage = "Partial import found: \(recordedCount) of \(mediaFiles.count) files already handled."
            } else if recordedCount == mediaFiles.count {
                if rejectedCount > 0 {
                    statusMessage = "Previous import completed with \(rejectedCount) files skipped by Photos."
                } else {
                    resetImportStates()
                    activeManifest = nil
                    statusMessage = "Previous import completed. Import All will start over."
                }
            } else {
                statusMessage = "Scan complete."
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not read import manifest."
        }
    }

    private func applyManifest(_ manifest: ImportManifest) {
        for index in mediaFiles.indices {
            if let item = manifest.importedItems[mediaFiles[index].resumeKey] {
                switch item.status {
                case .imported:
                    mediaFiles[index].importState = .skipped(nil)
                case .skipped:
                    mediaFiles[index].importState = .skipped(
                        item.skippedReason ?? "Skipped because Photos rejected this file."
                    )
                }
            } else {
                mediaFiles[index].importState = .pending
            }
        }
    }

    private func resetImportStates() {
        for index in mediaFiles.indices {
            mediaFiles[index].importState = .pending
        }
    }

    private func hasUnfinishedManifest(_ manifest: ImportManifest, mediaFiles: [MediaItem]) -> Bool {
        let importedCount = mediaFiles.filter { manifest.importedItems[$0.resumeKey] != nil }.count
        return importedCount > 0 && importedCount < mediaFiles.count
    }

    private func deleteImportedSourceFiles(using manifest: ImportManifest) -> SourceDeletionResult {
        let importedKeys = Set(manifest.importedItems.values.compactMap { item in
            item.status == .imported ? item.resumeKey : nil
        })
        var result = SourceDeletionResult()

        for index in mediaFiles.indices where importedKeys.contains(mediaFiles[index].resumeKey) {
            let media = mediaFiles[index]

            guard FileManager.default.fileExists(atPath: media.url.path) else {
                mediaFiles[index].importState = .deleted
                result.alreadyMissing += 1
                continue
            }

            do {
                try FileManager.default.removeItem(at: media.url)
                mediaFiles[index].importState = .deleted
                result.deleted += 1
            } catch {
                mediaFiles[index].importState = .deleteFailed(error.localizedDescription)
                result.failures.append(media.relativePath)
            }
        }

        return result
    }

    private func deletionStatus(for result: SourceDeletionResult) -> String {
        let rejectedCount = rejectedSkippedCount()

        if result.failures.isEmpty {
            if rejectedCount > 0 {
                return "Import complete with \(rejectedCount) files skipped by Photos. Deleted \(result.successfulCount) source files."
            }

            return "Import complete. Deleted \(result.successfulCount) source files."
        }

        return "Import complete, but \(result.failures.count) source files could not be deleted."
    }

    private func importCompletionStatus() -> String {
        let rejectedCount = rejectedSkippedCount()
        guard rejectedCount > 0 else {
            return "Import complete."
        }

        return "Import complete with \(rejectedCount) files skipped by Photos."
    }

    private func rejectedSkippedCount() -> Int {
        mediaFiles.filter { media in
            if case .skipped(let reason) = media.importState {
                return reason != nil
            }
            return false
        }.count
    }

    private func nextBatchIndexes(from pendingIndexes: [Array<MediaItem>.Index], limits: BatchLimits) -> [Array<MediaItem>.Index] {
        var batch: [Array<MediaItem>.Index] = []
        var totalBytes: Int64 = 0
        var videoCount = 0

        for index in pendingIndexes {
            let item = mediaFiles[index]
            let isVideo = item.kind == .video
            let wouldExceedFileLimit = batch.count >= limits.fileLimit
            let wouldExceedByteLimit = totalBytes + item.size > limits.byteLimit
            let wouldExceedVideoLimit = isVideo && videoCount >= limits.maxVideoFileLimit

            if !batch.isEmpty && (wouldExceedFileLimit || wouldExceedByteLimit || wouldExceedVideoLimit) {
                break
            }

            batch.append(index)
            totalBytes += item.size
            if isVideo {
                videoCount += 1
            }
        }

        return batch
    }

    private func batchStatus(
        fileCount: Int,
        bytes: Int64,
        elapsed: TimeInterval,
        limits: BatchLimits
    ) -> String {
        let bytesPerSecond = Int64(Double(bytes) / max(elapsed, 0.001))
        return "Imported \(fileCount) files in \(elapsed.formatted(.number.precision(.fractionLength(1))))s at \(bytesPerSecond.fileSizeText)/s. Next batch up to \(limits.byteLimit.fileSizeText)."
    }

    private func fallbackBatchStatus(
        importedCount: Int,
        skippedCount: Int,
        elapsed: TimeInterval
    ) -> String {
        "Imported \(importedCount) files and skipped \(skippedCount) rejected files in \(elapsed.formatted(.number.precision(.fractionLength(1))))s."
    }

    private func mergeCustomSelection(with detectedVolumes: [VolumeCandidate]) -> [VolumeCandidate] {
        guard let selectedVolume,
              !detectedVolumes.contains(where: { $0.id == selectedVolume.id }) else {
            return detectedVolumes
        }

        return [selectedVolume] + detectedVolumes
    }

    private func clearPhotosPermissionActions() {
        canOpenPhotosSettings = false
        canResetPhotosPermission = false
    }

    private static func isPhotosAuthorizationError(_ error: Error) -> Bool {
        guard let error = error as? PhotoKitImportError else {
            return false
        }

        switch error {
        case .accessDenied, .invalidPrivacyAuthorization:
            return true
        case .unsupportedMedia, .missingPlaceholder, .partialImport, .cancelled:
            return false
        }
    }
}

private struct SourceDeletionResult {
    var deleted = 0
    var alreadyMissing = 0
    var failures: [String] = []

    var successfulCount: Int {
        deleted + alreadyMissing
    }

    var errorMessage: String? {
        guard !failures.isEmpty else {
            return nil
        }

        return "Import complete, but could not delete: \(failures.prefix(3).joined(separator: ", "))"
    }
}

private struct OneByOneImportResult {
    var importedCount = 0
    var skippedCount = 0
}

private enum PhotosPermissionResetter {
    static func reset(bundleIdentifier: String) throws {
        try reset(service: "PhotosAdd", bundleIdentifier: bundleIdentifier)
        try reset(service: "Photos", bundleIdentifier: bundleIdentifier)
    }

    private static func reset(service: String, bundleIdentifier: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: output + errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            throw PhotosPermissionResetError(service: service, message: message)
        }
    }
}

private struct PhotosPermissionResetError: LocalizedError {
    let service: String
    let message: String?

    var errorDescription: String? {
        if let message, !message.isEmpty {
            return "Could not reset \(service) permission: \(message)"
        }

        return "Could not reset \(service) permission."
    }
}
