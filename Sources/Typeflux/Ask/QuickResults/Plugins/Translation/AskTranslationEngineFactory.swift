import Foundation

/// DI-owned engines. Each AI service binds its own model for the entire request.
final class AskTranslationEngineFactory: @unchecked Sendable {
    private let settings: SettingsStore
    private let textProcessing: LLMService
    private let credentials: any AskTranslationCredentialStoring
    private var aiEngines: [String: AskAITranslationEngine] = [:]
    private let lock = NSLock()

    init(settings: SettingsStore, textProcessing: LLMService,
         credentials: any AskTranslationCredentialStoring = AskKeychainTranslationCredentials()) {
        self.settings = settings
        self.textProcessing = textProcessing
        self.credentials = credentials
    }

    @MainActor
    func makeSession() -> AskTranslationFanout {
        AskTranslationFanout()
    }

    func engine(for service: AskTranslationService) -> any AskTranslationEngine {
        switch service.kind {
        case .device: return AskOnDeviceTranslationEngine()
        case let .provider(provider):
            return AskServiceTranslationEngine(
                client: AskServiceTranslationEngine.client(for: provider),
                credentials: credentials
            )
        case let .ai(reference):
            lock.lock(); defer { lock.unlock() }
            if let cached = aiEngines[reference] {
                return cached
            }
            let engine = AskAITranslationEngine(
                service: AskTranslationLLMService(
                    settings: settings,
                    textProcessing: textProcessing,
                    reference: reference
                )
            ) { [weak settings] in AskPluginRegistry.translationModelName(settings, reference: reference) }
            // Keep a bounded set without retaining removed services indefinitely.
            if aiEngines.count >= 32 {
                aiEngines.removeAll()
            }
            aiEngines[reference] = engine
            return engine
        }
    }

    func name(for service: AskTranslationService) -> String {
        switch service.kind {
        case .device: L("ask.translation.stack.deviceTitle")
        case let .provider(provider): provider.title
        case let .ai(reference): AskPluginRegistry.sourceLabel(AskPluginRegistry.translationModelName(
                settings,
                reference: reference
            ))
        }
    }
}
