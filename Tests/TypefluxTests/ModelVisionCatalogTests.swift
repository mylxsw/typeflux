@testable import Typeflux
import XCTest

final class ModelVisionCatalogTests: XCTestCase {
    /// Real model IDs as providers and relays list them, domestic and international, through October 2026.
    private let expectations: [(id: String, vision: Bool?)] = [
        ("gpt-4o", true),
        ("gpt-4o-mini", true),
        ("gpt-4.1-nano", true),
        ("gpt-5", true),
        ("gpt-5.1-codex", true),
        ("gpt-6-luna", true),
        ("gpt-6.1-sol", true),
        ("o1", true),
        ("o3-pro", true),
        ("o4-mini", true),
        ("o3-mini", false),
        ("o1-mini", false),
        ("gpt-3.5-turbo", false),
        ("gpt-4", false),
        ("gpt-4-0613", false),
        ("gpt-4-turbo", true),
        ("gpt-4-turbo-preview", false),
        ("gpt-oss-120b", false),
        ("gpt-oss:20b", false),
        ("gpt-4o-audio-preview", false),
        ("gpt-4o-mini-tts", false),
        ("claude-sonnet-5-5", true),
        ("claude-opus-5-5", true),
        ("claude-3-5-haiku-20241022", true),
        ("claude-2.1", false),
        ("anthropic/claude-fable-5.1", true),
        ("gemini-3.5-flash", true),
        ("gemini-2.5-pro", true),
        ("gemini-pro", false),
        ("gemini-pro-vision", true),
        ("gemma3:27b", true),
        ("gemma3:1b", false),
        ("gemma-3-12b-it", true),
        ("gemma-3-1b-it", false),
        ("gemma-4-31b-it", true),
        ("gemma4:26b", true),
        ("gemma2:9b", false),
        ("gemma3n:e4b", true),
        ("grok-4", true),
        ("grok-4-7", true),
        ("grok-4.1-fast", true),
        ("grok-3-mini", false),
        ("grok-2-vision-1212", true),
        ("grok-code-fast-1", false),
        ("llama-4-maverick", true),
        ("llama4:scout", true),
        ("llama3.2-vision:11b", true),
        ("llama3.3:70b", false),
        ("meta-llama/Llama-3.1-8B-Instruct", false),
        ("mistral-small-2506", true),
        ("mistral-small3.1", true),
        ("mistral-medium-3.5", true),
        ("mistral-large-latest", true),
        ("mistral-large-2411", false),
        ("pixtral-large-latest", true),
        ("codestral-latest", false),
        ("mistral:7b", false),
        ("magistral-medium-2509", true),
        ("phi-4", false),
        ("phi-4-multimodal-instruct", true),
        ("phi3.5-vision", true),
        ("amazon.nova-lite-v1:0", true),
        ("amazon.nova-micro-v1:0", false),
        ("command-a-vision-07-2025", true),
        ("command-r-plus", false),
        ("granite3.2-vision", true),
        ("granite-4.0-h-small", false),
        ("qwen3.5-plus", true),
        ("qwen3.5:9b", true),
        ("qwen3.6-flash", true),
        ("qwen3-max", false),
        ("qwen-max", false),
        ("qwen3:8b", false),
        ("qwen2.5:7b", false),
        ("qwen2.5vl:7b", true),
        ("Qwen/Qwen3-VL-8B-Instruct", true),
        ("qwen-vl-max", true),
        ("qvq-max", true),
        ("qwen3-omni-flash", true),
        ("qwen3-coder-plus", false),
        ("qwq-32b", false),
        ("accounts/fireworks/models/qwen2p5-vl-32b-instruct", true),
        ("deepseek-chat", false),
        ("deepseek-reasoner", false),
        ("deepseek-v4-pro", false),
        ("deepseek-v4-flash", false),
        ("deepseek-v4-flash-vision-exp", true),
        ("deepseek-r1:7b", false),
        ("deepseek-vl2", true),
        ("deepseek-ocr", true),
        ("janus-pro-7b", true),
        ("glm-4.5v", true),
        ("glm-4v-plus", true),
        ("glm-5v-turbo", true),
        ("glm-4.1v-thinking-flash", true),
        ("glm-4.7", false),
        ("glm-5.2", false),
        ("glm-4.5-air", false),
        ("glm-z1-air", false),
        ("kimi-k2.5", true),
        ("kimi-k2.6", true),
        ("kimi-k2.7-code", true),
        ("kimi-k3", true),
        ("kimi-latest", true),
        ("kimi-k2-0905-preview", false),
        ("kimi-k2-thinking", false),
        ("moonshot-v1-8k", false),
        ("moonshot-v1-8k-vision-preview", true),
        ("kimi-vl-a3b-thinking", true),
        ("MiniMax-M3", true),
        ("MiniMax-M2.5", false),
        ("minimax-m1", false),
        ("abab6.5s-chat", false),
        ("MiniMax-VL-01", true),
        ("doubao-seed-2-0-pro-260215", true),
        ("doubao-seed-1-6-250615", true),
        ("doubao-1.5-vision-pro-32k", true),
        ("doubao-1-5-pro-32k-250115", false),
        ("doubao-seed-translation", false),
        ("ernie-5.0-thinking-preview", true),
        ("ernie-4.5-turbo-vl", true),
        ("ernie-4.5-turbo-128k", false),
        ("ernie-x1.1-preview", false),
        ("hunyuan-turbos-latest", false),
        ("hunyuan-t1-vision", true),
        ("hunyuan-vision", true),
        ("step-1v-8k", true),
        ("step-3", true),
        ("step-2-16k", false),
        ("step-3.5-flash", nil),
        ("yi-vision", true),
        ("yi-lightning", false),
        ("mimo-v2.5", true),
        ("xiaomi/mimo-v2.6-flash", true),
        ("mimo-v2-flash", nil),
        ("mimo-vl-7b-rl", true),
        ("longcat-flash-omni", true),
        ("longcat-flash-chat", false),
        ("internvl3-78b", true),
        ("internlm3-8b", false),
        ("minicpm-v", true),
        ("llava:13b", true),
        ("moondream", true),
        ("typeflux/assistant-dev", nil),
        ("coding/auto", nil),
        ("my-custom-model", nil),
        ("sensenova-v6-pro", true),
        ("", nil),
        ("   ", nil),
    ]

    func testKnownModelIDsResolveToTheirVisionSupport() {
        for (id, vision) in expectations {
            XCTAssertEqual(ModelVisionCatalog.vision(forModelID: id), vision, id)
        }
    }

    func testNormalizationStripsRoutingPrefixesAndVendorSpellings() {
        XCTAssertEqual(ModelVisionCatalog.normalized(" OpenAI/GPT-4o "), "gpt-4o")
        XCTAssertEqual(ModelVisionCatalog.normalized("accounts/fireworks/models/qwen2p5-vl-32b"), "qwen2.5-vl-32b")
        XCTAssertEqual(ModelVisionCatalog.normalized("Llama_4 Scout"), "llama-4-scout")
        XCTAssertEqual(ModelVisionCatalog.normalized("gemma3:27b"), "gemma3:27b")
    }

    func testUserAndProviderAnswersWinOverTheGuess() {
        var model = RegisteredModel(id: "gpt-4o", name: "GPT-4o")
        XCTAssertEqual(model.effectiveVision, true)
        XCTAssertTrue(model.visionIsGuessed)
        model.vision = false
        XCTAssertEqual(model.effectiveVision, false)
        XCTAssertFalse(model.visionIsGuessed)

        let unknown = RegisteredModel(id: "house-model", name: "House")
        XCTAssertNil(unknown.effectiveVision)
        XCTAssertFalse(unknown.visionIsGuessed)
    }

    func testCloudModelsAreNeverGuessed() {
        let cloud = RegisteredModel(id: "gpt-4o", name: "GPT-4o", reference: "cloud:gpt-4o")
        XCTAssertNil(cloud.effectiveVision)
        XCTAssertFalse(cloud.visionIsGuessed)
        XCTAssertEqual(RegisteredModel(id: "x", name: "X", reference: "cloud:x", vision: true).effectiveVision, true)
    }
}
