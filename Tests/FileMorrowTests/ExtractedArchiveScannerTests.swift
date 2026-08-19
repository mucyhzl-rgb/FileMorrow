import Foundation
import XCTest
@testable import FileMorrow

final class ExtractedArchiveScannerTests: XCTestCase {
    func testDetectsArchiveUnpackedIntoItsOwnFolder() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try write("world!", to: root.appending(path: "report/sub/c.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))

        let found = await scan(root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].name, "report.zip")
        XCTAssertEqual(found[0].destinationURL.lastPathComponent, "report")
        XCTAssertEqual(found[0].entryCount, 2)
        XCTAssertEqual(found[0].extractedSize, 11, "5 bytes + 6 bytes of verified content")
    }

    func testDetectsFlatArchiveUnpackedIntoAFolderNamedAfterIt() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        try write("one", to: staging.appending(path: "a.txt"))
        try write("two", to: staging.appending(path: "b.txt"))
        try zip(["a.txt", "b.txt"], in: staging, to: root.appending(path: "notes.zip"))

        // Archive Utility unpacks a flat archive into <name>/.
        try write("one", to: root.appending(path: "notes/a.txt"))
        try write("two", to: root.appending(path: "notes/b.txt"))
        try FileManager.default.removeItem(at: staging)

        let found = await scan(root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].destinationURL.lastPathComponent, "notes")
        XCTAssertEqual(found[0].entryCount, 2)
    }

    func testDetectsWrappedFolderWithADifferentNameFromTheArchive() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("payload", to: root.appending(path: "Project Files/readme.md"))
        try zip(["Project Files"], in: root, to: root.appending(path: "project-v2-final.zip"))

        let found = await scan(root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].destinationURL.lastPathComponent, "Project Files")
    }

    func testHandlesEntryNamesContainingSpaces() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("spaced", to: root.appending(path: "deck/my  slide deck.key"))
        try zip(["deck"], in: root, to: root.appending(path: "deck.zip"))

        let found = await scan(root)
        XCTAssertEqual(found.count, 1, "A filename with repeated spaces must still be matched")
        XCTAssertEqual(found[0].entryCount, 1)
    }

    func testPartialExtractionIsNeverReported() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try write("world!", to: root.appending(path: "report/sub/c.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))
        try FileManager.default.removeItem(at: root.appending(path: "report/sub/c.txt"))

        let found = await scan(root)
        XCTAssertTrue(found.isEmpty, "One missing entry must disqualify the whole archive")
    }

    func testChangedFileSizeIsNeverReported() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))
        try write("hello, this file was edited after extraction", to: root.appending(path: "report/a.txt"))

        let found = await scan(root)
        XCTAssertTrue(found.isEmpty, "An edited file means the archive is no longer redundant")
    }

    func testArchiveWithNoMatchingFolderIsNotReported() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        try write("packed", to: staging.appending(path: "still-packed/a.txt"))
        try zip(["still-packed"], in: staging, to: root.appending(path: "still-packed.zip"))
        try FileManager.default.removeItem(at: staging)

        let found = await scan(root)
        XCTAssertTrue(found.isEmpty)
    }

    func testMacOSMetadataEntriesAreIgnored() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try write("junk", to: root.appending(path: "report/.DS_Store"))
        try write("junk", to: root.appending(path: "report/__MACOSX/._a.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))
        // Extraction discards this bookkeeping, so it must not block a match.
        try FileManager.default.removeItem(at: root.appending(path: "report/.DS_Store"))
        try FileManager.default.removeItem(at: root.appending(path: "report/__MACOSX"))

        let found = await scan(root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].entryCount, 1, "Only the real file should be counted")
    }

    func testPathTraversalEntriesAreRejected() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try makeArchiveWithRawEntries(
            at: root.appending(path: "report.zip"),
            entries: ["report/a.txt": "hello", "../escape.txt": "nope"]
        )

        let found = await scan(root)
        XCTAssertTrue(found.isEmpty, "An entry escaping the destination must void the archive")
    }

    func testArchiveFiledIntoAManagedFolderIsMatchedAgainstDownloads() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))

        // Simulate the organizer having filed the archive away.
        let archives = root.appending(path: "Archives", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: archives.appending(path: ".filemorrow-managed"))
        try FileManager.default.moveItem(
            at: root.appending(path: "report.zip"),
            to: archives.appending(path: "report.zip")
        )

        let found = await scan(root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].archiveURL.deletingLastPathComponent().lastPathComponent, "Archives")
        XCTAssertEqual(
            found[0].destinationURL.resolvingSymlinksInPath(),
            root.appending(path: "report", directoryHint: .isDirectory).resolvingSymlinksInPath()
        )
    }

    func testTrashRemovesOnlyTheArchive() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))

        let scanner = ExtractedArchiveScanner()
        let found = await scanner.scan(root: root, profile: TestProfiles.general)
        XCTAssertEqual(found.count, 1)

        let trashed = TrashRecorder()
        let didTrash = try await scanner.trash(found[0]) { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }

        XCTAssertTrue(didTrash)
        XCTAssertEqual(trashed.urls.map(\.lastPathComponent), ["report.zip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "report.zip").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appending(path: "report/a.txt").path),
            "The unpacked folder must be left completely untouched"
        )
    }

    func testTrashRefusesWhenTheExtractedCopyDisappearedAfterTheScan() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))

        let scanner = ExtractedArchiveScanner()
        let found = await scanner.scan(root: root, profile: TestProfiles.general)
        XCTAssertEqual(found.count, 1)

        // The user deletes the unpacked folder between scanning and confirming.
        try FileManager.default.removeItem(at: root.appending(path: "report"))

        let trashed = TrashRecorder()
        do {
            _ = try await scanner.trash(found[0]) { trashed.append($0) }
            XCTFail("Trashing the only remaining copy must throw")
        } catch {
            XCTAssertTrue(error is ExtractedArchiveError)
        }
        XCTAssertTrue(trashed.urls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "report.zip").path))
    }

    func testScanReportsProgressAndCompletes() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }

        try write("hello", to: root.appending(path: "report/a.txt"))
        try zip(["report"], in: root, to: root.appending(path: "report.zip"))

        actor Updates {
            var values: [ExtractedArchiveScanProgress] = []
            func append(_ update: ExtractedArchiveScanProgress) { values.append(update) }
        }
        let updates = Updates()
        _ = await ExtractedArchiveScanner().scan(root: root, profile: TestProfiles.general) { update in
            await updates.append(update)
        }

        let values = await updates.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last?.completedArchives, values.last?.totalArchives)
        XCTAssertEqual(values.last?.fraction, 1)
    }

    func testEmptyDownloadsProducesNoResults() async throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let found = await scan(root)
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Helpers

    private func scan(_ root: URL) async -> [ExtractedArchive] {
        await ExtractedArchiveScanner().scan(root: root, profile: TestProfiles.general)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func zip(_ paths: [String], in workingDirectory: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", "-X"] + [archive.path] + paths
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip failed for \(archive.lastPathComponent)")
    }

    /// Builds an archive with entry names the `zip` tool refuses to produce,
    /// so the traversal guard can be exercised.
    private func makeArchiveWithRawEntries(at archive: URL, entries: [String: String]) throws {
        let script = """
        import sys, zipfile
        target = sys.argv[1]
        with zipfile.ZipFile(target, "w") as handle:
            for pair in sys.argv[2:]:
                name, _, body = pair.partition("=")
                handle.writestr(name, body)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, archive.path] + entries.map { "\($0.key)=\($0.value)" }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// The scanner calls its trash hook serially from inside the actor, so plain
/// reference storage is enough to record what it asked for.
private final class TrashRecorder: @unchecked Sendable {
    private(set) var urls: [URL] = []

    func append(_ url: URL) { urls.append(url) }
}
