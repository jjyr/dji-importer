import AppKit
import Foundation

@MainActor
final class ImportViewModel: ObservableObject {
    @Published private(set) var volumes: [VolumeCandidate] = []
    @Published var selectedVolumeID: VolumeCandidate.ID?
    @Published private(set) var mediaFiles: [MediaItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isImporting = false
    @Published private(set) var progress = ImportProgressState.empty
    @Published private(set) var statusMessage = "Connect DJI Pocket 3 or choose a folder."
    @Published private(set) var lastError: String?

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
                self?.statusMessage = items.isEmpty ? "No supported media found." : "Scan complete."
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

    func startImportAll() {
        guard !isScanning, !isImporting, !mediaFiles.isEmpty else {
            return
        }

        importTask = Task { [weak self] in
            await self?.importAll()
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isImporting = false

        for index in mediaFiles.indices where mediaFiles[index].importState == .importing {
            mediaFiles[index].importState = .pending
        }

        statusMessage = "Import cancelled."
    }

    private func importAll() async {
        isImporting = true
        lastError = nil
        progress = ImportProgressState(total: mediaFiles.count)
        statusMessage = "Starting import into Photos..."

        for index in mediaFiles.indices {
            if Task.isCancelled {
                break
            }

            mediaFiles[index].importState = .importing
            progress.currentFile = mediaFiles[index].relativePath
            statusMessage = "Importing \(mediaFiles[index].relativePath)"

            let fileURL = mediaFiles[index].url
            let result = await Task.detached(priority: .userInitiated) {
                PhotosImporter.importFile(fileURL)
            }.value

            if result.succeeded {
                mediaFiles[index].importState = .finished(result.message.isEmpty ? nil : result.message)
                progress.succeeded += 1
            } else {
                let message = result.message.isEmpty ? "Unknown Photos import error." : result.message
                mediaFiles[index].importState = .failed(message)
                progress.failed += 1
            }

            progress.completed += 1
        }

        isImporting = false
        progress.currentFile = nil

        if Task.isCancelled {
            statusMessage = "Import cancelled."
        } else if progress.failed == 0 {
            statusMessage = "Import complete."
        } else {
            statusMessage = "Import complete with \(progress.failed) failed files."
        }
    }

    private func mergeCustomSelection(with detectedVolumes: [VolumeCandidate]) -> [VolumeCandidate] {
        guard let selectedVolume,
              !detectedVolumes.contains(where: { $0.id == selectedVolume.id }) else {
            return detectedVolumes
        }

        return [selectedVolume] + detectedVolumes
    }
}
