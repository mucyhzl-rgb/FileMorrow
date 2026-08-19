import Foundation
import XCTest
@testable import FileMorrow

final class FileScannerTests: XCTestCase {
    func testLivePathsCoverBothTheOrganizedAndTopLevelLocation() {
        let downloads = URL(fileURLWithPath: "/Users/test/Downloads")
        let organized = downloads.appending(path: "Documents & Books/thesis.pdf")
        let loose = downloads.appending(path: "receipt.pdf")

        let paths = FileScanner.livePaths(
            for: [record(url: organized, location: .organized), record(url: loose, location: .loose)],
            downloadsURL: downloads
        )

        XCTAssertTrue(paths.contains(organized.path))
        XCTAssertTrue(
            paths.contains(downloads.appending(path: "thesis.pdf").path),
            "Undo restores organized files to the top level, so that key must be kept too"
        )
        XCTAssertTrue(paths.contains(loose.path))
    }

    func testLivePathsAreEmptyForAnEmptyScan() {
        XCTAssertTrue(
            FileScanner.livePaths(for: [], downloadsURL: URL(fileURLWithPath: "/Users/test/Downloads")).isEmpty
        )
    }

    private func record(url: URL, location: FileLocation) -> FileRecord {
        FileRecord(
            url: url,
            dateAdded: .distantPast,
            size: 10,
            contentType: "com.adobe.pdf",
            category: .documents,
            confidence: 100,
            reason: "Known Documents format",
            source: .rule,
            excerpt: nil,
            location: location
        )
    }
}
