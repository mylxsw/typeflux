import CryptoKit
import Foundation
@testable import TypefluxChat
import XCTest

final class ModelIconResolverTests: XCTestCase {
    func testModelFamiliesSurviveVersionsNamespacesAndQuantization() {
        let cases: [(String, String)] = [
            ("anthropic/claude-sonnet-4:beta", "claude"),
            (" CLAUDE-SONNET-99-20990101 ", "claude"),
            ("qwen3:8b", "qwen"), ("Qwen/Qwen2.5-72B-Instruct-Q4_K_M.gguf", "qwen"),
            ("deepseek-ai/DeepSeek-R1-Distill-Qwen-32B", "deepseek"),
            ("org/DeepSeek-R1-Distill-Llama-70B", "deepseek"),
            ("openrouter/anthropic/claude-next:free", "claude"),
            ("ollama/gemma3:12b", "gemma"), ("openai/gpt-999-preview", "openai"),
            ("gpt-oss-120b", "openai"), ("o3-mini", "openai"), ("o99", "openai"),
            ("kimi-k2-thinking", "kimi"), ("moonshot-v1-128k", "moonshot"),
            ("glm-4.6", "zai"), ("glm-4.6v", "glmv"), ("chatglm3-6b", "chatglm"),
            ("codestral-latest", "mistral"), ("mistralai/devstral-2", "mistral"),
            ("qwq-32b", "qwen"), ("meta-llama/llama-4", "meta"),
            ("muse-spark", "meta"), ("spark-4", "spark"),
            ("command-a-03-2025", "commanda"), ("command-r-plus", "cohere"),
            ("x-ai/grok-4", "grok"), ("step-3.5-flash", "stepfun"),
            ("mimo-v2-flash", "xiaomimimo"), ("bge-m3", "baai"),
            ("text-embedding-3-large", "openai"), ("whisper-1", "openai"),
            ("dall-e-3", "dalle"), ("nano-banana-pro", "nanobanana")
        ]
        for (id, key) in cases {
            XCTAssertEqual(ModelIconResolver.resolve(modelID: id).resourceKey, key, id)
        }
    }

    func testIdentityPrecedesDisplayNameAndHostingProvider() {
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "claude-next", displayName: "GPT 5",
                                                 providerID: "openRouter").resourceKey, "claude")
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "deployment-17", displayName: "MiniMax M3",
                                                 providerID: "openAI").resourceKey, "minimax")
        XCTAssertEqual(
            ModelIconResolver.resolve(modelID: "openai/deployment", displayName: "Claude Sonnet").resourceKey,
            "claude"
        )
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "anthropic/new-family").resourceKey, "anthropic")
        XCTAssertEqual(
            ModelIconResolver.resolve(modelID: "deployment-17", providerID: " OpenAI ").resourceKey,
            "openai"
        )
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "unknown", providerID: "typefluxCloud"), .provider)
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "unknown", providerID: ""), .generic)
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "unknown", providerID: "ollama").resourceKey, "ollama")
    }

    func testExplicitOverridesAndAutomaticChoices() {
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "google/gemini-3-pro-image-preview:free").resourceKey,
                       "nanobanana")
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "GEMINI-3-PRO-IMAGE-PREVIEW").resourceKey, "nanobanana")
        XCTAssertEqual(ModelIconResolver.resolve(modelID: "gemini-3.1-flash-image-preview").resourceKey, "nanobanana")
        for id in ["default", " AUTO "] {
            XCTAssertEqual(ModelIconResolver.resolve(modelID: id, displayName: "GPT 5", providerID: "openAI"), .generic)
        }
    }

    func testUnknownNamesDoNotMatchEmbeddedBrandFragments() {
        for id in [
            "",
            " ",
            "mygptproxy",
            "notclaude",
            "qwenish",
            "sparkle",
            "llamazing",
            "yiannis",
            "foo1",
            "deepseeker",
            "zeta"
        ] {
            XCTAssertEqual(ModelIconResolver.resolve(modelID: id), .generic, id)
        }
        XCTAssertEqual(
            ModelIconResolver.resolve(modelID: "opaque", displayName: "🥨 Claude Sonnet").resourceKey,
            "claude"
        )
    }

    func testCatalogAndRulesAreCompleteAndResourcesMatchManifestHashes() throws {
        let icons = ModelIconResolver.catalog
        XCTAssertEqual(icons.count, 86)
        XCTAssertEqual(Set(icons.map(\.key)).count, icons.count)
        let sampleURL = try XCTUnwrap(icons.first?.descriptor.resourceURL(dark: false))
        let data = try Data(contentsOf: sampleURL.deletingLastPathComponent().appendingPathComponent("catalog.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(manifest["icons"] as? [[String: Any]])
        XCTAssertEqual(rows.filter { $0["group"] as? String == "model" }.count, 72)
        for icon in icons {
            XCTAssertEqual(ModelIconResolver.resolve(modelID: icon.key).resourceKey, icon.key)
            for dark in [false, true] {
                let url = try XCTUnwrap(icon.descriptor.resourceURL(dark: dark), icon.key)
                let bytes = try Data(contentsOf: url)
                XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let row = try XCTUnwrap(rows.first { $0["key"] as? String == icon.key })
                let hashes = try XCTUnwrap(row["sha256"] as? [String: String])
                XCTAssertEqual(hash, hashes[dark ? "dark" : "light"])
            }
        }
        let keys = Set(icons.map(\.key))
        let rules = ModelIconResolver.rules
        XCTAssertFalse(rules.exact.isEmpty)
        for key in Array(rules.aliases.keys) + Array(rules.exact.values) + Array(rules.providers.values) {
            XCTAssertTrue(keys.contains(key), key)
        }
        for aliases in rules.aliases.values {
            for alias in aliases {
                XCTAssertNoThrow(try NSRegularExpression(pattern: alias))
            }
        }
    }

    func testMissingOrUnsafeResourcesFallBackWithoutCrashing() {
        for descriptor in [ModelIconDescriptor.generic, .provider, .asset("missing", monochrome: false),
                           .asset("../openai", monochrome: true)] {
            XCTAssertNil(descriptor.resourceURL(dark: false))
            XCTAssertNil(descriptor.resourceURL(dark: true))
        }
        XCTAssertFalse(ModelIconDescriptor.generic.isMonochrome)
        XCTAssertTrue(ModelIconResolver.resolve(modelID: "gpt-5").isMonochrome)
        XCTAssertTrue(ModelIconResolver.resolve(modelID: "kimi-k2").isMonochrome)
        XCTAssertFalse(ModelIconResolver.resolve(modelID: "claude-next").isMonochrome)
    }

    func testInstalledApplicationFindsRelocatedPackageBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Typeflux.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        XCTAssertNil(ModelIconResources.installedBundle(in: nil))
        XCTAssertNil(ModelIconResources.installedBundle(in: resources))
        try FileManager.default.copyItem(at: ModelIconResources.bundle.bundleURL,
                                         to: resources.appendingPathComponent("TypefluxChat_TypefluxChat.bundle"))
        let bundle = try XCTUnwrap(ModelIconResources.installedBundle(in: resources))
        XCTAssertNotNil(bundle.url(forResource: "claude-light", withExtension: "png", subdirectory: "ModelIcons"))
    }
}
