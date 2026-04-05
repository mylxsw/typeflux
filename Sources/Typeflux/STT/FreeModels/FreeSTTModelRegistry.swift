import Foundation

struct FreeSTTResolvedModel: Equatable {
    let sourceID: String
    let sourceName: String
    let baseURL: String
    let modelName: String
    let apiKey: String
    let additionalHeaders: [String: String]
}

protocol FreeSTTModelSource {
    var id: String { get }
    var displayName: String { get }
    var baseURL: String { get }
    var apiKey: String { get }
    var additionalHeaders: [String: String] { get }
    var supportedModels: [String] { get }

    func resolve(modelName: String) -> FreeSTTResolvedModel?
}

extension FreeSTTModelSource {
    var apiKey: String {
        ""
    }

    var additionalHeaders: [String: String] {
        [:]
    }

    func resolve(modelName: String) -> FreeSTTResolvedModel? {
        let normalizedInput = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else { return nil }

        let matchedModel = supportedModels.first {
            $0.caseInsensitiveCompare(normalizedInput) == .orderedSame
        }
        guard let matchedModel else { return nil }

        return FreeSTTResolvedModel(
            sourceID: id,
            sourceName: displayName,
            baseURL: baseURL,
            modelName: matchedModel,
            apiKey: apiKey,
            additionalHeaders: additionalHeaders,
        )
    }
}

struct StaticFreeSTTModelSource: FreeSTTModelSource {
    let id: String
    let displayName: String
    let baseURL: String
    let apiKey: String
    let additionalHeaders: [String: String]
    let supportedModels: [String]

    init(
        id: String,
        displayName: String,
        baseURL: String,
        apiKey: String = "",
        additionalHeaders: [String: String] = [:],
        supportedModels: [String],
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
        self.supportedModels = supportedModels
    }
}

enum FreeSTTModelRegistry {
    static var sources: [any FreeSTTModelSource] {
        BuiltInFreeSTTModelSources.sources
    }

    static var suggestedModelNames: [String] {
        var seen = Set<String>()
        return sources
            .flatMap(\.supportedModels)
            .compactMap { raw in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                let key = value.lowercased()
                guard seen.insert(key).inserted else { return nil }
                return value
            }
            .sorted()
    }

    static func resolve(modelName: String) -> FreeSTTResolvedModel? {
        sources.lazy.compactMap { $0.resolve(modelName: modelName) }.first
    }

    static func sourceSummaryLines() -> [String] {
        sources.map { source in
            let models = source.supportedModels.joined(separator: ", ")
            guard !models.isEmpty else { return source.displayName }
            return "\(source.displayName): \(models)"
        }
    }
}

enum BuiltInFreeSTTModelSources {
    static var sources: [any FreeSTTModelSource] {
        [
            // Add concrete free STT integrations here. Each source owns its fixed
            // transcription endpoint, optional auth/header requirements, and model names.
        ]
    }
}
