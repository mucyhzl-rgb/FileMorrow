import Foundation
import XCTest
@testable import FileMorrow

final class DownloadsFoldersTests: XCTestCase {
    func testOnlyManagedFoldersAreScanned() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let managed = root.appending(path: "Archives", directoryHint: .isDirectory)
        let userFolder = root.appending(path: "My Private Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: managed.appending(path: ".filemorrow-managed"))

        let roots = DownloadsFolders.managedScanRoots(root: root, profile: TestProfiles.general)

        XCTAssertTrue(roots.contains(root))
        XCTAssertTrue(roots.contains { $0.lastPathComponent == "Archives" })
        XCTAssertFalse(
            roots.contains { $0.lastPathComponent == "My Private Folder" },
            "A folder the user created must never be enumerated"
        )
    }

    func testLegacyManagedMarkerIsStillHonoured() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let managed = root.appending(path: "Archives", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: managed.appending(path: ".downloads-butler-managed"))

        let roots = DownloadsFolders.managedScanRoots(root: root, profile: TestProfiles.general)
        XCTAssertTrue(roots.contains { $0.lastPathComponent == "Archives" })
    }

    func testFilesAreFilteredByExtensionAndOrderedStably() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appending(path: "beta.zip"))
        try Data("b".utf8).write(to: root.appending(path: "alpha.ZIP"))
        try Data("c".utf8).write(to: root.appending(path: "notes.txt"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "folder.zip", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let files = DownloadsFolders.files(in: [root], extensions: ["zip"])

        XCTAssertEqual(files.map(\.lastPathComponent), ["alpha.ZIP", "beta.zip"])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
