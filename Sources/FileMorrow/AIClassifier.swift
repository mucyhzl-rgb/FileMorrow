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
        @Guide(description: "Zero-based index of the single best category from the numbered list", .range(0...50))
        var categoryIndex: Int

        @Guide(description: "Confidence from 0 to 100", .range(0...100))
        var confidence: Int

        @Guide(description: "One concise evidence-based reason")
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
               Purpose: \(category.description)
               Examples: \(category.examples.joined(separator: "; "))
            """
        }.joined(separator: "\n")

        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            Classify personal download files privately and conservatively.
            Choose only a zero-based category index from the supplied numbered list.
            Prefer the file's subject over its container format.
            Choose a broad category such as Documents & Books or Code & Data when
            the format is known but the subject is unclear. Use Needs Review only
            when neither the filename, extracted evidence, nor file format supports
            any category, and keep its confidence below 60. Never invent unseen content.
            """
        )
        let prompt = """
        Active organization profile:
        \(categoryGuide)

        Filename: \(filename)
        Extracted local evidence:
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
            "Apple Intelligence returned a category outside the active profile."
        case .systemTooOld:
            "Smart Content needs macOS 26. Format mode organizes everything by file type on this Mac."
        }
    }
}
