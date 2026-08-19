import Foundation
import XCTest
@testable import FileMorrow

final class PersistenceStoreTests: XCTestCase {
    func testBatchSaveWritesEveryDecision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(baseURL: root)

        try await store.save(contentsOf: (0..<25).map { decision(path: "/tmp/file-\($0).pdf") })

        let saved = await store.decisions()
        XCTAssertEqual(saved.count, 25)
        XCTAssertEqual(saved["/tmp/file-7.pdf"]?.category, .documents)
    }

    func testLaterDecisionForTheSamePathWins() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(baseURL: root)

        try await store.save(decision(path: "/tmp/a.pdf", confidence: 60))
        try await store.save(decision(path: "/tmp/a.pdf", confidence: 100))

        let saved = await store.decisions()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved["/tmp/a.pdf"]?.confidence, 100)
    }

    func testHistoryIsCappedSoUndoStaysCheap() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(baseURL: root)

        for index in 0..<(PersistenceStore.historyLimit + 20) {
            try await store.append(.init(
                id: UUID(),
                createdAt: .now,
                operations: [.init(originalPath: "/tmp/\(index)", destinationPath: "/tmp/moved/\(index)")]
            ))
        }

        let history = await store.history()
        XCTAssertEqual(history.count, PersistenceStore.historyLimit)
        XCTAssertEqual(
            history.last?.operations.first?.originalPath,
            "/tmp/\(PersistenceStore.historyLimit + 19)",
            "The newest batch must survive, because that is the one undo restores"
        )
    }

    func testPruneDropsDecisionsForFilesThatAreGone() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(baseURL: root)

        try await store.save(contentsOf: [
            decision(path: "/tmp/still-here.pdf"),
            decision(path: "/tmp/deleted-months-ago.pdf")
        ])

        let removed = try await store.pruneDecisions(keeping: ["/tmp/still-here.pdf"])
        let saved = await store.decisions()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(Set(saved.keys), ["/tmp/still-here.pdf"])
    }

    func testPruneIsANoOpWhenEverythingIsStillLive() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(baseURL: root)

        try await store.save(decision(path: "/tmp/a.pdf"))
        let removed = try await store.pruneDecisions(keeping: ["/tmp/a.pdf", "/tmp/other.pdf"])

        let saved = await store.decisions()
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(saved.count, 1)
    }

    private func decision(path: String, confidence: Int = 90) -> SavedDecision {
        .init(
            path: path,
            modifiedAt: .distantPast,
            category: .documents,
            confidence: confidence,
            reason: "Test",
            source: .rule,
            modelVersion: 6
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
