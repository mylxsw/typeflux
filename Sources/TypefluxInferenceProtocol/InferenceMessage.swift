import Foundation

/// Private, versioned IPC. Paths and content never belong in diagnostics.
public struct InferenceMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case prepare, transcribe, probe, ready, progress, final, failed }
    public var version = 1
    public var sequence = 0
    public var id: UUID
    public var kind: Kind
    public var configuration: InferenceConfiguration?
    public var audioPath: String?
    public var prompt: String?
    public var language: String?
    public var lowEnergy = false
    public var text: String?
    public var modelPath: String?

    public init(id: UUID = UUID(), kind: Kind) { self.id = id; self.kind = kind }

    public func validate() throws {
        guard version == 1, (0...1_000_000).contains(sequence),
              [audioPath, modelPath].allSatisfy({ Self.valid($0, limit: 4096) }),
              Self.valid(prompt, limit: 16384), Self.valid(text, limit: 131072),
              language == nil || language == "zh" || language == "en" else { throw InferenceFailure.protocolViolation }
        switch kind {
        case .prepare:
            guard let configuration else { throw InferenceFailure.protocolViolation }
            try configuration.validate()
        case .transcribe:
            guard let audioPath, audioPath.hasPrefix("/") else { throw InferenceFailure.protocolViolation }
        case .progress, .final:
            guard text != nil else { throw InferenceFailure.protocolViolation }
        default: break
        }
    }

    static func valid(_ value: String?, limit: Int) -> Bool {
        value.map { $0.utf8.count <= limit && !$0.contains("\0") } ?? true
    }
}

public struct InferenceConfiguration: Codable, Sendable, Equatable {
    public var model: String
    public var downloadBase: String?
    public var repository: String?
    public var endpoint: String?
    public var modelFolder: String?
    public var tokenizerFolder: String?

    public init(model: String, downloadBase: String? = nil, repository: String? = nil,
                endpoint: String? = nil, modelFolder: String? = nil, tokenizerFolder: String? = nil) {
        self.model = model; self.downloadBase = downloadBase; self.repository = repository
        self.endpoint = endpoint; self.modelFolder = modelFolder; self.tokenizerFolder = tokenizerFolder
    }

    public func validate() throws {
        guard !model.isEmpty, InferenceMessage.valid(model, limit: 256),
              [downloadBase, repository, endpoint, modelFolder, tokenizerFolder]
                .allSatisfy({ InferenceMessage.valid($0, limit: 4096) }),
              [downloadBase, modelFolder, tokenizerFolder].allSatisfy({ $0 == nil || $0!.hasPrefix("/") }) else {
            throw InferenceFailure.protocolViolation
        }
    }
}

public enum InferenceFailure: Error, Equatable, Sendable, LocalizedError {
    case unavailable, busy, cancelled, timedOut, protocolViolation, engineFailed
    public var errorDescription: String? { "Local transcription is unavailable. No operation was retried." }
}
