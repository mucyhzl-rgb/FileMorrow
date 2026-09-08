import Foundation
import XCTest
@testable import FileMorrow

final class ProfileStoreTests: XCTestCase {
    func testDeletedBuiltInCategoryStaysDeleted() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var profile = await harness.store.load()
        XCTAssertTrue(profile.categories.contains { $0.id == "Design" })

        profile.categories.removeAll { $0.id == "Design" }
        try await harness.store.save(profile)

        let reloaded = await Harness.freshStore(harness).load()
        XCTAssertFalse(
            reloaded.categories.contains { $0.id == "Design" },
            "A category the user deleted must not be reinstated by the merge"
        )
    }

    func testRemovedExtensionIsNotResurrected() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var profile = await harness.store.load()
        let index = try XCTUnwrap(profile.categories.firstIndex { $0.id == "Documents" })
        XCTAssertTrue(profile.categories[index].extensions.contains("pdf"))

        profile.categories[index].extensions.removeAll { $0 == "pdf" }
        try await harness.store.save(profile)

        let reloaded = await Harness.freshStore(harness).load()
        let documents = try XCTUnwrap(reloaded.categories.first { $0.id == "Documents" })
        XCTAssertFalse(
            documents.extensions.contains("pdf"),
            "Teaching a format to another category must survive the next launch"
        )
    }

    func testReAddingARemovedEntryClearsTheTombstone() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var profile = await harness.store.load()
        var index = try XCTUnwrap(profile.categories.firstIndex { $0.id == "Documents" })
        profile.categories[index].extensions.removeAll { $0 == "pdf" }
        try await harness.store.save(profile)

        profile = await Harness.freshStore(harness).load()
        index = try XCTUnwrap(profile.categories.firstIndex { $0.id == "Documents" })
        profile.categories[index].extensions.append("pdf")
        try await harness.store.save(profile)

        let reloaded = await Harness.freshStore(harness).load()
        let documents = try XCTUnwrap(reloaded.categories.first { $0.id == "Documents" })
        XCTAssertEqual(documents.extensions.filter { $0 == "pdf" }.count, 1)
        XCTAssertFalse(documents.suppressedBuiltIns?.contains("extensions:pdf") ?? false)
    }

    func testTombstonesAreScopedToTheFieldTheyWereRemovedFrom() async throws {
        let harness = try Harness(bundled: Harness.profile(
            extensions: ["invoice"],
            filenameKeywords: ["invoice"]
        ))
        defer { harness.cleanUp() }

        var profile = await harness.store.load()
        var index = try XCTUnwrap(profile.categories.firstIndex { $0.id == "Documents" })
        profile.categories[index].filenameKeywords.removeAll { $0 == "invoice" }
        try await harness.store.save(profile)

        let reloaded = await Harness.freshStore(harness).load()
        index = try XCTUnwrap(reloaded.categories.firstIndex { $0.id == "Documents" })
        XCTAssertFalse(reloaded.categories[index].filenameKeywords.contains("invoice"))
        XCTAssertTrue(
            reloaded.categories[index].extensions.contains("invoice"),
            "Removing a keyword must not suppress an identically spelled extension"
        )
    }

    func testEnglishBuiltInDisplayNamesAreLocalizedOnReload() async throws {
        let english = OrganizationProfile(
            schemaVersion: 2,
            name: "General Downloads",
            categories: [
                .init(
                    id: "Documents",
                    name: "Documents & Books",
                    folderName: "Documents & Books",
                    icon: "doc.fill",
                    color: "gray",
                    description: "General documents, books, ebooks, notes, and subtitles without a stronger subject match.",
                    enabled: true,
                    extensions: ["pdf"],
                    filenameKeywords: [],
                    contentKeywords: [],
                    examples: [],
                    contentAware: true,
                    extensionConfidence: 60
                ),
                Harness.category(id: "Needs Review")
            ]
        )
        let chinese = OrganizationProfile(
            schemaVersion: 2,
            name: "通用下载",
            categories: [
                .init(
                    id: "Documents",
                    name: "文档与书籍",
                    folderName: "文档与书籍",
                    icon: "doc.fill",
                    color: "gray",
                    description: "没有更明确主题匹配的常规文档、书籍、电子书、笔记和字幕。",
                    enabled: true,
                    extensions: ["pdf"],
                    filenameKeywords: [],
                    contentKeywords: [],
                    examples: [],
                    contentAware: true,
                    extensionConfidence: 60
                ),
                Harness.category(id: "Needs Review")
            ]
        )
        let harness = try Harness(bundled: english)
        defer { harness.cleanUp() }

        _ = await harness.store.load()
        _ = try Harness.writeBundled(chinese, at: harness.bundledURL)

        let reloaded = await Harness.freshStore(harness).load()
        let documents = try XCTUnwrap(reloaded.categories.first { $0.id == "Documents" })
        XCTAssertEqual(documents.name, "文档与书籍")
        XCTAssertEqual(documents.folderName, "文档与书籍")
        XCTAssertTrue(documents.description.contains("文档"))
    }

    func testCustomCategoryNamesSurviveChineseMigration() async throws {
        let english = OrganizationProfile(
            schemaVersion: 2,
            name: "General Downloads",
            categories: [
                .init(
                    id: "Work",
                    name: "Client Projects",
                    folderName: "Work",
                    icon: "briefcase.fill",
                    color: "blue",
                    description: "Client work, proposals, meetings, invoices, briefs, and deliverables.",
                    enabled: true,
                    extensions: [],
                    filenameKeywords: [],
                    contentKeywords: [],
                    examples: [],
                    contentAware: true,
                    extensionConfidence: 0
                ),
                Harness.category(id: "Needs Review")
            ]
        )
        let chinese = OrganizationProfile(
            schemaVersion: 2,
            name: "通用下载",
            categories: [
                .init(
                    id: "Work",
                    name: "工作",
                    folderName: "工作",
                    icon: "briefcase.fill",
                    color: "blue",
                    description: "客户工作、方案、会议、发票、简报和交付物。",
                    enabled: true,
                    extensions: [],
                    filenameKeywords: [],
                    contentKeywords: [],
                    examples: [],
                    contentAware: true,
                    extensionConfidence: 0
                ),
                Harness.category(id: "Needs Review")
            ]
        )
        let harness = try Harness(bundled: english)
        defer { harness.cleanUp() }

        _ = await harness.store.load()
        _ = try Harness.writeBundled(chinese, at: harness.bundledURL)

        let reloaded = await Harness.freshStore(harness).load()
        let work = try XCTUnwrap(reloaded.categories.first { $0.id == "Work" })
        XCTAssertEqual(work.name, "Client Projects")
        XCTAssertEqual(work.folderName, "工作")
    }

    func testUntouchedProfileStillLearnsNewBuiltInKnowledge() async throws {
        let harness = try Harness(bundled: Harness.profile(extensions: ["pdf"]))
        defer { harness.cleanUp() }

        _ = await harness.store.load()

        // Ship an update that teaches a new format and a whole new category.
        var updated = Harness.profile(extensions: ["pdf", "epub"])
        updated.categories.insert(
            Harness.category(id: "Design", extensions: ["sketch"]),
            at: 1
        )
        let upgraded = try Harness.writeBundled(updated, at: harness.bundledURL)
        XCTAssertNotNil(upgraded)

        let reloaded = await Harness.freshStore(harness).load()
        let documents = try XCTUnwrap(reloaded.categories.first { $0.id == "Documents" })
        XCTAssertTrue(documents.extensions.contains("epub"))
        XCTAssertTrue(reloaded.categories.contains { $0.id == "Design" })
    }

    func testImportRejectsProfileWithoutNeedsReview() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var invalid = Harness.profile(extensions: ["pdf"])
        invalid.categories.removeAll { $0.id == "Needs Review" }
        let url = harness.root.appending(path: "invalid.json")
        try JSONEncoder().encode(invalid).write(to: url)

        do {
            _ = try await harness.store.importProfile(from: url)
            XCTFail("A profile without Needs Review must be rejected")
        } catch {
            XCTAssertTrue(error is ProfileError)
        }
    }

    func testExportedProfileCanBeImportedBack() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var profile = await harness.store.load()
        profile.name = "Shared Profile"
        let url = harness.root.appending(path: "exported.json")
        try await harness.store.export(profile, to: url)

        let imported = try await harness.store.importProfile(from: url)
        XCTAssertEqual(imported.name, "Shared Profile")
        XCTAssertEqual(imported.categories.count, profile.categories.count)
    }


    func testPreviousBuiltInLookIsRefreshedOnReload() async throws {
        let older = OrganizationProfile(
            schemaVersion: 2,
            name: "通用下载",
            categories: [
                .init(
                    id: "Documents",
                    name: "文档与书籍",
                    folderName: "文档与书籍",
                    icon: "doc.fill",
                    color: "gray",
                    description: "没有更明确主题匹配的常规文档、书籍、电子书、笔记和字幕。",
                    enabled: true,
                    extensions: ["pdf"],
                    filenameKeywords: [],
                    contentKeywords: [],
                    examples: [],
                    contentAware: true,
                    extensionConfidence: 60
                ),
                Harness.category(id: "Needs Review")
            ]
        )
        let harness = try Harness(bundled: older)
        defer { harness.cleanUp() }
        _ = await harness.store.load()

        let current = TestProfiles.general
        _ = try Harness.writeBundled(current, at: harness.bundledURL)
        let reloaded = await Harness.freshStore(harness).load()
        let documents = try XCTUnwrap(reloaded.categories.first { $0.id == "Documents" })
        XCTAssertEqual(documents.icon, "books.vertical.fill")
        XCTAssertEqual(documents.color, "indigo")
    }

    func testCustomCategoryLookSurvivesIconRefresh() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        var profile = await harness.store.load()
        let index = try XCTUnwrap(profile.categories.firstIndex { $0.id == "Documents" })
        profile.categories[index].icon = "star.fill"
        profile.categories[index].color = "pink"
        try await harness.store.save(profile)

        let reloaded = await Harness.freshStore(harness).load()
        let documents = try XCTUnwrap(reloaded.categories.first { $0.id == "Documents" })
        XCTAssertEqual(documents.icon, "star.fill")
        XCTAssertEqual(documents.color, "pink")
    }

    // MARK: - Harness

    private struct Harness {
        let root: URL
        let bundledURL: URL
        let store: ProfileStore

        init(bundled: OrganizationProfile? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            bundledURL = root.appending(path: "default-profile.json")
            _ = try Harness.writeBundled(bundled ?? TestProfiles.general, at: bundledURL)
            store = ProfileStore(baseURL: root, bundledProfileURL: bundledURL)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        /// A second store over the same folder, standing in for a relaunch.
        static func freshStore(_ harness: Harness) -> ProfileStore {
            ProfileStore(baseURL: harness.root, bundledProfileURL: harness.bundledURL)
        }

        @discardableResult
        static func writeBundled(_ profile: OrganizationProfile, at url: URL) throws -> URL {
            try JSONEncoder().encode(profile).write(to: url, options: .atomic)
            return url
        }

        static func category(
            id: String,
            extensions: [String] = [],
            filenameKeywords: [String] = []
        ) -> CategoryDefinition {
            .init(
                id: id,
                name: id,
                folderName: id,
                icon: "doc.fill",
                color: "gray",
                description: id,
                enabled: true,
                extensions: extensions,
                filenameKeywords: filenameKeywords,
                contentKeywords: [],
                examples: [],
                contentAware: false,
                extensionConfidence: 90
            )
        }

        static func profile(
            extensions: [String] = [],
            filenameKeywords: [String] = []
        ) -> OrganizationProfile {
            .init(
                schemaVersion: 2,
                name: "Test",
                categories: [
                    category(id: "Documents", extensions: extensions, filenameKeywords: filenameKeywords),
                    category(id: "Needs Review")
                ]
            )
        }
    }
}
