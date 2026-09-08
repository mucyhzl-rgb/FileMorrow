import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The classifier's answer, independent of which system produced it, so
/// callers never need availability annotations of their own.
struct AIClassification: Sendable {
    var categoryIndex: Int
    var confidence: Int
    var reason: String
}

/// Wraps Apple's on-device model where it exists. On systems without
/// Foundation Models the rest of the app is unaffected: Format mode, local
/// evidence scoring, teaching, and every cleanup workflow are unchanged.
actor AIClassifier {
    var availability: IntelligenceAvailabilityState {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return IntelligenceAvailabilityState(SystemLanguageModel.default.availability)
        }
        #endif
        return .systemTooOld
    }

    func classify(
        filename: String,
        excerpt: String,
        categories: [CategoryDefinition]
    ) async throws -> (AIClassification, CategoryDefinition) {
        let usable = Array(categories.prefix(51))
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let result = try await FoundationModelClassifier.classify(
                filename: filename,
                excerpt: excerpt,
                categories: usable
            )
            guard usable.indices.contains(result.categoryIndex) else {
                throw AIClassificationError.invalidCategoryIndex
            }
            return (result, usable[result.categoryIndex])
        }
        #endif
        throw AIClassificationError.systemTooOld
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private enum FoundationModelClassifier {
    @Generable
    struct Response {
        @Guide(description: "编号列表中最佳分类的从零开始的索引", .range(0...50))
        var categoryIndex: Int

        @Guide(description: "置信度，范围 0 到 100", .range(0...100))
        var confidence: Int

        @Guide(description: "一句基于证据的简短中文理由")
        var reason: String
    }

    static func classify(
        filename: String,
        excerpt: String,
        categories: [CategoryDefinition]
    ) async throws -> AIClassification {
        let categoryGuide = categories.enumerated().map { index, category in
            """
            \(index). \(category.name)
               用途：\(category.description)
               示例：\(category.examples.joined(separator: "；"))
            """
        }.joined(separator: "\n")

        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            请私密、保守地分类个人下载文件。
            只能从提供的编号列表中选择一个从零开始的分类索引。
            优先看文件主题，而不是容器格式。
            当格式已知但主题不清楚时，选择较宽的分类，例如「文档与书籍」或「代码与数据」。
            只有在文件名、提取证据和文件格式都无法支持任何分类时，才使用「待审核」，
            并将其置信度保持在 60 以下。不要编造未见过的内容。
            理由请用简体中文撰写。
            """
        )
        let prompt = """
        当前整理配置：
        \(categoryGuide)

        文件名：\(filename)
        本机提取的证据：
        \(excerpt)
        """
        let response = try await session.respond(to: prompt, generating: Response.self).content
        return AIClassification(
            categoryIndex: response.categoryIndex,
            confidence: response.confidence,
            reason: response.reason
        )
    }
}
#endif

enum AIClassificationError: LocalizedError {
    case invalidCategoryIndex
    case systemTooOld

    var errorDescription: String? {
        switch self {
        case .invalidCategoryIndex:
            "Apple Intelligence 返回的分类不在当前配置中。"
        case .systemTooOld:
            "智能内容需要 macOS 26。这台 Mac 上的格式模式会按文件类型整理。"
        }
    }
}
