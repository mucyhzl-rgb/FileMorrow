import XCTest
@testable import FileMorrow

final class FolderBrandingServiceTests: XCTestCase {
    func testMatchingStampLeavesAnExistingIconAlone() {
        let definition = TestProfiles.general.categories.first { $0.id == "Documents" }!
        let signature = FolderBrandingService.signature(for: definition)

        XCTAssertEqual(
            FolderBrandingService.iconUpdate(
                stamp: signature,
                hasCustomIcon: true,
                signature: signature
            ),
            .unchanged
        )
    }

    func testExistingIconWithoutStampIsRecordedInsteadOfRedrawn() {
        let definition = TestProfiles.general.categories.first { $0.id == "Documents" }!
        let signature = FolderBrandingService.signature(for: definition)

        XCTAssertEqual(
            FolderBrandingService.iconUpdate(
                stamp: nil,
                hasCustomIcon: true,
                signature: signature
            ),
            .recordExisting
        )
    }

    func testMissingOrStaleIconsAreRedrawn() {
        let definition = TestProfiles.general.categories.first { $0.id == "Documents" }!
        let signature = FolderBrandingService.signature(for: definition)

        XCTAssertEqual(
            FolderBrandingService.iconUpdate(
                stamp: nil,
                hasCustomIcon: false,
                signature: signature
            ),
            .redraw
        )
        XCTAssertEqual(
            FolderBrandingService.iconUpdate(
                stamp: "old-look",
                hasCustomIcon: true,
                signature: signature
            ),
            .redraw
        )
    }
}
