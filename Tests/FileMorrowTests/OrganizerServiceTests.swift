import Foundation
import XCTest
@testable import FileMorrow

final class OrganizerServiceTests: XCTestCase {
    func testMarkerCollisionAndUndoAreSafe() async throws {
        let root = temporaryDirectory()
        let state = root.appending(path: "State", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "photo.jpg")
        try Data("new".utf8).write(to: source)
        let images = root.appending(path: "Images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: images.appending(path: "photo.jpg"))

        let store = PersistenceStore(baseURL: state)
        let organizer = OrganizerService(store: store)
        let moved = try await organizer.organize(
            [record(url: source)],
            downloadsURL: root,
            minimumConfidence: 85,
            profile: TestProfiles.general
        )

        XCTAssertEqual(moved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.appending(path: ".filemorrow-managed").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.appending(path: "photo 2.jpg").path))
        XCTAssertEqual(try Data(contentsOf: images.appending(path: "photo.jpg")), Data("existing".utf8))

        let undone = try await organizer.undoLast()
        XCTAssertEqual(undone, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appending(path: "photo 2.jpg").path))
    }

    func testOneUnmovableFileDoesNotStrandTheRest() async throws {
        let root = temporaryDirectory()
        let state = root.appending(path: "State", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A plain file where the Images folder needs to go, so creating that
        // destination fails for the first record only.
        try Data("blocker".utf8).write(to: root.appending(path: "Images"))

        let blocked = root.appending(path: "photo.jpg")
        let movable = root.appending(path: "notes.pdf")
        try Data("jpg".utf8).write(to: blocked)
        try Data("pdf".utf8).write(to: movable)

        let organizer = OrganizerService(store: PersistenceStore(baseURL: state))
        let moved = try await organizer.organize(
            [record(url: blocked), record(url: movable, category: .documents)],
            downloadsURL: root,
            minimumConfidence: 85,
            profile: TestProfiles.general
        )

        let skipped = await organizer.skippedCount
        XCTAssertEqual(moved, 1, "The healthy file must still be organized")
        XCTAssertEqual(skipped, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path), "The failed file stays put")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "Documents & Books/notes.pdf").path
        ))

        let undone = try await organizer.undoLast()
        XCTAssertEqual(undone, 1, "A partial run must still be undoable")
    }

    func testFailureWithNothingMovedIsReported() async throws {
        let root = temporaryDirectory()
        let state = root.appending(path: "State", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("blocker".utf8).write(to: root.appending(path: "Images"))
        let blocked = root.appending(path: "photo.jpg")
        try Data("jpg".utf8).write(to: blocked)

        let organizer = OrganizerService(store: PersistenceStore(baseURL: state))
        do {
            _ = try await organizer.organize(
                [record(url: blocked)],
                downloadsURL: root,
                minimumConfidence: 85,
                profile: TestProfiles.general
            )
            XCTFail("A run that moved nothing must surface the error")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        }
    }

    func testFilesBelowTheConfidenceGateAreLeftAlone() async throws {
        let root = temporaryDirectory()
        let state = root.appending(path: "State", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let uncertain = root.appending(path: "mystery.jpg")
        try Data("jpg".utf8).write(to: uncertain)

        let organizer = OrganizerService(store: PersistenceStore(baseURL: state))
        let moved = try await organizer.organize(
            [record(url: uncertain, confidence: 40)],
            downloadsURL: root,
            minimumConfidence: 85,
            profile: TestProfiles.general
        )

        XCTAssertEqual(moved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: uncertain.path))
    }

    private func record(
        url: URL,
        category: ArchiveCategory = .images,
        confidence: Int = 100
    ) -> FileRecord {
        FileRecord(
            url: url,
            dateAdded: .distantPast,
            size: 3,
            contentType: "public.jpeg",
            category: category,
            confidence: confidence,
            reason: "Known image format",
            source: .rule,
            excerpt: nil,
            location: .loose
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
