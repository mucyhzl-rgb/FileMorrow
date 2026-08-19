import Foundation

actor ProfileStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let profileURL: URL
    private let bundledProfileURL: URL?

    init(baseURL: URL? = nil, bundledProfileURL: URL? = nil) {
        let base = baseURL ?? AppSupportPaths.directory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        profileURL = base.appending(path: "organization-profile.json")
        self.bundledProfileURL = bundledProfileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load() -> OrganizationProfile {
        let bundled = bundledProfile()
        if let data = try? Data(contentsOf: profileURL),
           let profile = try? decoder.decode(OrganizationProfile.self, from: data) {
            guard let bundled else { return profile }
            let migrated = mergeBuiltInKnowledge(into: profile, from: bundled)
            try? save(migrated)
            return migrated
        }
        if let bundled {
            try? save(bundled)
            return bundled
        }
        return Self.fallback
    }

    private func bundledProfile() -> OrganizationProfile? {
        let url = bundledProfileURL
            ?? Bundle.main.url(forResource: "default-profile", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OrganizationProfile.self, from: data)
    }

    /// Keeps personal names, folders, colors and enabled choices while teaching
    /// an existing profile about newly supported formats and built-in signals.
    private func mergeBuiltInKnowledge(
        into personal: OrganizationProfile,
        from bundled: OrganizationProfile
    ) -> OrganizationProfile {
        var result = personal
        result.schemaVersion = max(personal.schemaVersion, bundled.schemaVersion)
        let removedCategoryIDs = Set(personal.removedBuiltInCategoryIDs ?? [])

        for builtIn in bundled.categories {
            guard let index = result.categories.firstIndex(where: { $0.id == builtIn.id }) else {
                guard !removedCategoryIDs.contains(builtIn.id) else { continue }
                let insertion = result.categories.firstIndex { $0.category == .needsReview }
                    ?? result.categories.endIndex
                result.categories.insert(builtIn, at: insertion)
                continue
            }
            let suppressed = Set(result.categories[index].suppressedBuiltIns ?? [])
            result.categories[index].extensions = merged(
                result.categories[index].extensions,
                builtIn.extensions,
                field: .extensions,
                suppressing: suppressed
            )
            result.categories[index].filenameKeywords = merged(
                result.categories[index].filenameKeywords,
                builtIn.filenameKeywords,
                field: .filenameKeywords,
                suppressing: suppressed
            )
            result.categories[index].contentKeywords = merged(
                result.categories[index].contentKeywords,
                builtIn.contentKeywords,
                field: .contentKeywords,
                suppressing: suppressed
            )
            result.categories[index].examples = merged(
                result.categories[index].examples,
                builtIn.examples,
                field: .examples,
                suppressing: suppressed
            )
        }
        return result
    }

    private func merged(
        _ personal: [String],
        _ builtIn: [String],
        field: ProfileField,
        suppressing suppressed: Set<String>
    ) -> [String] {
        personal + builtIn.filter { candidate in
            !suppressed.contains(field.key(candidate))
                && !personal.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
    }

    /// Namespaces a tombstone so removing a keyword never suppresses an
    /// identically spelled extension or example in the same category.
    private enum ProfileField: String, CaseIterable {
        case extensions, filenameKeywords, contentKeywords, examples

        func key(_ value: String) -> String { "\(rawValue):\(value.lowercased())" }

        func values(of category: CategoryDefinition) -> [String] {
            switch self {
            case .extensions: category.extensions
            case .filenameKeywords: category.filenameKeywords
            case .contentKeywords: category.contentKeywords
            case .examples: category.examples
            }
        }
    }

    /// Records what the user removed relative to the bundled profile, so the
    /// next merge treats the absence as a decision instead of a gap to fill.
    /// Anything they add back is un-suppressed by the same pass.
    private func recordingRemovals(in profile: OrganizationProfile) -> OrganizationProfile {
        guard let bundled = bundledProfile() else { return profile }
        var result = profile

        let presentIDs = Set(profile.categories.map(\.id))
        var removedIDs = Set(profile.removedBuiltInCategoryIDs ?? [])
        removedIDs.formUnion(bundled.categories.map(\.id).filter { !presentIDs.contains($0) })
        removedIDs.subtract(presentIDs)
        result.removedBuiltInCategoryIDs = removedIDs.isEmpty ? nil : removedIDs.sorted()

        for index in result.categories.indices {
            let category = result.categories[index]
            guard let builtIn = bundled.categories.first(where: { $0.id == category.id }) else {
                continue
            }
            let present = Set(tombstoneKeys(of: category))
            var suppressed = Set(category.suppressedBuiltIns ?? [])
            suppressed.formUnion(tombstoneKeys(of: builtIn))
            suppressed.subtract(present)
            result.categories[index].suppressedBuiltIns = suppressed.isEmpty ? nil : suppressed.sorted()
        }
        return result
    }

    private func tombstoneKeys(of category: CategoryDefinition) -> [String] {
        ProfileField.allCases.flatMap { field in
            field.values(of: category).map(field.key)
        }
    }

    func save(_ profile: OrganizationProfile) throws {
        try encoder.encode(recordingRemovals(in: profile)).write(to: profileURL, options: .atomic)
    }

    func export(_ profile: OrganizationProfile, to url: URL) throws {
        try encoder.encode(profile).write(to: url, options: .atomic)
    }

    func importProfile(from url: URL) throws -> OrganizationProfile {
        let data = try Data(contentsOf: url)
        let profile = try decoder.decode(OrganizationProfile.self, from: data)
        guard !profile.categories.isEmpty,
              profile.categories.contains(where: { $0.id == ArchiveCategory.needsReview.rawValue }) else {
            throw ProfileError.invalidProfile
        }
        try save(profile)
        return profile
    }

    static let fallback = OrganizationProfile(
        schemaVersion: 2,
        name: "Minimal",
        categories: [
            .init(
                id: ArchiveCategory.documents.rawValue,
                name: "Documents",
                folderName: "Documents",
                icon: "doc.fill",
                color: "gray",
                description: "General documents",
                enabled: true,
                extensions: ["pdf", "doc", "docx", "ppt", "pptx", "key", "txt"],
                filenameKeywords: [],
                contentKeywords: [],
                examples: [],
                contentAware: true,
                extensionConfidence: 60
            ),
            .init(
                id: ArchiveCategory.other.rawValue,
                name: "Other",
                folderName: "Other",
                icon: "square.grid.2x2.fill",
                color: "gray",
                description: "Unsupported or extensionless files",
                enabled: true,
                extensions: [],
                filenameKeywords: [],
                contentKeywords: [],
                examples: [],
                contentAware: false,
                extensionConfidence: 100
            ),
            .init(
                id: ArchiveCategory.needsReview.rawValue,
                name: "Needs Review",
                folderName: "Needs Review",
                icon: "questionmark.folder.fill",
                color: "gray",
                description: "Ambiguous files",
                enabled: true,
                extensions: [],
                filenameKeywords: [],
                contentKeywords: [],
                examples: [],
                contentAware: true,
                extensionConfidence: 0
            )
        ]
    )
}

enum ProfileError: LocalizedError {
    case invalidProfile

    var errorDescription: String? {
        "The selected file is not a valid FileMorrow profile."
    }
}
