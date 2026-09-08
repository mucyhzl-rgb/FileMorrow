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
            if isEnglishDisplay(result.categories[index].name, id: builtIn.id) {
                result.categories[index].name = builtIn.name
            }
            if isEnglishDisplay(result.categories[index].folderName, id: builtIn.id) {
                result.categories[index].folderName = builtIn.folderName
            }
            if result.categories[index].description == builtIn.id
                || englishDescriptions[builtIn.id] == result.categories[index].description {
                result.categories[index].description = builtIn.description
            }
            if shouldRefreshLook(result.categories[index], from: builtIn) {
                result.categories[index].icon = builtIn.icon
                result.categories[index].color = builtIn.color
            }
        }
        return result
    }

    /// Existing installs keep English names until this merge. Only rewrite
    /// a field when the user has not customized it.
    private func isEnglishDisplay(_ value: String, id: String) -> Bool {
        value == id || value == CategoryDefinition.englishFolderAliases[id]
    }

    /// Refresh shipped icons and colors, but leave a restyled category alone.
    private func shouldRefreshLook(_ personal: CategoryDefinition, from builtIn: CategoryDefinition) -> Bool {
        guard personal.icon != builtIn.icon || personal.color != builtIn.color else { return false }
        return CategoryDefinition.legacyLooks[builtIn.id]?.contains {
            $0.icon == personal.icon && $0.color == personal.color
        } == true
    }

    private var englishDescriptions: [String: String] {
        [
            "University": "Courses, lectures, assignments, research, exams, and academic material.",
            "Finance & PSX": "Banking, investments, stock markets, taxes, statements, and company reports.",
            "Medical": "Clinical, patient, hospital, health, lab, and medical professional material.",
            "Work": "Client work, proposals, meetings, invoices, briefs, and deliverables.",
            "Personal": "Personal applications, CVs, letters, and identity-related documents.",
            "Travel & Immigration": "Flights, hotels, visas, passports, permits, and itineraries.",
            "Legal": "Contracts, affidavits, ordinances, notices, and formal legal material.",
            "Documents": "General documents, books, ebooks, notes, and subtitles without a stronger subject match.",
            "Images": "Photos, screenshots, and raster images.",
            "Videos": "Movies, screen recordings, and video clips.",
            "Music": "Music, voice notes, podcasts, and audio recordings.",
            "Apps & Installers": "Application installers and executable packages for any platform.",
            "Archives": "Compressed archives whose contents do not indicate a stronger subject.",
            "Design": "Design source files, vectors, layouts, mockups, and brand assets.",
            "Code & Data": "Source code, websites, environments, databases, notebooks, and structured data.",
            "Spreadsheets & Data": "Generic spreadsheets and tabular data without a stronger subject match.",
            "System & Diagnostics": "Crash reports, logs, system profiles, diagnostic files, and configuration profiles.",
            "Projects & Plugins": "Portable project bundles, creative coding projects, and application plugins.",
            "Other": "Files with an unsupported or missing extension when using format-only organization.",
            "Needs Review": "Fallback for files that remain genuinely ambiguous after analysis."
        ]
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
        name: "精简",
        categories: [
            .init(
                id: ArchiveCategory.documents.rawValue,
                name: "文档",
                folderName: "文档",
                icon: "books.vertical.fill",
                color: "indigo",
                description: "常规文档",
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
                name: "其他",
                folderName: "其他",
                icon: "tray.full.fill",
                color: "gray",
                description: "不支持或没有扩展名的文件",
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
                name: "待审核",
                folderName: "待审核",
                icon: "questionmark.folder.fill",
                color: "gray",
                description: "无法确定归类的文件",
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
        "所选文件不是有效的 FileMorrow 配置。"
    }
}
