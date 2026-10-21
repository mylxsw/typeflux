/// Trusted host-internal transport. Resolved credentials must stay inside host composition.
/// Runtime-facing authority and cancellation remain owned by the caller.
protocol AskModelCompleting: Sendable {
    func complete(provider: RegisteredProvider, connection: SettingsStore.TextLLMConfiguration,
                  payload: String, onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                  onProgress: (@Sendable (AskStreamProgress) async -> Void)?) async throws -> (String, [AskToolCall])
}
