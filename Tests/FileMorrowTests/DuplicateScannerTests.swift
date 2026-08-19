import Foundation
import XCTest
@testable import FileMorrow

final class DuplicateScannerTests: XCTestCase {
    func testFindsOnlyByteIdenticalFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let duplicate = Data("same bytes".utf8)
        try duplicate.write(to: root.appending(path: "copy-a.txt"))
        try duplicate.write(to: root.appending(path: "copy-b.txt"))
        try Data("different!".utf8).write(to: root.appending(path: "different.txt"))

        let groups = await DuplicateScanner().scan(root: root)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2)
        XCTAssertEqual(groups[0].extras.count, 1)
        XCTAssertEqual(groups[0].wastedSize, Int64(duplicate.count))
    }

    func testFindsExactDuplicatesInsideDownloadedOrUserCreatedFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstFolder = root.appending(path: "Downloaded Project", directoryHint: .isDirectory)
        let secondFolder = root.appending(path: "Personal Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let duplicate = Data("nested duplicate".utf8)
        try duplicate.write(to: firstFolder.appending(path: "copy-a.txt"))
        try duplicate.write(to: secondFolder.appending(path: "copy-b.txt"))

        let groups = await DuplicateScanner().scan(root: root)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2)
        XCTAssertTrue(groups[0].files.allSatisfy { $0.deletingLastPathComponent() != root })
    }

    func testDuplicateCleanupKeepsOneAndUsesRecoverableDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let recovery = root.appending(path: "Recovery Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("identical".utf8)
        try bytes.write(to: root.appending(path: "a.txt"))
        try bytes.write(to: root.appending(path: "b.txt"))
        let scanner = DuplicateScanner()
        let groups = await scanner.scan(root: root)
        let group = try XCTUnwrap(groups.first)

        let count = try await scanner.trashExtras(in: group) { source in
            try FileManager.default.moveItem(
                at: source,
                to: recovery.appending(path: source.lastPathComponent)
            )
        }

        XCTAssertEqual(count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recovery.path).count, 1)
    }

    func testScanReportsFingerprintAndVerificationProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 7, count: 300_000)
        try bytes.write(to: root.appending(path: "first.bin"))
        try bytes.write(to: root.appending(path: "second.bin"))

        let collector = ProgressCollector()
        let groups = await DuplicateScanner().scan(root: root) { update in
            await collector.append(update)
        }
        let stages = await collector.stages

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(stages.contains(.fingerprinting))
        XCTAssertTrue(stages.contains(.verifying))
    }

    func testKeeperIsTheLeastBuriedCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = root.appending(path: "Project/vendor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("shared asset".utf8)
        // Alphabetically the nested copy sorts first, so a path-order keeper
        // would delete the original sitting at the top of Downloads.
        try bytes.write(to: root.appending(path: "zeta.txt"))
        try bytes.write(to: nested.appending(path: "alpha.txt"))

        let groups = await DuplicateScanner().scan(root: root)
        let group = try XCTUnwrap(groups.first)

        XCTAssertEqual(group.keeper.lastPathComponent, "zeta.txt")
        XCTAssertEqual(group.extras.map(\.lastPathComponent), ["alpha.txt"])
    }

    func testKeeperCanBeOverriddenByTheUser() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("either copy is fine".utf8)
        try bytes.write(to: root.appending(path: "first.txt"))
        try bytes.write(to: root.appending(path: "second.txt"))

        let groups = await DuplicateScanner().scan(root: root)
        let group = try XCTUnwrap(groups.first)
        let other = try XCTUnwrap(group.extras.first)

        let flipped = group.keeping(other)
        XCTAssertEqual(flipped.keeper, other)
        XCTAssertEqual(flipped.extras, [group.keeper])
        XCTAssertEqual(flipped.wastedSize, group.wastedSize)
    }

    func testCleanupRefusesWhenACopyChangedAfterTheScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("original bytes".utf8)
        try bytes.write(to: root.appending(path: "keep.txt"))
        try bytes.write(to: root.appending(path: "spare.txt"))

        let scanner = DuplicateScanner()
        let groups = await scanner.scan(root: root)
        let group = try XCTUnwrap(groups.first)

        // The spare is replaced between the scan and the confirmation.
        try Data("completely different bytes".utf8).write(to: root.appending(path: "spare.txt"))

        do {
            _ = try await scanner.trashExtras(in: group) { _ in
                XCTFail("Nothing should be trashed once the bytes stopped matching")
            }
            XCTFail("Cleanup must refuse a file that is no longer a duplicate")
        } catch {
            XCTAssertTrue(error is DuplicateCleanupError)
        }
    }

    func testCleanupRefusesWhenTheKeeperIsGone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("only copy soon".utf8)
        try bytes.write(to: root.appending(path: "keep.txt"))
        try bytes.write(to: root.appending(path: "spare.txt"))

        let scanner = DuplicateScanner()
        let groups = await scanner.scan(root: root)
        let group = try XCTUnwrap(groups.first)
        try FileManager.default.removeItem(at: group.keeper)

        do {
            _ = try await scanner.trashExtras(in: group) { _ in
                XCTFail("The last remaining copy must never be trashed")
            }
            XCTFail("Cleanup must refuse when the keeper vanished")
        } catch {
            XCTAssertTrue(error is DuplicateCleanupError)
        }
    }
}

private actor ProgressCollector {
    private var values: [DuplicateScanProgress] = []

    func append(_ value: DuplicateScanProgress) {
        values.append(value)
    }

    var stages: Set<DuplicateScanProgress.Stage> {
        Set(values.map(\.stage))
    }
}
