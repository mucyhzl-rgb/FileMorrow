import Foundation

/// Finds ZIP archives whose contents are already sitting on disk, unpacked.
///
/// The check is deliberately strict: every single file entry in the archive
/// must exist at the matching relative path *and* match its uncompressed byte
/// size. A partial or renamed extraction is never reported, because the only
/// action offered afterwards is moving the archive to Trash.
actor ExtractedArchiveScanner {
    /// Archives larger than this many entries are skipped; the per-entry `stat`
    /// cost stops being worth it and such archives are rarely hand-extracted.
    private let entryLimit = 20_000
    private let processTimeout: TimeInterval = 20

    private struct Entry {
        let path: String
        let size: Int64
    }

    func scan(
        root: URL,
        profile: OrganizationProfile,
        progress: (@Sendable (ExtractedArchiveScanProgress) async -> Void)? = nil
    ) async -> [ExtractedArchive] {
        let archives = archiveURLs(root: root, profile: profile)
        guard !archives.isEmpty else { return [] }

        var results: [ExtractedArchive] = []
        for (index, archive) in archives.enumerated() {
            guard !Task.isCancelled else { return [] }
            await progress?(.init(
                completedArchives: index,
                totalArchives: archives.count,
                currentArchive: archive.lastPathComponent
            ))
            if let match = extractedArchive(at: archive, root: root) {
                results.append(match)
            }
        }
        await progress?(.init(
            completedArchives: archives.count,
            totalArchives: archives.count,
            currentArchive: nil
        ))
        return results.sorted { $0.archiveSize > $1.archiveSize }
    }

    func trash(_ archive: ExtractedArchive, trash: ((URL) throws -> Void)? = nil) throws -> Bool {
        guard FileManager.default.fileExists(atPath: archive.archiveURL.path) else { return false }
        // Re-verify immediately before deleting: the extracted folder may have
        // been moved or emptied since the scan produced this result.
        guard verify(archive.archiveURL, against: archive.destinationURL) != nil else {
            throw ExtractedArchiveError.contentsNoLongerMatch(archive.name)
        }
        if let trash {
            try trash(archive.archiveURL)
        } else {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: archive.archiveURL, resultingItemURL: &resultingURL)
        }
        return true
    }

    // MARK: - Discovery

    /// Top-level ZIPs in Downloads, plus ZIPs already filed into a managed
    /// category folder. Arbitrary user folders are never walked.
    private func archiveURLs(root: URL, profile: OrganizationProfile) -> [URL] {
        var folders = [root]
        for definition in profile.enabledCategories where definition.category != .needsReview {
            let folder = root.appending(path: definition.folderName, directoryHint: .isDirectory)
            if AppSupportPaths.hasManagedMarker(in: folder) { folders.append(folder) }
        }

        return folders.flatMap { folder -> [URL] in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                $0.pathExtension.lowercased() == "zip"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func extractedArchive(at archive: URL, root: URL) -> ExtractedArchive? {
        guard let entries = entries(of: archive), !entries.isEmpty else { return nil }

        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let stem = archive.deletingPathExtension().lastPathComponent

        // An archive filed into a managed folder was unpacked where it was
        // downloaded, so Downloads itself is also a candidate parent.
        var parents = [archive.deletingLastPathComponent()]
        if parents[0] != root { parents.append(root) }

        for parent in parents {
            // Archive Utility either creates a folder named after the archive…
            if let match = verify(entries, in: parent.appending(path: stem, directoryHint: .isDirectory), stripping: nil) {
                return ExtractedArchive(
                    archiveURL: archive,
                    destinationURL: parent.appending(path: stem, directoryHint: .isDirectory),
                    archiveSize: archiveSize,
                    entryCount: entries.count,
                    extractedSize: match
                )
            }
            // …or unpacks a single wrapped top-level folder straight into
            // place. This is the common shape: report.zip holding report/.
            if let top = singleTopLevelComponent(of: entries) {
                let destination = parent.appending(path: top, directoryHint: .isDirectory)
                if let match = verify(entries, in: destination, stripping: "\(top)/") {
                    return ExtractedArchive(
                        archiveURL: archive,
                        destinationURL: destination,
                        archiveSize: archiveSize,
                        entryCount: entries.count,
                        extractedSize: match
                    )
                }
            }
        }
        return nil
    }

    /// Convenience re-check used before trashing. Returns the verified byte
    /// total, or nil when the destination no longer holds the full contents.
    private func verify(_ archive: URL, against destination: URL) -> Int64? {
        guard let entries = entries(of: archive), !entries.isEmpty else { return nil }
        if let total = verify(entries, in: destination, stripping: nil) { return total }
        if let top = singleTopLevelComponent(of: entries) {
            return verify(entries, in: destination, stripping: "\(top)/")
        }
        return nil
    }

    /// Every entry must exist under `destination` at its relative path with an
    /// exactly matching size. Any miss fails the whole archive.
    private func verify(_ entries: [Entry], in destination: URL, stripping prefix: String?) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        var total: Int64 = 0
        for entry in entries {
            var relative = entry.path
            if let prefix {
                guard relative.hasPrefix(prefix) else { return nil }
                relative = String(relative.dropFirst(prefix.count))
            }
            guard !relative.isEmpty else { return nil }
            let candidate = destination.appending(path: relative)
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == entry.size else { return nil }
            total += entry.size
        }
        return total
    }

    private func singleTopLevelComponent(of entries: [Entry]) -> String? {
        let tops = Set(entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        guard tops.count == 1, let top = tops.first else { return nil }
        // Only a real wrapper folder counts; a flat archive has no leading path.
        guard entries.allSatisfy({ $0.path.contains("/") }) else { return nil }
        return top
    }

    // MARK: - Archive listing

    private func entries(of archive: URL) -> [Entry]? {
        guard let listing = run("/usr/bin/unzip", ["-l", "-qq", archive.path]) else { return nil }
        var entries: [Entry] = []
        for line in listing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let size = Int64(parts[0]) else { continue }
            let path = String(parts[3]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !path.hasSuffix("/") else { continue }
            guard !isMetadataEntry(path) else { continue }
            // Refuse anything that could resolve outside the destination.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            entries.append(.init(path: path, size: size))
            if entries.count > entryLimit { return nil }
        }
        return entries
    }

    /// Bookkeeping macOS writes into ZIPs but discards on extraction.
    private func isMetadataEntry(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.first == "__MACOSX" { return true }
        return components.contains { $0 == ".DS_Store" || $0.hasPrefix("._") }
    }

    private func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Never let an encrypted or corrupt archive block on a prompt.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(processTimeout)
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 4_000_000 || Date() > deadline { break }
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            guard process.terminationStatus == 0 || !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            if process.isRunning { process.terminate() }
            return nil
        }
    }
}

enum ExtractedArchiveError: LocalizedError {
    case contentsNoLongerMatch(String)

    var errorDescription: String? {
        switch self {
        case let .contentsNoLongerMatch(name):
            "\(name) was left in place: its extracted files no longer match the archive."
        }
    }
}
