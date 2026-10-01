import Foundation

/// Carries a frozen persona through the router, including an explicit no-persona
/// choice. Only a successful multimodal request marks it applied; a fallback
/// transcript still needs the normal rewrite step.
final class TranscriptionPersonaContext: @unchecked Sendable {
    @TaskLocal static var current: TranscriptionPersonaContext?
    let prompt: String?
    private let lock = NSLock()
    private var applied = false

    init(prompt: String?) { self.prompt = prompt }

    var wasApplied: Bool { lock.withLock { applied } }
    func markApplied() { lock.withLock { applied = true } }
}
