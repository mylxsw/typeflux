import Foundation

enum LLMRemoteAPIStyle {
    case openAICompatible
    case anthropic
    case gemini
}

enum LLMRemoteProvider: String, CaseIterable, Codable {
    case custom
    case openRouter
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case kimi
    case qwen
    case zhipu

    var displayName: String {
        switch self {
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
        }
    }

    var apiStyle: LLMRemoteAPIStyle {
        switch self {
        case .anthropic:
            return .anthropic
        case .gemini:
            return .gemini
        case .custom, .openRouter, .openAI, .deepSeek, .kimi, .qwen, .zhipu:
            return .openAICompatible
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .custom:
            return ""
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
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .custom:
            return ["gpt-4o-mini", "deepseek-chat", "kimi-k2.5", "qwen-plus", "glm-4.7"]
        case .openRouter:
            return ["openrouter/auto", "openai/gpt-4o-mini", "anthropic/claude-3.5-haiku", "google/gemini-2.5-flash"]
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]
        case .anthropic:
            return ["claude-sonnet-4-20250514", "claude-3-7-sonnet-20250219", "claude-3-5-haiku-20241022"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .deepSeek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .kimi:
            return ["kimi-k2.5", "kimi-k2", "kimi-k2-thinking"]
        case .qwen:
            return ["qwen-max", "qwen-plus", "qwen-turbo"]
        case .zhipu:
            return ["glm-4.7", "glm-4.7-flash", "glm-4.5-air"]
        }
    }

    var defaultModel: String {
        suggestedModels.first ?? ""
    }

    var supportsNativeStructuredOutput: Bool {
        switch self {
        case .openAI, .gemini:
            return true
        case .custom, .openRouter, .anthropic, .deepSeek, .kimi, .qwen, .zhipu:
            return false
        }
    }

    var studioProviderID: StudioModelProviderID {
        switch self {
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
        }
    }

    static func from(providerID: StudioModelProviderID) -> LLMRemoteProvider? {
        switch providerID {
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
        default:
            return nil
        }
    }
}
