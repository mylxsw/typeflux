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
    case typefluxCloud
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
    case groq
    case xiaomi
    case openCodeZen
    case openCodeGo
    case custom

    static let defaultProvider: LLMRemoteProvider = .openAI

    static let settingsDisplayOrder: [LLMRemoteProvider] = [
        .typefluxCloud,
        .freeModel,
        .openCodeZen,
        .openCodeGo,
        .openRouter,
        .openAI,
        .anthropic,
        .gemini,
        .grok,
        .deepSeek,
        .kimi,
        .qwen,
        .zhipu,
        .minimax,
        .xiaomi,
        .custom,
    ]

    static let onboardingDisplayOrder: [LLMRemoteProvider] = settingsDisplayOrder.filter {
        $0 != .freeModel && $0 != .typefluxCloud
    }

    var displayName: String {
        switch self {
        case .typefluxCloud:
            L("provider.llm.typefluxCloud")
        case .freeModel:
            L("provider.llm.freeModel")
        case .custom:
            L("provider.llm.custom")
        case .openRouter:
            "OpenRouter"
        case .openAI:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        case .gemini:
            "Gemini"
        case .deepSeek:
            "DeepSeek"
        case .kimi:
            "Kimi"
        case .qwen:
            "Qwen"
        case .zhipu:
            "Zhipu"
        case .minimax:
            "MiniMax"
        case .grok:
            "xAI"
        case .groq:
            "Groq"
        case .xiaomi:
            "Xiaomi MiMo"
        case .openCodeZen:
            "OpenCode Zen"
        case .openCodeGo:
            "OpenCode Go"
        }
    }

    var apiStyle: LLMRemoteAPIStyle {
        switch self {
        case .anthropic:
            .anthropic
        case .gemini:
            .gemini
        case .typefluxCloud, .freeModel, .custom, .openRouter, .openAI, .deepSeek, .kimi, .qwen, .zhipu, .minimax,
             .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
            .openAICompatible
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .typefluxCloud:
            ""
        case .freeModel:
            ""
        case .custom:
            "https://api.openai.com/v1"
        case .openRouter:
            "https://openrouter.ai/api/v1"
        case .openAI:
            "https://api.openai.com/v1"
        case .anthropic:
            "https://api.anthropic.com/v1"
        case .gemini:
            "https://generativelanguage.googleapis.com/v1beta"
        case .deepSeek:
            "https://api.deepseek.com"
        case .kimi:
            "https://api.moonshot.cn/v1"
        case .qwen:
            "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .zhipu:
            "https://open.bigmodel.cn/api/paas/v4"
        case .minimax:
            "https://api.minimax.io/v1"
        case .grok:
            "https://api.x.ai/v1"
        case .groq:
            "https://api.groq.com/openai/v1"
        case .xiaomi:
            "https://api.xiaomimimo.com/v1"
        case .openCodeZen:
            "https://opencode.ai/zen/v1"
        case .openCodeGo:
            "https://opencode.ai/zen/go/v1"
        }
    }

    var endpointPresets: [LLMRemoteEndpointPreset] {
        switch self {
        case .typefluxCloud, .freeModel:
            []
        case .zhipu:
            [
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.international",
                    url: "https://api.z.ai/api/paas/v4",
                ),
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.china",
                    url: "https://open.bigmodel.cn/api/paas/v4",
                ),
            ]
        case .minimax:
            [
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.international",
                    url: "https://api.minimax.io/v1",
                ),
                LLMRemoteEndpointPreset(
                    labelKey: "settings.models.endpointPreset.china",
                    url: "https://api.minimaxi.com/v1",
                ),
            ]
        default:
            []
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .typefluxCloud:
            return []
        case .custom:
            let allModels = LLMRemoteProvider.allCases
                .filter { $0 != .custom && $0 != .freeModel }
                .flatMap(\.suggestedModels)
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
        case .groq:
            return [
                "groq/compound",
                "groq/compound-mini",
                "llama-3.1-8b-instant",
                "llama-3.3-70b-versatile",
                "openai/gpt-oss-120b",
                "openai/gpt-oss-20b",
            ]
        case .xiaomi:
            return [
                "mimo-v2-pro",
                "mimo-v2-flash",
                "mimo-v2-omni",
            ]
        case .openCodeZen:
            return [
                "big-pickle",
                "minimax-m2.5-free",
                "ling-2.6-flash-free",
                "hy3-preview-free",
                "nemotron-3-super-free",
                "gpt-5-nano",
                "gpt-5.5",
                "claude-opus-4-7",
                "gemini-3.1-pro-preview",
                "qwen3.6-plus",
                "minimax-m2.7",
                "glm-5.1",
                "kimi-k2.6",
            ]
        case .openCodeGo:
            return [
                "deepseek-v4-pro",
                "deepseek-v4-flash",
                "qwen3.6-plus",
                "qwen3.5-plus",
                "glm-5.1",
                "glm-5",
                "kimi-k2.6",
                "kimi-k2.5",
                "minimax-m2.7",
                "minimax-m2.5",
                "mimo-v2.5",
                "mimo-v2.5-pro",
                "mimo-v2-pro",
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
            true
        case .typefluxCloud, .freeModel, .custom, .openRouter, .anthropic, .deepSeek, .kimi, .qwen, .zhipu, .minimax,
             .grok, .groq, .xiaomi, .openCodeZen, .openCodeGo:
            false
        }
    }

    var studioProviderID: StudioModelProviderID {
        switch self {
        case .typefluxCloud:
            .typefluxCloud
        case .freeModel:
            .freeModel
        case .custom:
            .customLLM
        case .openRouter:
            .openRouter
        case .openAI:
            .openAI
        case .anthropic:
            .anthropic
        case .gemini:
            .gemini
        case .deepSeek:
            .deepSeek
        case .kimi:
            .kimi
        case .qwen:
            .qwen
        case .zhipu:
            .zhipu
        case .minimax:
            .minimax
        case .grok:
            .grok
        case .groq:
            .groq
        case .xiaomi:
            .xiaomi
        case .openCodeZen:
            .openCodeZen
        case .openCodeGo:
            .openCodeGo
        }
    }

    static func from(providerID: StudioModelProviderID) -> LLMRemoteProvider? {
        switch providerID {
        case .typefluxCloud:
            .typefluxCloud
        case .freeModel:
            .freeModel
        case .customLLM:
            .custom
        case .openRouter:
            .openRouter
        case .openAI:
            .openAI
        case .anthropic:
            .anthropic
        case .gemini:
            .gemini
        case .deepSeek:
            .deepSeek
        case .kimi:
            .kimi
        case .qwen:
            .qwen
        case .zhipu:
            .zhipu
        case .minimax:
            .minimax
        case .grok:
            .grok
        case .groq:
            .groq
        case .xiaomi:
            .xiaomi
        case .openCodeZen:
            .openCodeZen
        case .openCodeGo:
            .openCodeGo
        default:
            nil
        }
    }
}
