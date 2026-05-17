import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ImportViewModel()
    @State private var selectedMediaIDs = Set<MediaItem.ID>()
    @State private var mediaSortOrder = [KeyPathComparator(\MediaItem.name)]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sources")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.refreshVolumes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isImporting)
                .help("Refresh volumes")
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)

            if viewModel.volumes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text("No volumes found")
                        .font(.headline)

                    Text("Connect DJI Pocket 3 or choose a folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { viewModel.selectedVolumeID },
                    set: { viewModel.selectVolume(id: $0) }
                )) {
                    ForEach(viewModel.volumes) { volume in
                        VolumeRow(volume: volume)
                            .tag(volume.id)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            Button {
                viewModel.chooseFolder()
            } label: {
                Label("Choose Folder", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isImporting)
            .padding(14)
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 260)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header

            Divider()

            mediaContent

            Divider()

            footer
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.selectedVolume?.name ?? "DJI Importer")
                    .font(.system(size: 24, weight: .semibold))

                Text(viewModel.selectedVolume?.subtitle ?? "Choose a source to scan media.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    SummaryChip(symbolName: "photo.on.rectangle.angled", text: viewModel.mediaSummary)

                    if let selectedVolume = viewModel.selectedVolume,
                       let availableCapacity = selectedVolume.availableCapacity,
                       let totalCapacity = selectedVolume.totalCapacity {
                        SummaryChip(
                            symbolName: "externaldrive",
                            text: "\(availableCapacity.fileSizeText) free of \(totalCapacity.fileSizeText)"
                        )
                    }
                }
            }

            Spacer()

            Toggle(isOn: $viewModel.deleteSourceFilesAfterImport) {
                Label("Delete Originals", systemImage: "trash")
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(viewModel.deleteSourceFilesAfterImport ? Color.red : Color.primary)
            .disabled(viewModel.isImporting)
            .help("Delete source files after every imported file is recorded in Photos")

            Button {
                viewModel.scanSelectedVolume()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.selectedVolume == nil || viewModel.isScanning || viewModel.isImporting)

            if viewModel.isImporting {
                Button(role: .cancel) {
                    viewModel.cancelImport()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    viewModel.startPrimaryImport()
                } label: {
                    Label(viewModel.primaryImportTitle, systemImage: viewModel.primaryImportSymbolName)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.mediaFiles.isEmpty || viewModel.isScanning)

                Button(role: .destructive) {
                    viewModel.startOverImport()
                } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.mediaFiles.isEmpty || viewModel.isScanning)
                .help("Clear the manifest and import this source from scratch")
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var mediaContent: some View {
        if viewModel.isScanning {
            ProgressView("Scanning media...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.mediaFiles.isEmpty {
            EmptyMediaView(hasError: viewModel.lastError != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(sortedMediaFiles, selection: $selectedMediaIDs, sortOrder: $mediaSortOrder) {
                TableColumn("Name", value: \.name) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.kind.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .lineLimit(1)

                            Text(item.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .mediaFileDragSource(for: item)
                }
                .width(min: 300, ideal: 460)

                TableColumn("Kind", value: \.kindSortValue) { item in
                    Text(item.kind.title)
                        .mediaFileDragSource(for: item)
                }
                .width(80)

                TableColumn("Size", value: \.size) { item in
                    Text(item.size.fileSizeText)
                        .mediaFileDragSource(for: item)
                }
                .width(90)

                TableColumn("Status", value: \.statusSortValue) { item in
                    StatusLabel(state: item.importState)
                        .mediaFileDragSource(for: item)
                }
                .width(120)
            }
            .contextMenu(forSelectionType: MediaItem.ID.self) { selectedIDs in
                Button {
                    openMediaItems(withIDs: selectedIDs)
                } label: {
                    Label("Open File", systemImage: "arrow.up.right.square")
                }
                .disabled(selectedIDs.isEmpty)

                Button {
                    openContainingFolders(forIDs: selectedIDs)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(selectedIDs.isEmpty)
            } primaryAction: { selectedIDs in
                openMediaItems(withIDs: selectedIDs)
            }
        }
    }

    private var sortedMediaFiles: [MediaItem] {
        viewModel.mediaFiles.sorted(using: mediaSortOrder)
    }

    private func mediaItems(withIDs selectedIDs: Set<MediaItem.ID>) -> [MediaItem] {
        viewModel.mediaFiles.filter { selectedIDs.contains($0.id) }
    }

    private func openMediaItems(withIDs selectedIDs: Set<MediaItem.ID>) {
        for item in mediaItems(withIDs: selectedIDs) {
            viewModel.openFile(item)
        }
    }

    private func openContainingFolders(forIDs selectedIDs: Set<MediaItem.ID>) {
        for item in mediaItems(withIDs: selectedIDs) {
            viewModel.openContainingFolder(item)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.progress.total > 0 {
                ProgressView(value: viewModel.progress.fraction)

                HStack {
                    Text("\(viewModel.progress.completed) of \(viewModel.progress.total)")

                    if viewModel.progress.succeeded > 0 {
                        Text("\(viewModel.progress.succeeded) done")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.progress.skipped > 0 {
                        Text("\(viewModel.progress.skipped) skipped")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.progress.deleted > 0 {
                        Text("\(viewModel.progress.deleted) deleted")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.progress.failed > 0 {
                        Text("\(viewModel.progress.failed) failed")
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    if let currentFile = viewModel.progress.currentFile {
                        Text(currentFile)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
            }

            HStack {
                Text(viewModel.lastError ?? viewModel.statusMessage)
                    .foregroundColor(viewModel.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)

                Spacer()

                if viewModel.canOpenPhotosSettings {
                    if viewModel.canResetPhotosPermission {
                        Button {
                            viewModel.resetPhotosPermission()
                        } label: {
                            Label("Reset Photos Permission", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isResettingPhotosPermission)
                    }

                    Button {
                        viewModel.openPhotosSettings()
                    } label: {
                        Label("Open Photos Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private extension View {
    func mediaFileDragSource(for item: MediaItem) -> some View {
        contentShape(Rectangle())
            .onDrag {
                NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
            }
    }
}

private struct VolumeRow: View {
    let volume: VolumeCandidate

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.isLikelyCameraVolume ? "camera" : "externaldrive")
                .foregroundStyle(volume.isLikelyCameraVolume ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .lineLimit(1)

                    if volume.isLikelyCameraVolume {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Text(volume.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SummaryChip: View {
    let symbolName: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct StatusLabel: View {
    let state: ImportState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
            Text(state.title)
        }
        .foregroundStyle(color)
        .help(helpText)
    }

    private var symbolName: String {
        switch state {
        case .pending:
            return "circle"
        case .skipped(let message):
            return message == nil ? "forward.circle.fill" : "exclamationmark.circle.fill"
        case .importing:
            return "arrow.triangle.2.circlepath"
        case .finished:
            return "checkmark.circle.fill"
        case .deleted:
            return "trash.circle.fill"
        case .deleteFailed:
            return "trash.slash.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .pending:
            return .secondary
        case .skipped(let message):
            return message == nil ? .secondary : .orange
        case .importing:
            return .blue
        case .finished:
            return .green
        case .deleted:
            return .green
        case .deleteFailed:
            return .red
        case .failed:
            return .red
        }
    }

    private var helpText: String {
        switch state {
        case .pending:
            return "Ready to import"
        case .skipped(let message):
            return message ?? "Already imported in the current manifest; skipped for resume"
        case .importing:
            return "Importing into Photos"
        case .finished(let message):
            return message ?? "Imported into Photos"
        case .deleted:
            return "Imported into Photos and deleted from the source"
        case .deleteFailed(let message):
            return message
        case .failed(let message):
            return message
        }
    }
}

private struct EmptyMediaView: View {
    let hasError: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasError ? "exclamationmark.triangle" : "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(hasError ? .red : .secondary)

            Text(hasError ? "Scan failed" : "No media to import")
                .font(.headline)

            Text(hasError ? "Check the selected source and try again." : "Supported formats: JPG, JPEG, MP4.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
