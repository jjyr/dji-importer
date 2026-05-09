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

        do {
            var manifest = try manifest(for: mode, selectedVolume: selectedVolume)
            activeManifest = manifest

            if mode == .startOver {
                resetImportStates()
                canResumeImport = false
            } else {
                applyManifest(manifest)
            }

            let skipped = mediaFiles.filter { $0.importState == .skipped }.count
            progress = ImportProgressState(
                total: mediaFiles.count,
                completed: skipped,
                succeeded: 0,
                skipped: skipped,
                failed: 0,
                currentFile: nil
            )

            let pendingCount = mediaFiles.count - skipped
            guard pendingCount > 0 else {
                statusMessage = "Nothing left to import."
                isImporting = false
                return
            }

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
                let importedAssets = try await PhotoKitImporter.importBatch(batch)
                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                let importedBytes = batch.reduce(Int64(0)) { $0 + $1.size }

                let localIdentifiersByKey = Dictionary(
                    uniqueKeysWithValues: importedAssets.map { ($0.resumeKey, $0.localIdentifier) }
                )

                for index in batchIndexes {
                    let media = mediaFiles[index]
                    guard let localIdentifier = localIdentifiersByKey[media.resumeKey] else {
                        continue
                    }

                    mediaFiles[index].importState = .finished(localIdentifier)
                    manifest.importedItems[media.resumeKey] = ImportManifestItem(
                        relativePath: media.relativePath,
                        size: media.size,
                        modificationDate: media.modificationDate,
                        localIdentifier: localIdentifier,
                        importedAt: Date()
                    )
                }

                try manifestStore.save(manifest)
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
            }

            if Task.isCancelled {
                statusMessage = "Import cancelled. Resume Import will skip completed batches."
                canResumeImport = hasUnfinishedManifest(manifest, mediaFiles: mediaFiles)
            } else {
                statusMessage = "Import complete."
                canResumeImport = false
            }
        } catch {
            for index in mediaFiles.indices where mediaFiles[index].importState == .importing {
                mediaFiles[index].importState = .failed(error.localizedDescription)
            }
            progress.failed += mediaFiles.filter {
                if case .failed = $0.importState {
                    return true
                }
                return false
            }.count
            lastError = error.localizedDescription
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

            let importedCount = mediaFiles.filter { $0.importState == .skipped }.count
            if canResumeImport {
                statusMessage = "Partial import found: \(importedCount) of \(mediaFiles.count) files already imported."
            } else if importedCount == mediaFiles.count {
                resetImportStates()
                activeManifest = nil
                statusMessage = "Previous import completed. Import All will start over."
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
            if manifest.importedItems[mediaFiles[index].resumeKey] != nil {
                mediaFiles[index].importState = .skipped
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

    private func mergeCustomSelection(with detectedVolumes: [VolumeCandidate]) -> [VolumeCandidate] {
        guard let selectedVolume,
              !detectedVolumes.contains(where: { $0.id == selectedVolume.id }) else {
            return detectedVolumes
        }

        return [selectedVolume] + detectedVolumes
    }
}
