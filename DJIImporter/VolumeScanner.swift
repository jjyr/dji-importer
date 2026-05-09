import Foundation

enum VolumeScanner {
    static func mountedVolumes() -> [VolumeCandidate] {
        let fileManager = FileManager.default
        let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .volumeLocalizedNameKey,
            .volumeNameKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
        ]

        guard let volumeURLs = try? fileManager.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let rootAttributes = try? fileManager.attributesOfFileSystem(forPath: "/")
        let rootSystemNumber = rootAttributes?[.systemNumber] as? NSNumber

        return volumeURLs.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isDirectory == true else {
                return nil
            }

            let standardizedURL = url.standardizedFileURL
            if let rootSystemNumber,
               let volumeAttributes = try? fileManager.attributesOfFileSystem(forPath: standardizedURL.path),
               let volumeSystemNumber = volumeAttributes[.systemNumber] as? NSNumber,
               volumeSystemNumber == rootSystemNumber {
                return nil
            }

            let name = values.volumeLocalizedName ?? values.volumeName ?? standardizedURL.lastPathComponent
            let hasDCIM = fileManager.fileExists(atPath: standardizedURL.appendingPathComponent("DCIM").path)
            let lowerName = name.lowercased()
            let lowerPath = standardizedURL.path.lowercased()
            let likelyCameraVolume = hasDCIM || lowerName.contains("dji") || lowerPath.contains("dji")

            return VolumeCandidate(
                url: standardizedURL,
                name: name,
                isLikelyCameraVolume: likelyCameraVolume,
                totalCapacity: values.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values.volumeAvailableCapacity.map(Int64.init)
            )
        }
        .sorted { left, right in
            if left.isLikelyCameraVolume != right.isLikelyCameraVolume {
                return left.isLikelyCameraVolume
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    static func customVolume(for url: URL) -> VolumeCandidate {
        let standardizedURL = url.standardizedFileURL
        let name = standardizedURL.lastPathComponent.isEmpty ? standardizedURL.path : standardizedURL.lastPathComponent
        let hasDCIM = FileManager.default.fileExists(atPath: standardizedURL.appendingPathComponent("DCIM").path)

        return VolumeCandidate(
            url: standardizedURL,
            name: name,
            subtitle: standardizedURL.path,
            isLikelyCameraVolume: hasDCIM || name.lowercased().contains("dji")
        )
    }
}
