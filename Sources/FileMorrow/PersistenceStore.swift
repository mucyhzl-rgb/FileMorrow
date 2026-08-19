import Foundation

actor PersistenceStore {
    /// Undo only ever reaches the most recent batch, so older batches are
    /// history for its own sake. Capping keeps the file small on installs that
    /// have been organizing hourly for months.
    static let historyLimit = 50

    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let decisionsURL: URL
    private let movesURL: URL

    init(baseURL: URL? = nil) {
        let base = baseURL ?? AppSupportPaths.directory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        decisionsURL = base.appending(path: "decisions.json")
        movesURL = base.appending(path: "move-history.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func decisions() -> [String: SavedDecision] {
        guard let data = try? Data(contentsOf: decisionsURL) else { return [:] }
        return (try? decoder.decode([String: SavedDecision].self, from: data)) ?? [:]
    }

    func save(_ decision: SavedDecision) throws {
        try save(contentsOf: [decision])
    }

    /// Writes a whole run in one pass. Saving decisions one at a time re-encoded
    /// the entire file per decision, which is quadratic across a long analysis.
    func save(contentsOf newDecisions: [SavedDecision]) throws {
        guard !newDecisions.isEmpty else { return }
        var all = decisions()
        for decision in newDecisions { all[decision.path] = decision }
        try encoder.encode(all).write(to: decisionsURL, options: .atomic)
    }

    /// Drops decisions whose file no longer exists at that path. Without this
    /// the file grows for the lifetime of the install.
    @discardableResult
    func pruneDecisions(keeping livePaths: Set<String>) throws -> Int {
        let all = decisions()
        let kept = all.filter { livePaths.contains($0.key) }
        guard kept.count != all.count else { return 0 }
        try encoder.encode(kept).write(to: decisionsURL, options: .atomic)
        return all.count - kept.count
    }

    func history() -> [MoveBatch] {
        guard let data = try? Data(contentsOf: movesURL) else { return [] }
        return (try? decoder.decode([MoveBatch].self, from: data)) ?? []
    }

    func append(_ batch: MoveBatch) throws {
        var all = history()
        all.append(batch)
        if all.count > Self.historyLimit {
            all.removeFirst(all.count - Self.historyLimit)
        }
        try encoder.encode(all).write(to: movesURL, options: .atomic)
    }

    func replaceLastBatch(with batch: MoveBatch?) throws {
        var all = history()
        guard !all.isEmpty else { return }
        all.removeLast()
        if let batch { all.append(batch) }
        try encoder.encode(all).write(to: movesURL, options: .atomic)
    }
}
