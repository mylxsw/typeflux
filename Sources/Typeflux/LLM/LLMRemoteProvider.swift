import Foundation

enum LLMRemoteAPIStyle {
    case openAICompatible
    case anthropic
    case gemini
}

struct LLMRemoteEndpointPreset: Equatable {
    let labelKey: String
    let url: String
}

enum LLMRemoteProvider: String, CaseIterable, Codable {
    case freeModel
    case openRouter
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case kimi
    case qwen
    case zhipu
    case minimax
    case grok
    case xiaomi
    case custom

    var displayName: String {
        switch self {
        case .freeModel:
            return L("provider.llm.freeModel")
        case .custom:
            return L("provider.llm.custom")
        case .openRouter:
            return "OpenRouter"
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        case .deepSeek:
            return "DeepSeek"
        case .kimi:
            return "Kimi"
        case .qwen:
            return "Qwen"
        case .zhipu:
            return "Zhipu"
        case .minimax:
            return "MiniMax"
        case .grok:
            return "Grok"
        case .xiaomi:
            return "Xiaomi MiMo"
        }
    }

    var apiStyle: LLMRemoteAPIStyle {
        switch self {
        case .anthropic:
            return .anthropic
        case .gemini:
            return .gemini
        case .freeModel, .custom, .openRouter, .openAI, .deepSeek, .kimi, .qwen, .zhipu, .minimax,
            .grok, .xiaomi:
            return .openAICompatible
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .freeModel:
            return ""
        case .custom:
            return "https://api.openai.com/v1"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .openAI:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .deepSeek:
            return "https://api.deepseek.com"
        case .kimi:
            return "https://api.moonshot.cn/v1"
        case .qwen:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .zhipu:
            return "https://open.bigmodel.cn/api/paas/v4"
        case .minimax:
            return "https://api.minimax.io/v1"
        case .grok:
            return "https://api.x.ai/v1"
        case .xiaomi:
            return "https://api.xiaomimimo.com/v1"
        }
    }

    var endpointPresets: [LLMRemoteEndpointPreset] {
        switch self {
        case .freeModel:
            return []
        case .zhipu:
            return [
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.international",
                    url: "https://api.z.ai/api/paas/v4"
                ),
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.china",
                    url: "https://open.bigmodel.cn/api/paas/v4"
                ),
            ]
        case .minimax:
            return [
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.international",
                    url: "https://api.minimax.io/v1"
                ),
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.china",
                    url: "https://api.minimaxi.com/v1"
                ),
            ]
        default:
            return []
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .custom:
            let allModels = LLMRemoteProvider.allCases
                .filter { $0 != .custom && $0 != .freeModel }
                .flatMap { $0.suggestedModels }
            var seen = Set<String>()
            return allModels.filter { seen.insert($0).inserted }
        case .freeModel:
            return FreeLLMModelRegistry.suggestedModelNames
        case .openRouter:
            return [
                "openrouter/auto",
                "openai/gpt-5.4",
                "openai/gpt-5.4-mini",
                "openai/gpt-5.4-nano",
                "anthropic/claude-opus-4.6",
                "anthropic/claude-sonnet-4.6",
                "anthropic/claude-haiku-4.5",
                "google/gemini-3-flash-preview",
                "google/gemini-3.1-pro-preview",
                "google/gemini-3.1-flash-lite-preview",
                "x-ai/grok-4.1-fast",
                "x-ai/grok-4",
                "x-ai/grok-4.20",
                "moonshotai/kimi-k2.5",
                "minimax/minimax-m2.7",
                "z-ai/glm-5-turbo",
                "z-ai/glm-5",
                "z-ai/glm-4.5-air",
                "qwen/qwen3.5-flash-02-23",
                "deepseek/deepseek-v3.2",
            ]
        case .openAI:
            return [
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.4-nano",
                "gpt-5.3-codex",
            ]
        case .anthropic:
            return [
                "claude-opus-4-6",
                "claude-sonnet-4-6",
                "claude-haiku-4-5",
            ]
        case .gemini:
            return [
                "gemini-3.1-pro-preview",
                "gemini-3-flash-preview",
                "gemini-3.1-flash-lite-preview",
                "gemini-2.5-flash",
                "gemini-2.5-pro",
            ]
        case .deepSeek:
            return [
                "deepseek-chat",
                "deepseek-reasoner",
            ]
        case .kimi:
            return [
                "kimi-k2.5",
                "kimi-k2-turbo-preview",
            ]
        case .qwen:
            return [
                "qwen3.6-plus",
                "qwen3-max",
                "qwen3.5-flash",
            ]
        case .zhipu:
            return [
                "glm-5",
                "glm-5-turbo",
                "glm-4.7-flash",
                "glm-4.5-air",
            ]
        case .minimax:
            return [
                "MiniMax-M2.7",
                "MiniMax-M2.7-highspeed",
            ]
        case .grok:
            return [
                "grok-4-1-fast-reasoning",
                "grok-4-1-fast-non-reasoning",
                "grok-4.20-0309-reasoning",
                "grok-4.20-0309-non-reasoning",
            ]
        case .xiaomi:
            return [
                "mimo-v2-pro",
                "mimo-v2-flash",
                "mimo-v2-omni",
            ]
        }
    }

    var defaultModel: String {
        suggestedModels.first ?? ""
    }

    var supportsNativeStructuredOutput: Bool {
        switch self {
        case .openAI, .gemini:
            return true
        case .freeModel, .custom, .openRouter, .anthropic, .deepSeek, .kimi, .qwen, .zhipu, .minimax,
            .grok, .xiaomi:
            return false
        }
    }

    var studioProviderID: StudioModelProviderID {
        switch self {
        case .freeModel:
            return .freeModel
        case .custom:
            return .customLLM
        case .openRouter:
            return .openRouter
        case .openAI:
            return .openAI
        case .anthropic:
            return .anthropic
        case .gemini:
            return .gemini
        case .deepSeek:
            return .deepSeek
        case .kimi:
            return .kimi
        case .qwen:
            return .qwen
        case .zhipu:
            return .zhipu
        case .minimax:
            return .minimax
        case .grok:
            return .grok
        case .xiaomi:
            return .xiaomi
        }
    }

    static func from(providerID: StudioModelProviderID) -> LLMRemoteProvider? {
        switch providerID {
        case .freeModel:
            return .freeModel
        case .customLLM:
            return .custom
        case .openRouter:
            return .openRouter
        case .openAI:
            return .openAI
        case .anthropic:
            return .anthropic
        case .gemini:
            return .gemini
        case .deepSeek:
            return .deepSeek
        case .kimi:
            return .kimi
        case .qwen:
            return .qwen
        case .zhipu:
            return .zhipu
        case .minimax:
            return .minimax
        case .grok:
            return .grok
        case .xiaomi:
            return .xiaomi
        default:
            return nil
        }
    }
}
