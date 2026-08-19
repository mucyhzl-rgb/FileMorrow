import Foundation

/// Finds `.dmg` and `.pkg` installers in Downloads whose software is already
/// installed on this Mac.
///
/// Two independent kinds of evidence are used, and neither one mounts, opens,
/// or runs an installer:
///
/// - A `.pkg` carries the package identifiers and versions it installs. Those
///   are read from the archive's metadata and checked against the receipts
///   macOS keeps for packages that were actually installed. That is an exact
///   match, not a guess.
/// - A `.dmg` is matched by name against the apps present in Applications,
///   with the version in the filename compared against the installed bundle.
///
/// An installer newer than what is installed is never reported: that is an
/// update the user has downloaded but not applied yet.
actor InstallerScanner {
    private let processTimeout: TimeInterval = 20

    func scan(
        root: URL,
        profile: OrganizationProfile,
        applicationFolders: [URL]? = nil,
        progress: (@Sendable (InstallerScanProgress) async -> Void)? = nil
    ) async -> [RedundantInstaller] {
        let installers = DownloadsFolders.files(
            in: DownloadsFolders.managedScanRoots(root: root, profile: profile),
            extensions: ["dmg", "pkg", "mpkg"]
        )
        guard !installers.isEmpty else { return [] }

        let installedApps = installedApps(in: applicationFolders ?? Self.defaultApplicationFolders())
        var results: [RedundantInstaller] = []

        for (index, installer) in installers.enumerated() {
            guard !Task.isCancelled else { return [] }
            await progress?(.init(
                completedInstallers: index,
                totalInstallers: installers.count,
                currentInstaller: installer.lastPathComponent
            ))
            if let match = redundantInstaller(at: installer, installedApps: installedApps) {
                results.append(match)
            }
        }

        await progress?(.init(
            completedInstallers: installers.count,
            totalInstallers: installers.count,
            currentInstaller: nil
        ))
        return results.sorted { $0.installerSize > $1.installerSize }
    }

    func trash(_ installer: RedundantInstaller, trash: ((URL) throws -> Void)? = nil) throws -> Bool {
        guard FileManager.default.fileExists(atPath: installer.installerURL.path) else { return false }
        if let trash {
            try trash(installer.installerURL)
        } else {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: installer.installerURL, resultingItemURL: &resultingURL)
        }
        return true
    }

    static func defaultApplicationFolders() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
        ]
    }

    // MARK: - Matching

    private func redundantInstaller(at url: URL, installedApps: [InstalledApp]) -> RedundantInstaller? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let installerVersion = Self.version(inFilename: url.lastPathComponent)

        if ["pkg", "mpkg"].contains(url.pathExtension.lowercased()) {
            guard let receipt = installedReceipt(for: url) else { return nil }
            return RedundantInstaller(
                installerURL: url,
                installerSize: size,
                installerVersion: receipt.packagedVersion ?? installerVersion,
                installedName: receipt.identifier,
                installedLocation: "Installed package receipt",
                installedVersion: receipt.installedVersion,
                evidence: .packageReceipt,
                comparison: Self.comparison(
                    installer: receipt.packagedVersion ?? installerVersion,
                    installed: receipt.installedVersion
                )
            )
        }

        guard let app = matchingApp(for: url, in: installedApps) else { return nil }
        let comparison = Self.comparison(installer: installerVersion, installed: app.version)
        // A newer installer than what is installed is a pending update.
        guard comparison != .installerIsNewer else { return nil }

        return RedundantInstaller(
            installerURL: url,
            installerSize: size,
            installerVersion: installerVersion,
            installedName: app.name,
            installedLocation: app.url.path,
            installedVersion: app.version,
            evidence: .installedApp,
            comparison: comparison
        )
    }

    private func matchingApp(for installer: URL, in apps: [InstalledApp]) -> InstalledApp? {
        let stem = Self.normalized(installer.deletingPathExtension().lastPathComponent)
        guard !stem.isEmpty else { return nil }

        if let exact = apps.first(where: { $0.normalizedName == stem }) { return exact }
        // Fall back to a contained name, but only for names long enough that a
        // coincidental substring is implausible.
        return apps
            .filter { $0.normalizedName.count >= 4 && stem.contains($0.normalizedName) }
            .max { $0.normalizedName.count < $1.normalizedName.count }
    }

    // MARK: - Installed applications

    private func installedApps(in folders: [URL]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in folders {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in contents {
                if entry.pathExtension.lowercased() == "app" {
                    if let app = installedApp(at: entry) { apps.append(app) }
                    continue
                }
                // One level down covers /Applications/Utilities and similar.
                let nested = (try? FileManager.default.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for child in nested where child.pathExtension.lowercased() == "app" {
                    if let app = installedApp(at: child) { apps.append(app) }
                }
            }
        }
        return apps
    }

    private func installedApp(at url: URL) -> InstalledApp? {
        let plistURL = url.appending(path: "Contents/Info.plist")
        let info = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? nil

        let bundleName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)

        return InstalledApp(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            normalizedName: Self.normalized(bundleName),
            version: version
        )
    }

    // MARK: - Package receipts

    private struct Receipt {
        let identifier: String
        let packagedVersion: String?
        let installedVersion: String?
    }

    /// Reads the identifiers a package installs, then asks macOS whether a
    /// receipt exists for each. Every identifier must be installed at the
    /// packaged version or newer.
    private func installedReceipt(for url: URL) -> Receipt? {
        let declared = packageIdentifiers(in: url)
        guard !declared.isEmpty else { return nil }

        var first: Receipt?
        for (identifier, packagedVersion) in declared {
            guard let installedVersion = receiptVersion(for: identifier) else { return nil }
            if let packagedVersion,
               Self.comparison(installer: packagedVersion, installed: installedVersion) == .installerIsNewer {
                return nil
            }
            if first == nil {
                first = Receipt(
                    identifier: identifier,
                    packagedVersion: packagedVersion,
                    installedVersion: installedVersion
                )
            }
        }
        return first
    }

    private func packageIdentifiers(in url: URL) -> [(String, String?)] {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "filemorrow-pkg-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let listing = run("/usr/bin/xar", ["-tf", url.path]) else { return [] }
        let entries = listing.split(separator: "\n").map(String.init)
        let metadata = entries.filter {
            $0 == "Distribution" || $0 == "PackageInfo" || $0.hasSuffix("/PackageInfo")
        }
        guard !metadata.isEmpty else { return [] }

        var found: [(String, String?)] = []
        for entry in metadata.prefix(8) {
            guard run("/usr/bin/xar", ["-xf", url.path, "-C", temporary.path, entry]) != nil
                    || FileManager.default.fileExists(atPath: temporary.appending(path: entry).path)
            else { continue }
            guard let xml = try? String(contentsOf: temporary.appending(path: entry), encoding: .utf8) else {
                continue
            }
            found.append(contentsOf: Self.identifiers(inPackageMetadata: xml))
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0.0).inserted }
    }

    private func receiptVersion(for identifier: String) -> String? {
        guard let output = run("/usr/sbin/pkgutil", ["--pkg-info", identifier]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("version:") {
            return line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Parsing helpers

    /// Pulls `identifier`/`id` and `version` pairs out of a package's
    /// `Distribution` or `PackageInfo` metadata.
    static func identifiers(inPackageMetadata xml: String) -> [(String, String?)] {
        let pattern = #"<(?:pkg-ref|pkg-info)\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)

        var results: [(String, String?)] = []
        for match in regex.matches(in: xml, range: range) {
            guard let attributeRange = Range(match.range(at: 1), in: xml) else { continue }
            let attributes = String(xml[attributeRange])
            guard let identifier = attribute("identifier", in: attributes)
                    ?? attribute("id", in: attributes),
                  identifier.contains(".") else { continue }
            results.append((identifier, attribute("version", in: attributes)))
        }

        // Prefer entries that carried a version for the same identifier.
        var best: [String: String?] = [:]
        for (identifier, version) in results {
            if best[identifier] == nil || (best[identifier] ?? nil) == nil {
                best[identifier] = version
            }
        }
        return best.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        // Anchored to a preceding space so `format-version="2"` is not read as
        // the `version` attribute.
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)\(name)=\"([^\"]*)\"") else { return nil }
        let range = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = regex.firstMatch(in: attributes, range: range),
              let valueRange = Range(match.range(at: 1), in: attributes) else { return nil }
        let value = String(attributes[valueRange])
        return value.isEmpty ? nil : value
    }

    static func version(inFilename name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)+"#) else { return nil }
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let match = regex.firstMatch(in: stem, range: range),
              let valueRange = Range(match.range, in: stem) else { return nil }
        return String(stem[valueRange])
    }

    /// Strips version numbers and packaging noise so `Zoom-6.1.2-arm64.dmg`
    /// and `Zoom.app` line up.
    static func normalized(_ value: String) -> String {
        let noise: Set<String> = [
            "installer", "install", "setup", "macos", "mac", "osx", "darwin",
            "universal", "universal2", "arm64", "aarch64", "x64", "x86", "x8664",
            "intel", "applesilicon", "apple", "silicon", "dmg", "pkg", "app",
            "final", "latest", "full", "offline", "64bit", "32bit", "bit", "for"
        ]
        let separators = CharacterSet(charactersIn: " -_.+()[]")
        return value
            .lowercased()
            .components(separatedBy: separators)
            .filter { token in
                !token.isEmpty
                    && !noise.contains(token)
                    && !token.allSatisfy(\.isNumber)
                    && !(token.hasPrefix("v") && token.dropFirst().allSatisfy { $0.isNumber })
            }
            .joined()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func comparison(installer: String?, installed: String?) -> VersionComparison {
        guard let installer, let installed else { return .unknownVersion }
        switch installed.compare(installer, options: .numeric) {
        case .orderedDescending: return .installedIsNewer
        case .orderedSame: return .sameVersion
        case .orderedAscending: return .installerIsNewer
        }
    }

    // MARK: - Process

    private func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(processTimeout)
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 2_000_000 || Date() > deadline { break }
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            if process.isRunning { process.terminate() }
            return nil
        }
    }
}

struct InstalledApp: Sendable {
    let url: URL
    let name: String
    let normalizedName: String
    let version: String?
}
