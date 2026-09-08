import XCTest
@testable import FileMorrow

final class CategoryLookTests: XCTestCase {
    func testBuiltInLooksUseTheShippedSidebarIcons() {
        let documents = TestProfiles.general.categories.first { $0.id == "Documents" }!
        XCTAssertEqual(documents.displayIcon, "books.vertical.fill")
        XCTAssertEqual(documents.displayColorName, "indigo")

        let archives = TestProfiles.general.categories.first { $0.id == "Archives" }!
        XCTAssertEqual(archives.displayIcon, "archivebox.fill")
        XCTAssertEqual(archives.displayColorName, "orange")
    }

    func testOlderStoredLooksStillDisplayTheCurrentBuiltInIcon() {
        var documents = TestProfiles.general.categories.first { $0.id == "Documents" }!
        documents.icon = "doc.fill"
        documents.color = "gray"

        XCTAssertEqual(documents.displayIcon, "books.vertical.fill")
        XCTAssertEqual(documents.displayColorName, "indigo")
    }

    func testCustomLookWinsOverTheShippedIcon() {
        var documents = TestProfiles.general.categories.first { $0.id == "Documents" }!
        documents.icon = "star.fill"
        documents.color = "pink"

        XCTAssertEqual(documents.displayIcon, "star.fill")
        XCTAssertEqual(documents.displayColorName, "pink")
    }
}
