import Foundation

/// Where the cleanup scanners are allowed to look.
///
/// Only the top level of Downloads and folders FileMorrow itself created and
/// marked. Arbitrary user or downloaded folders are never enumerated here; the
/// duplicate finder is the single workflow that walks the tree, and it does so
/// read-only.
enum DownloadsFolders {
    static func managedScanRoots(root: URL, profile: OrganizationProfile) -> [URL] {
        var folders = [root]
        for definition in profile.enabledCategories where definition.category != .needsReview {
            let folder = root.appending(path: definition.folderName, directoryHint: .isDirectory)
            if AppSupportPaths.hasManagedMarker(in: folder) { folders.append(folder) }
        }
        return folders
    }

    /// Regular files directly inside the given folders whose extension matches,
    /// in a stable order so results do not shuffle between scans.
    static func files(in folders: [URL], extensions: Set<String>) -> [URL] {
        folders.flatMap { folder -> [URL] in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                extensions.contains($0.pathExtension.lowercased())
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
