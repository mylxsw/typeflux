import Foundation

/// Callable runtime operations, independent of tool authorization and UI features.
enum AskAgentOperation: String, CaseIterable, Codable, Sendable {
    case send, result, inferenceResult = "inference_result", cancel, retry, regenerate, steer, resume, observe
}

struct AskAgentDescriptor: Sendable {
    let binding: AskAgentBinding
    let operations: Set<AskAgentOperation>

    static let `default` = Self(binding: .default, operations: Set(AskAgentOperation.allCases))

    func supports(_ binding: AskAgentBinding, requiredOperations: Set<AskAgentOperation>) -> Bool {
        binding.isWellFormed && binding == self.binding && operations.isSuperset(of: requiredOperations)
    }
}

struct AskAgentRegistration: Sendable {
    let descriptor: AskAgentDescriptor
    let runtime: any AskAgentRuntime
}

/// Internal composition failures, never presented as a new user-facing error.
enum AskAgentRegistrySetupError: Error {
    case invalidBinding, duplicateBinding, missingDefault
}

/// Immutable composition. Registration does not confer state ownership, tool
/// authorization, or permission to activate an implementation on an old peer.
struct AskAgentRegistry: Sendable {
    private struct Key: Hashable, Sendable {
        let id: String
        let version: Int
        init(_ binding: AskAgentBinding) { id = binding.id; version = binding.version }
    }
    private let registrations: [Key: AskAgentRegistration]
    private let defaultBinding: AskAgentBinding

    init(registrations: [AskAgentRegistration], defaultBinding: AskAgentBinding) throws {
        guard defaultBinding.isWellFormed else { throw AskAgentRegistrySetupError.invalidBinding }
        var entries: [Key: AskAgentRegistration] = [:]
        for registration in registrations {
            let binding = registration.descriptor.binding
            guard binding.isWellFormed else { throw AskAgentRegistrySetupError.invalidBinding }
            let key = Key(binding)
            guard entries[key] == nil else { throw AskAgentRegistrySetupError.duplicateBinding }
            entries[key] = registration
        }
        guard entries[Key(defaultBinding)] != nil else { throw AskAgentRegistrySetupError.missingDefault }
        self.registrations = entries
        self.defaultBinding = defaultBinding
    }

    func lookup(_ binding: AskAgentBinding) throws -> AskAgentRegistration {
        guard binding.isWellFormed, let registration = registrations[Key(binding)] else {
            throw AskLocalError.implementationUnavailable
        }
        return registration
    }

    func selectDefault(requiredOperations: Set<AskAgentOperation>) throws -> AskAgentRegistration {
        try resolvePersisted(defaultBinding, requiredOperations: requiredOperations)
    }

    /// Historical absence always means the legacy default, never the new-run default.
    func resolvePersisted(_ binding: AskAgentBinding?, requiredOperations: Set<AskAgentOperation>) throws -> AskAgentRegistration {
        let binding = binding ?? .default
        let registration = try lookup(binding)
        guard registration.descriptor.supports(binding, requiredOperations: requiredOperations) else {
            throw AskLocalError.implementationUnavailable
        }
        return registration
    }
}
