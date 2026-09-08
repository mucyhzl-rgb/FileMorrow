import Foundation
import UniformTypeIdentifiers

enum RuleClassifier {
    static func classify(
        url: URL,
        type: UTType?,
        profile: OrganizationProfile,
        mode: ClassificationMode = .smartContent
    ) -> RuleDecision {
        let ext = normalizedExtension(url)
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let enabled = profile.enabledCategories

        if mode == .smartContent {
            let semanticMatches = enabled.compactMap { definition -> (CategoryDefinition, Int)? in
                let matches = definition.filenameKeywords.filter { name.contains($0.lowercased()) }
                guard !matches.isEmpty else { return nil }
                return (definition, matches.reduce(0) { $0 + ($1.contains(" ") ? 3 : 2) })
            }
            .sorted { $0.1 > $1.1 }

            if let winner = semanticMatches.first {
                return .init(
                    category: winner.0.category,
                    confidence: min(96, 86 + winner.1),
                    reason: "文件名匹配「\(winner.0.name)」"
                )
            }
        }

        if let definition = enabled.first(where: {
            $0.extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.contains(ext)
        }) {
            return .init(
                category: definition.category,
                confidence: mode == .formatOnly ? 100 : definition.extensionConfidence,
                reason: mode == .formatOnly
                    ? "按 .\(ext) 文件格式归类"
                    : definition.contentAware
                    ? "\(ext.uppercased()) 格式；内容分析可以进一步判断主题"
                    : "已知的「\(definition.name)」格式"
            )
        }

        if type?.conforms(to: .image) == true,
           let definition = enabled.first(where: { $0.id == ArchiveCategory.images.rawValue }) {
            return .init(category: definition.category, confidence: 100, reason: "图片文件")
        }
        if type?.conforms(to: .movie) == true,
           let definition = enabled.first(where: { $0.id == ArchiveCategory.videos.rawValue }) {
            return .init(category: definition.category, confidence: 100, reason: "视频文件")
        }
        if type?.conforms(to: .audio) == true,
           let definition = enabled.first(where: { $0.id == ArchiveCategory.music.rawValue }) {
            return .init(category: definition.category, confidence: 100, reason: "音频文件")
        }

        if mode == .formatOnly,
           let other = enabled.first(where: { $0.category == .other }) {
            return .init(
                category: other.category,
                confidence: 100,
                reason: ext.isEmpty
                    ? "没有扩展名，已放入其他"
                    : "不支持的 .\(ext) 格式，已放入其他"
            )
        }

        return .init(category: .needsReview, confidence: 20, reason: "未知格式，需要分析")
    }

    static func normalizedExtension(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".sqlite-wal") { return "sqlite-wal" }
        if name.hasPrefix("."), !name.dropFirst().contains(".") { return String(name.dropFirst()) }
        return url.pathExtension.lowercased()
    }
}
