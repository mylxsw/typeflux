import Foundation

/// Guesses whether a model reads images from its ID, for models whose provider
/// does not say (most OpenAI-compatible relays). A setting the user makes always
/// wins; see `RegisteredModel.effectiveVision`.
///
/// Rules are checked in order and the first match decides. `false` is reserved
/// for families known to be text-only, because it hides the model from
/// conversations with images. Anything unrecognised stays `nil` and may still
/// try an image once (see `AskModelLibrary.acceptsImages`).
///
/// Coverage as of October 2026, domestic and international: OpenAI, Anthropic,
/// Google, xAI, Meta, Mistral, Microsoft, Amazon, Cohere, IBM, Qwen, DeepSeek,
/// Zhipu GLM, Moonshot Kimi, MiniMax, ByteDance Doubao, Baidu ERNIE, Tencent
/// Hunyuan, StepFun, 01.AI Yi, Xiaomi MiMo, Meituan LongCat, InternLM, MiniCPM,
/// plus common Ollama tags.
enum ModelVisionCatalog {
    static func vision(forModelID id: String) -> Bool? {
        let name = normalized(id)
        guard !name.isEmpty else { return nil }
        return rules.first { $0.pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil }?.vision
    }

    /// Lowercased last path component, so `openai/gpt-4o`, `accounts/fireworks/models/qwen2p5-vl-32b`
    /// and `Qwen/Qwen3-VL-8B` read like the bare IDs the rules expect.
    static func normalized(_ id: String) -> String {
        var name = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        name = name.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        // Fireworks writes versions as `2p5`.
        return name.replacingOccurrences(of: #"(\d)p(\d)"#, with: "$1.$2", options: .regularExpression)
    }

    private struct Rule {
        let pattern: NSRegularExpression
        let vision: Bool
    }

    private static func rule(_ pattern: String, _ vision: Bool) -> Rule {
        // Patterns are literals below; a typo fails every test, not one user.
        Rule(pattern: try! NSRegularExpression(pattern: pattern), vision: vision)
    }

    private static let rules: [Rule] = [
        // Speech and realtime variants carry vision-family names but take no images.
        rule(#"(audio|realtime|transcribe|tts|speech|asr)"#, false),
        rule(#"(captioner|image-generation|imagen|dall-e|gpt-image|seedream|seedance|hunyuanimage)"#, false),

        // Explicit markers used across vendors: qwen2.5-vl, internvl3, kimi-vl,
        // deepseek-vl2, glm-4.5v, grok-2-vision, deepseek-v4-flash-vision-exp,
        // qwen3-omni, longcat-flash-omni, deepseek-ocr, phi-4-multimodal.
        rule(#"(vl|vlm)([-.:\d]|$)"#, true),
        rule(#"(vision|omni|ocr|multimodal)"#, true),
        rule(#"glm-?\d+(\.\d+)?v"#, true),
        rule(#"(llava|bakllava|moondream|pixtral|paligemma|smolvlm|cogvlm|cogagent|qvq|janus|minicpm-?[vo]|intern-s1)"#, true),
        rule(#"step-?(1|1\.5)[vo]|step-?r1-v|step-?3([-:]|$)"#, true),

        // OpenAI
        rule(#"gpt-oss|gpt-3\.5|(^|-)o1-(mini|preview)|(^|-)o3-mini|davinci|babbage"#, false),
        rule(#"gpt-4-turbo-preview|gpt-4-\d{4}-preview|^gpt-4(-32k)?(-\d{4})?$"#, false),
        rule(#"gpt-4o|chatgpt-4o|gpt-4\.[15]|gpt-4-turbo|gpt-[5-9]|(^|-)o[1-9]([-:]|$)|computer-use"#, true),

        // Anthropic: every Claude since 3 reads images.
        rule(#"claude-(instant|2)"#, false),
        rule(#"claude"#, true),

        // Google: Gemini 1.0 Pro was text-only; Gemma reads images from 3 (except 1B/270M), 3n and 4.
        rule(#"gemini-(1\.0-)?pro$|gemini-1\.0-pro"#, false),
        rule(#"gemini"#, true),
        rule(#"gemma-?3[-:]?(1b|270m)|codegemma|gemma-?[12]([-.:]|$|\d)"#, false),
        rule(#"gemma-?(3|3n|4)"#, true),

        // xAI: Grok 4 and later read images; Grok 3, earlier text models and grok-code do not.
        rule(#"grok-code|grok-(beta|[123])([-.:]|$)"#, false),
        rule(#"grok-[4-9]"#, true),

        // Meta: Llama 4 is natively multimodal; Llama 3.2 vision variants say "vision".
        rule(#"llama-?4"#, true),
        rule(#"llama-?[123]([-.:]|$|\d)|codellama"#, false),

        // Mistral: Small 3.1+, Medium 3+, Large 3, Magistral 2509+ and Ministral 3 read images.
        rule(#"mistral-small-?(3\.[1-9]|25(0[3-9]|1\d)|latest)|mistral-medium-?(3|25|latest)|mistral-large-?(3|25(1[0-2])|latest)|magistral-.*25(09|1\d)|ministral-.*2512"#, true),
        rule(#"codestral|mixtral|mathstral|mistral-nemo|open-mistral|mistral-7b|^mistral(:|$)|mistral-large-?(2|24\d\d)"#, false),

        // Microsoft, Amazon, Cohere, IBM
        rule(#"(^|-)phi-?[1-4]"#, false),
        rule(#"nova-(2-)?(lite|pro|premier)"#, true),
        rule(#"nova-(2-)?micro"#, false),
        rule(#"command|aya-expanse|granite"#, false),

        // Qwen: everything from 3.5 is natively multimodal; earlier text lines are not.
        rule(#"qwen-?(3\.[5-9]|[4-9](\.\d+)?)([-:]|$)"#, true),
        rule(#"qwq|qwen"#, false),

        // DeepSeek: V3, R1 and the public V4 Pro/Flash are text-only.
        rule(#"deepseek"#, false),

        // Zhipu: GLM-4, 4.5, 4.6, 4.7 and 5.x without a "v" are text-only.
        rule(#"chatglm|codegeex|glm-?\d|glm-z1"#, false),

        // Moonshot: Kimi K2.5 and later (K2.6, K2.7, K3) and kimi-latest read images.
        rule(#"kimi-k2[.-]?[5-9]|kimi-k[3-9]|kimi-latest"#, true),
        rule(#"kimi-k2|moonshot-v1-\d+k$"#, false),

        // MiniMax: M3 reads images and video; M1, M2.x, Text-01 and abab do not.
        rule(#"minimax-m[3-9]"#, true),
        rule(#"minimax-m[12]|minimax-text|abab"#, false),

        // ByteDance Doubao: the Seed 1.6+ and 2.0 lines are multimodal; older pro/lite are text.
        rule(#"doubao-seed-translation"#, false),
        rule(#"doubao-seed|ui-tars"#, true),
        rule(#"doubao-(1[.-]5-)?(pro|lite)|skylark"#, false),

        // Baidu ERNIE: 5.0 is natively multimodal; 4.5 (non-VL), X1, Speed, Lite and Tiny are text.
        rule(#"ernie-[5-9]"#, true),
        rule(#"ernie-(x1|4|3|speed|lite|tiny|char|novel)"#, false),

        // Tencent Hunyuan text lines (vision lines say "vision").
        rule(#"hunyuan-(t1|turbos?|lite|standard|large|pro|role|code|a13b|functioncall|translation)"#, false),

        // StepFun, 01.AI, Xiaomi MiMo, Meituan LongCat, Shanghai AI Lab, Baichuan, SenseTime
        rule(#"step-(1-(8k|32k|128k|256k|flash)|2)"#, false),
        rule(#"yi-(large|medium|spark|lightning|34b|9b|6b|1\.5)"#, false),
        rule(#"mimo-v2[.-]?[5-9]|mimo-v[3-9]"#, true),
        rule(#"mimo-7b"#, false),
        rule(#"longcat-flash-(chat|thinking)"#, false),
        rule(#"internlm|baichuan"#, false),
        rule(#"sensenova-v6"#, true)
    ]
}

extension RegisteredModel {
    /// What the app treats as the model's vision support: the provider's or the
    /// user's answer, else a guess from the ID. The Cloud catalog is authoritative,
    /// so Cloud models are never guessed.
    var effectiveVision: Bool? {
        if let vision { return vision }
        return reference.hasPrefix("cloud:") ? nil : ModelVisionCatalog.vision(forModelID: id)
    }

    /// True when `effectiveVision` comes from the ID alone, so settings can say so.
    var visionIsGuessed: Bool {
        vision == nil && effectiveVision != nil
    }
}
