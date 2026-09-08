import Foundation
import SwiftUI

struct ArchiveCategory: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let university = Self(rawValue: "University")
    static let finance = Self(rawValue: "Finance & PSX")
    static let medical = Self(rawValue: "Medical")
    static let work = Self(rawValue: "Work")
    static let personal = Self(rawValue: "Personal")
    static let travel = Self(rawValue: "Travel & Immigration")
    static let legal = Self(rawValue: "Legal")
    static let design = Self(rawValue: "Design")
    static let documents = Self(rawValue: "Documents")
    static let images = Self(rawValue: "Images")
    static let videos = Self(rawValue: "Videos")
    static let music = Self(rawValue: "Music")
    static let installers = Self(rawValue: "Apps & Installers")
    static let archives = Self(rawValue: "Archives")
    static let codeData = Self(rawValue: "Code & Data")
    static let other = Self(rawValue: "Other")
    static let needsReview = Self(rawValue: "Needs Review")
}

struct CategoryDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var folderName: String
    var icon: String
    var color: String
    var description: String
    var enabled: Bool
    var extensions: [String]
    var filenameKeywords: [String]
    var contentKeywords: [String]
    var examples: [String]
    var contentAware: Bool
    var extensionConfidence: Int
    /// Built-in extensions, keywords, or examples the user deliberately removed.
    /// Recorded so a profile merge never resurrects them. Compared lowercased.
    var suppressedBuiltIns: [String]? = nil

    var category: ArchiveCategory { .init(rawValue: id) }

    /// English folder names from earlier builds, so already-organized files
    /// stay visible after the default profile switches to Chinese folders.
    static let englishFolderAliases: [String: String] = [
        "University": "University",
        "Finance & PSX": "Finance & Investments",
        "Medical": "Medical & Health",
        "Work": "Work",
        "Personal": "Personal",
        "Travel & Immigration": "Travel & Immigration",
        "Legal": "Legal",
        "Documents": "Documents & Books",
        "Images": "Images",
        "Videos": "Videos",
        "Music": "Music & Audio",
        "Apps & Installers": "Apps & Installers",
        "Archives": "Archives",
        "Design": "Design & Creative",
        "Code & Data": "Code & Data",
        "Spreadsheets & Data": "Spreadsheets & Data",
        "System & Diagnostics": "System & Diagnostics",
        "Projects & Plugins": "Projects & Plugins",
        "Other": "Other",
        "Needs Review": "Needs Review"
    ]

    var managedFolderNames: [String] {
        var names = [folderName]
        if let english = Self.englishFolderAliases[id], english != folderName {
            names.append(english)
        }
        return names
    }

    var swiftUIColor: Color {
        switch color.lowercased() {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        case "gray": .gray
        default: .indigo
        }
    }
}

struct OrganizationProfile: Codable, Sendable {
    var schemaVersion: Int
    var name: String
    var categories: [CategoryDefinition]
    /// Built-in categories the user deleted, so a merge never re-adds them.
    var removedBuiltInCategoryIDs: [String]? = nil

    var enabledCategories: [CategoryDefinition] {
        categories.filter(\.enabled)
    }

    func definition(for category: ArchiveCategory) -> CategoryDefinition? {
        categories.first { $0.id == category.rawValue }
    }
}

enum ClassificationMode: String, CaseIterable, Identifiable, Sendable {
    case formatOnly = "Format only"
    case smartContent = "Smart content"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .formatOnly: "按文件格式"
        case .smartContent: "智能内容"
        }
    }

    var detail: String {
        switch self {
        case .formatOnly:
            "快速且可预期。PDF 归入文档，音频归入音乐，图片归入图片，表格归入表格。"
        case .smartContent:
            "根据文件名、提取出的内容和 Apple Intelligence 选择主题文件夹。更贴合内容，但端侧模型也可能分错。"
        }
    }
}

enum AgeView: String, CaseIterable, Identifiable {
    case today = "今天"
    case yesterday = "昨天"
    case lastWeek = "最近 7 天"
    case ready = "可以归档"
    case all = "全部下载"
    case duplicates = "重复文件"
    case extracted = "已解压压缩包"
    case installers = "安装包"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today: "sun.max.fill"
        case .yesterday: "clock.arrow.circlepath"
        case .lastWeek: "calendar"
        case .ready: "sparkles.rectangle.stack"
        case .all: "tray.full.fill"
        case .duplicates: "doc.on.doc.fill"
        case .extracted: "archivebox.fill"
        case .installers: "shippingbox.fill"
        }
    }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let files: [URL]
    let fileSize: Int64
    /// Which copy survives cleanup. The scanner picks the oldest, shallowest
    /// copy; the user can point this at any other copy before trashing.
    var keeperIndex: Int = 0

    var keeper: URL { files[min(max(0, keeperIndex), files.count - 1)] }
    var extras: [URL] {
        let keeper = keeper
        return files.filter { $0 != keeper }
    }
    var wastedSize: Int64 { fileSize * Int64(extras.count) }

    func keeping(_ url: URL) -> DuplicateGroup {
        guard let index = files.firstIndex(of: url) else { return self }
        var copy = self
        copy.keeperIndex = index
        return copy
    }
}

struct DuplicateScanProgress: Sendable {
    enum Stage: String, Sendable {
        case fingerprinting = "正在比较候选文件"
        case verifying = "正在核验完全相同的副本"
    }

    let stage: Stage
    let completedFiles: Int
    let totalFiles: Int
    let processedBytes: Int64
    let totalBytes: Int64
    let currentFile: String?

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(processedBytes) / Double(totalBytes))
    }
}

struct OrganizationProposal: Identifiable, Sendable {
    let id = UUID()
    let fileCount: Int
    let totalSize: Int64
    let categoryCounts: [(name: String, count: Int)]
    let automaticCheck: Bool
}

struct FileRecord: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let dateAdded: Date
    let size: Int64
    let contentType: String
    var category: ArchiveCategory
    var confidence: Int
    var reason: String
    var source: DecisionSource
    var excerpt: String?
    let location: FileLocation

    var name: String { url.lastPathComponent }
    var isReviewed: Bool { source == .user }
    var isOrganized: Bool { location == .organized }
}

enum FileLocation: String, Hashable, Sendable {
    case loose
    case organized
}

enum DecisionSource: String, Codable, Sendable {
    case rule = "Rule"
    case localContent = "Local content"
    case appleAI = "Apple Intelligence"
    case formatFallback = "Format fallback"
    case user = "Your correction"

    var title: String {
        switch self {
        case .rule: "规则"
        case .localContent: "本地内容"
        case .appleAI: "Apple Intelligence"
        case .formatFallback: "格式回退"
        case .user: "你的更正"
        }
    }
}

struct SavedDecision: Codable, Sendable {
    let path: String
    let modifiedAt: Date
    let category: ArchiveCategory
    let confidence: Int
    let reason: String
    let source: DecisionSource
    let modelVersion: Int?
}

struct MoveOperation: Codable, Sendable {
    let originalPath: String
    let destinationPath: String
}

struct MoveBatch: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let operations: [MoveOperation]
}

struct RuleDecision: Sendable {
    let category: ArchiveCategory
    let confidence: Int
    let reason: String
}

enum ArchiveEligibility {
    static func isEligible(_ record: FileRecord, cutoffDate: Date) -> Bool {
        !record.isOrganized && record.dateAdded < cutoffDate
    }
}

/// A ZIP whose full contents were verified to already exist on disk, so the
/// archive itself is redundant and can go to recoverable Trash.
struct ExtractedArchive: Identifiable, Hashable, Sendable {
    let archiveURL: URL
    let destinationURL: URL
    let archiveSize: Int64
    let entryCount: Int
    let extractedSize: Int64

    var id: String { archiveURL.path }
    var name: String { archiveURL.lastPathComponent }
    var destinationName: String { destinationURL.lastPathComponent }
}

struct ExtractedArchiveScanProgress: Sendable {
    let completedArchives: Int
    let totalArchives: Int
    let currentArchive: String?

    var fraction: Double? {
        guard totalArchives > 0 else { return nil }
        return min(1, Double(completedArchives) / Double(totalArchives))
    }
}

/// How a downloaded installer's version relates to what is installed.
enum VersionComparison: String, Sendable {
    /// The Mac already runs a newer build, typically because the app updated
    /// itself after this installer was downloaded.
    case installedIsNewer
    case sameVersion
    /// A pending update. These are never offered for cleanup.
    case installerIsNewer
    case unknownVersion

    var summary: String {
        switch self {
        case .installedIsNewer: "本机版本已经比这个更新"
        case .sameVersion: "已安装相同版本"
        case .installerIsNewer: "比已安装的版本更新"
        case .unknownVersion: "已经安装"
        }
    }
}

/// A `.dmg` or `.pkg` in Downloads whose software is already on this Mac.
struct RedundantInstaller: Identifiable, Hashable, Sendable {
    enum Evidence: String, Sendable {
        case packageReceipt = "已通过安装回执核实"
        case installedApp = "已匹配到本机应用"
    }

    let installerURL: URL
    let installerSize: Int64
    let installerVersion: String?
    let installedName: String
    let installedLocation: String
    let installedVersion: String?
    let evidence: Evidence
    let comparison: VersionComparison

    var id: String { installerURL.path }
    var name: String { installerURL.lastPathComponent }

    var versionSummary: String {
        switch (installerVersion, installedVersion) {
        case let (installer?, installed?):
            "安装包 \(installer) • 本机 \(installed)"
        case let (nil, installed?):
            "本机 \(installed)"
        case let (installer?, nil):
            "安装包 \(installer)"
        default:
            comparison.summary
        }
    }
}

struct InstallerScanProgress: Sendable {
    let completedInstallers: Int
    let totalInstallers: Int
    let currentInstaller: String?

    var fraction: Double? {
        guard totalInstallers > 0 else { return nil }
        return min(1, Double(completedInstallers) / Double(totalInstallers))
    }
}
