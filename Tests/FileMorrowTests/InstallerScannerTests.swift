import Foundation
import XCTest
@testable import FileMorrow

final class InstallerScannerTests: XCTestCase {

    // MARK: - Disk images matched to installed apps

    func testDiskImageForAnInstalledAppIsReported() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try harness.makeInstaller("Zoom-6.1.2-arm64.dmg", bytes: 4_096)
        try harness.installApp(named: "zoom.us", bundleName: "Zoom", version: "6.1.2")

        let found = await harness.scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].evidence, .installedApp)
        XCTAssertEqual(found[0].comparison, .sameVersion)
        XCTAssertEqual(found[0].installerVersion, "6.1.2")
        XCTAssertEqual(found[0].installedVersion, "6.1.2")
    }

    func testAppThatUpdatedItselfSinceTheDownloadIsStillReported() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        // The classic case: the DMG was for 6.1.2, the app has since updated
        // itself to 7.0.1, so the installer on disk is stale.
        try harness.makeInstaller("Zoom-6.1.2-arm64.dmg", bytes: 4_096)
        try harness.installApp(named: "zoom.us", bundleName: "Zoom", version: "7.0.1")

        let found = await harness.scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].comparison, .installedIsNewer)
        XCTAssertEqual(found[0].comparison.summary, "Already updated past this version")
    }

    func testPendingUpdateIsNeverReported() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        // A newer installer than what is installed is an update the user has
        // downloaded but not applied. Deleting it would lose the update.
        try harness.makeInstaller("Zoom-7.0.1-arm64.dmg", bytes: 4_096)
        try harness.installApp(named: "zoom.us", bundleName: "Zoom", version: "6.1.2")

        let found = await harness.scan()
        XCTAssertTrue(found.isEmpty)
    }

    func testInstallerForSoftwareThatIsNotInstalledIsNotReported() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try harness.makeInstaller("SomeAppNobodyInstalled-1.0.dmg", bytes: 2_048)
        try harness.installApp(named: "Zoom", bundleName: "Zoom", version: "6.1.2")

        let found = await harness.scan()
        XCTAssertTrue(found.isEmpty)
    }

    func testInstallerWithoutAVersionInItsNameStillMatches() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try harness.makeInstaller("Rectangle.dmg", bytes: 1_024)
        try harness.installApp(named: "Rectangle", bundleName: "Rectangle", version: "0.9")

        let found = await harness.scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].comparison, .unknownVersion)
        XCTAssertNil(found[0].installerVersion)
    }

    func testAppsInsideAnApplicationsSubfolderAreFound() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try harness.makeInstaller("Cyberduck-8.7.dmg", bytes: 2_048)
        try harness.installApp(named: "Cyberduck", bundleName: "Cyberduck", version: "8.7", inSubfolder: "Utilities")

        let found = await harness.scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].installedLocation.contains("Utilities"))
    }

    func testInstallersFiledIntoAManagedFolderAreChecked() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let managed = harness.downloads.appending(path: "Apps & Installers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: managed.appending(path: ".filemorrow-managed"))
        try Data(repeating: 0, count: 2_048).write(to: managed.appending(path: "Rectangle-0.9.dmg"))
        try harness.installApp(named: "Rectangle", bundleName: "Rectangle", version: "0.9")

        let found = await harness.scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].name, "Rectangle-0.9.dmg")
    }

    func testNonInstallerFilesAreIgnored() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try Data("not an installer".utf8).write(to: harness.downloads.appending(path: "Zoom-6.1.2.txt"))
        try harness.installApp(named: "Zoom", bundleName: "Zoom", version: "6.1.2")

        let found = await harness.scan()
        XCTAssertTrue(found.isEmpty)
    }

    func testResultsAreOrderedByReclaimableSize() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try harness.makeInstaller("Rectangle-0.9.dmg", bytes: 1_000)
        try harness.makeInstaller("Cyberduck-8.7.dmg", bytes: 90_000)
        try harness.installApp(named: "Rectangle", bundleName: "Rectangle", version: "0.9")
        try harness.installApp(named: "Cyberduck", bundleName: "Cyberduck", version: "8.7")

        let found = await harness.scan()
        XCTAssertEqual(found.map(\.name), ["Cyberduck-8.7.dmg", "Rectangle-0.9.dmg"])
    }

    func testTrashMovesOnlyTheInstaller() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try harness.makeInstaller("Rectangle-0.9.dmg", bytes: 1_024)
        let app = try harness.installApp(named: "Rectangle", bundleName: "Rectangle", version: "0.9")

        let scanner = InstallerScanner()
        let found = await scanner.scan(
            root: harness.downloads,
            profile: TestProfiles.general,
            applicationFolders: [harness.applications]
        )
        XCTAssertEqual(found.count, 1)

        let recorder = TrashRecorder()
        let didTrash = try await scanner.trash(found[0]) { url in
            recorder.append(url)
            try FileManager.default.removeItem(at: url)
        }

        XCTAssertTrue(didTrash)
        XCTAssertEqual(recorder.urls.map(\.lastPathComponent), ["Rectangle-0.9.dmg"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: app.path),
            "The installed application must never be touched"
        )
    }

    func testProgressCompletes() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.makeInstaller("Rectangle-0.9.dmg", bytes: 512)

        actor Updates {
            var values: [InstallerScanProgress] = []
            func append(_ value: InstallerScanProgress) { values.append(value) }
        }
        let updates = Updates()
        _ = await InstallerScanner().scan(
            root: harness.downloads,
            profile: TestProfiles.general,
            applicationFolders: [harness.applications]
        ) { update in
            await updates.append(update)
        }

        let values = await updates.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last?.fraction, 1)
    }

    // MARK: - Real packages

    func testRealPackageForSoftwareThatIsNotInstalledIsNotReported() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pkgbuild") else {
            throw XCTSkip("pkgbuild is unavailable on this machine")
        }
        let harness = try Harness()
        defer { harness.cleanUp() }

        // A genuine flat package, built here, whose identifier has certainly
        // never been installed. This exercises the whole receipt path: listing
        // the archive, extracting its metadata, parsing identifiers, and
        // asking pkgutil for a receipt.
        let payload = harness.root.appending(path: "payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: payload.appending(path: "tool"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkgbuild")
        process.arguments = [
            "--root", payload.path,
            "--identifier", "com.filemorrow.tests.never-installed",
            "--version", "1.0",
            "--install-location", "/tmp/filemorrow-tests",
            harness.downloads.appending(path: "TestTool-1.0.pkg").path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "pkgbuild could not produce a package")

        let found = await harness.scan()
        XCTAssertTrue(
            found.isEmpty,
            "A package whose identifier has no install receipt must never be offered for cleanup"
        )
    }

    func testPackageWithoutReadableMetadataIsNotReported() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        // Not a real xar archive at all.
        try Data("this is not a package".utf8).write(to: harness.downloads.appending(path: "Broken-1.0.pkg"))

        let found = await harness.scan()
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Pure parsing

    func testFilenameVersionExtraction() {
        XCTAssertEqual(InstallerScanner.version(inFilename: "Zoom-6.1.2-arm64.dmg"), "6.1.2")
        XCTAssertEqual(InstallerScanner.version(inFilename: "Firefox 128.0.1.dmg"), "128.0.1")
        XCTAssertEqual(InstallerScanner.version(inFilename: "Tool_2.10.dmg"), "2.10")
        XCTAssertNil(InstallerScanner.version(inFilename: "Rectangle.dmg"))
        XCTAssertNil(InstallerScanner.version(inFilename: "Installer.pkg"))
    }

    func testNameNormalisationStripsPackagingNoise() {
        XCTAssertEqual(InstallerScanner.normalized("Zoom-6.1.2-arm64.dmg"), "zoom")
        XCTAssertEqual(InstallerScanner.normalized("Zoom"), "zoom")
        XCTAssertEqual(
            InstallerScanner.normalized("Visual Studio Code-1.90-universal"),
            InstallerScanner.normalized("Visual Studio Code")
        )
        XCTAssertEqual(InstallerScanner.normalized("Docker_installer_macos_arm64"), "docker")
    }

    func testVersionComparison() {
        XCTAssertEqual(InstallerScanner.comparison(installer: "1.2", installed: "1.10"), .installedIsNewer)
        XCTAssertEqual(InstallerScanner.comparison(installer: "2.0", installed: "2.0"), .sameVersion)
        XCTAssertEqual(InstallerScanner.comparison(installer: "3.1", installed: "3.0"), .installerIsNewer)
        XCTAssertEqual(InstallerScanner.comparison(installer: nil, installed: "3.0"), .unknownVersion)
        XCTAssertEqual(InstallerScanner.comparison(installer: "3.0", installed: nil), .unknownVersion)
    }

    func testVersionAttributeIsNotConfusedWithFormatVersion() {
        let metadata = #"<pkg-info format-version="2" identifier="com.example.flat" version="9.9"/>"#
        XCTAssertEqual(InstallerScanner.identifiers(inPackageMetadata: metadata).first?.1, "9.9")
    }

    func testPackageMetadataIdentifiersAreParsed() {
        let distribution = """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="1">
            <pkg-ref id="com.example.tool"/>
            <pkg-ref id="com.example.tool" version="3.4.5" onConclusion="none">tool.pkg</pkg-ref>
            <pkg-ref id="com.example.helper" version="1.0"/>
        </installer-gui-script>
        """
        let parsed = InstallerScanner.identifiers(inPackageMetadata: distribution)
        XCTAssertEqual(parsed.map(\.0), ["com.example.helper", "com.example.tool"])
        XCTAssertEqual(parsed.first { $0.0 == "com.example.tool" }?.1, "3.4.5")
    }

    func testFlatPackageInfoIsParsed() {
        let packageInfo = """
        <pkg-info format-version="2" identifier="com.example.flat" version="9.9" install-location="/"/>
        """
        let parsed = InstallerScanner.identifiers(inPackageMetadata: packageInfo)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].0, "com.example.flat")
        XCTAssertEqual(parsed[0].1, "9.9")
    }

    func testMetadataWithoutIdentifiersYieldsNothing() {
        XCTAssertTrue(InstallerScanner.identifiers(inPackageMetadata: "<installer-gui-script/>").isEmpty)
        XCTAssertTrue(InstallerScanner.identifiers(inPackageMetadata: #"<pkg-ref id="notadotted"/>"#).isEmpty)
    }

    // MARK: - Harness

    private struct Harness {
        let root: URL
        let downloads: URL
        let applications: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            applications = root.appending(path: "Applications", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func scan() async -> [RedundantInstaller] {
            await InstallerScanner().scan(
                root: downloads,
                profile: TestProfiles.general,
                applicationFolders: [applications]
            )
        }

        func makeInstaller(_ name: String, bytes: Int) throws {
            try Data(repeating: 0, count: bytes).write(to: downloads.appending(path: name))
        }

        @discardableResult
        func installApp(
            named name: String,
            bundleName: String,
            version: String,
            inSubfolder subfolder: String? = nil
        ) throws -> URL {
            var parent = applications
            if let subfolder {
                parent = applications.appending(path: subfolder, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            let app = parent.appending(path: "\(name).app", directoryHint: .isDirectory)
            let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleName": bundleName,
                "CFBundleShortVersionString": version,
                "CFBundleIdentifier": "com.test.\(bundleName.lowercased())"
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try data.write(to: contents.appending(path: "Info.plist"))
            return app
        }
    }
}

private final class TrashRecorder: @unchecked Sendable {
    private(set) var urls: [URL] = []

    func append(_ url: URL) { urls.append(url) }
}
