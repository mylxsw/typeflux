import Foundation
import Darwin

/// Pure framework integration. Host services and mutable domain objects never
/// cross this boundary. Installed adapters are trusted in-process code.
protocol AskAgentTurnAdapter: Sendable {
    var descriptor: AskAgentDescriptor { get }
    func next(_ input: AskAgentTurnInput) async throws -> AskAgentDecision
}
struct AskAgentTurnMessage: Sendable {
    let role: String
    let content: String
    let callID: String?
}
struct AskAgentTurnInput: Sendable {
    let runID: String
    let binding: AskAgentBinding
    let turnSequence: Int
    let messages: [AskAgentTurnMessage]
    let preparedPrompt: AskRouteJSON
    let modelReference: String
    let previous: AskAgentTurnOutcome?
    let state: AskRouteJSON?
}
struct AskAgentToolIntent: Sendable {
    let name: String
    let arguments: String
    let callID: String
}
enum AskAgentTurnOutcome: Sendable {
    case model(content: String, tools: [AskAgentToolIntent], finishReason: String?)
    case tools([AskAgentTurnMessage])
    case resume
}
enum AskAgentDecision: Sendable {
    case requestModel(prompt: AskRouteJSON, purpose: String, state: AskRouteJSON?)
    case proposeTools([AskAgentToolIntent], content: String, state: AskRouteJSON?)
    case finish(content: String, reasoning: String?, state: AskRouteJSON?)
    case suspend(state: AskRouteJSON?)

    var state: AskRouteJSON? {
        switch self {
        case let .requestModel(_, _, state), let .proposeTools(_, _, state), let .finish(_, _, state), let .suspend(state): state
        }
    }
}
struct DefaultAskAgentTurnAdapter: AskAgentTurnAdapter {
    let descriptor = AskAgentDescriptor.default
    func next(_ input: AskAgentTurnInput) async throws -> AskAgentDecision {
        if case let .model(content, tools, _) = input.previous {
            if !tools.isEmpty { return .proposeTools(tools, content: content, state: nil) }
            return .finish(content: content, reasoning: nil, state: nil)
        }
        return .requestModel(prompt: input.preparedPrompt, purpose: "main", state: nil)
    }
}

/// A trusted exclusive local writer cohort must own its isolated directory for
/// its lifetime. Production has no alternate migration/activation configuration.
final class AskTurnDirectoryOwner: @unchecked Sendable {
    let directory: URL
    private let descriptor: Int32
    private let lock = NSLock()
    private var writerClaimed = false
    init(directory: URL) throws {
        guard directory.resolvingSymlinksInPath().standardizedFileURL !=
                AskLocalEngine.defaultDirectory.resolvingSymlinksInPath().standardizedFileURL else {
            throw AskLocalError.implementationUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        descriptor = open(directory.appendingPathComponent(".agent-state-v1.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw AskLocalError.implementationUnavailable
        }
    }
    fileprivate func claimWriter() -> AskTurnWriterLease? {
        lock.withLock {
            guard !writerClaimed else { return nil }
            writerClaimed = true
            return AskTurnWriterLease(owner: self)
        }
    }
    fileprivate func releaseWriter() { lock.withLock { writerClaimed = false } }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

final class AskTurnWriterLease: Sendable {
    private let owner: AskTurnDirectoryOwner
    fileprivate init(owner: AskTurnDirectoryOwner) { self.owner = owner }
    deinit { owner.releaseWriter() }
}

/// Immutable support intersection. Registry membership and peer declarations do
/// not grant selection, approval, tool authority, or state compatibility.
struct AskAgentTurnPolicy: Sendable {
    private struct Registration: Sendable { let descriptor: AskAgentDescriptor; let adapter: any AskAgentTurnAdapter }
    private let adapters: [String: Registration]
    private let enabled: [AskAgentBinding]
    private let peer: AskAgentPeerCapabilities
    private let owner: AskTurnDirectoryOwner?
    let selected: AskAgentBinding

    init(adapters: [any AskAgentTurnAdapter], selected: AskAgentBinding,
         enabled: [AskAgentBinding], peer: AskAgentPeerCapabilities,
         owner: AskTurnDirectoryOwner? = nil) throws {
        var entries: [String: Registration] = [:]
        guard adapters.count <= 32, enabled.count <= 32 else { throw AskAgentRegistrySetupError.invalidBinding }
        for adapter in adapters {
            let binding = adapter.descriptor.binding
            guard binding.isWellFormed, entries[Self.key(binding)] == nil else { throw AskAgentRegistrySetupError.invalidBinding }
            entries[Self.key(binding)] = .init(descriptor: adapter.descriptor, adapter: adapter)
        }
        self.adapters = entries; self.enabled = enabled; self.peer = peer; self.owner = owner; self.selected = selected
        _ = try resolve(selected, operations: Set(AskAgentOperation.allCases))
    }
    private static func key(_ binding: AskAgentBinding) -> String { "\(binding.id)/\(binding.version)" }
    func resolve(_ binding: AskAgentBinding, operations: Set<AskAgentOperation> = []) throws -> any AskAgentTurnAdapter {
        guard binding.isWellFormed, enabled.contains(binding), let registration = adapters[Self.key(binding)],
              registration.descriptor.supports(binding, requiredOperations: operations),
              binding == .default || (owner != nil && peer.supports(binding, operations: operations)) else { throw AskLocalError.implementationUnavailable }
        return registration.adapter
    }
    func claimWriter(directory: URL) -> (required: Bool, lease: AskTurnWriterLease?) {
        guard let owner else { return (false, nil) }
        guard acceptsDirectory(directory) else { return (true, nil) }
        return (true, owner.claimWriter())
    }
    func acceptsDirectory(_ directory: URL) -> Bool { owner == nil || owner?.directory == directory.resolvingSymlinksInPath().standardizedFileURL }
    static var canonical: Self {
        // Static canonical composition cannot fail and enables no alternate code.
        do {
            return try Self(adapters: [DefaultAskAgentTurnAdapter()], selected: .default,
                            enabled: [.default], peer: .canonical)
        } catch { preconditionFailure("Invalid canonical adapter configuration") }
    }
}

struct AskAgentPeerCapabilities: Codable, Sendable {
    struct Contract: Codable, Sendable {
        let id: String
        let version: Int
        let operations: [AskAgentOperation]
    }
    let protocolVersion: Int
    let contracts: [Contract]
    static let header = "X-Typeflux-Agent-Capabilities"
    static let canonical = Self(protocolVersion: 1, contracts: [.init(id: AskAgentBinding.default.id, version: 1, operations: AskAgentOperation.allCases)])
    static func parse(_ raw: String?) -> Self? {
        guard let raw, raw.utf8.count <= 4096, let value = try? JSONDecoder().decode(Self.self, from: Data(raw.utf8)), value.isValid else { return nil }
        return value
    }
    var isValid: Bool {
        var seen = Set<String>()
        return headerValue.utf8.count <= 4096 && protocolVersion == 1 && contracts.count <= 32 && contracts.allSatisfy {
            AskAgentBinding(id: $0.id, version: $0.version).isWellFormed
                && $0.operations.count <= AskAgentOperation.allCases.count
                && seen.insert("\($0.id)/\($0.version)").inserted
        }
    }
    func supports(_ binding: AskAgentBinding, operations: Set<AskAgentOperation>) -> Bool {
        isValid && contracts.contains { $0.id == binding.id && $0.version == binding.version && Set($0.operations).isSuperset(of: operations) }
    }
    var headerValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }
}
