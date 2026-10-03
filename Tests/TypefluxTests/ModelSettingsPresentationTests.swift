@testable import Typeflux
import XCTest

final class ModelSettingsPresentationTests: XCTestCase {
    private struct Row: Equatable {
        let name: String
        let models: [String]
        let available: Bool
    }

    private let rows = [
        Row(name: "Typeflux Cloud", models: ["DeepSeek Pro"], available: true),
        Row(name: "OpenAI", models: [], available: false),
        Row(name: "Custom", models: ["deepseek-flash", "coding/auto"], available: true),
        Row(name: "Ollama", models: ["llama3"], available: false),
    ]

    func testEmptyOrWhitespaceQueryMatchesEverything() {
        XCTAssertTrue(ModelSettingsPresentation.matches("", terms: []))
        XCTAssertTrue(ModelSettingsPresentation.matches("  \n", terms: ["anything"]))
    }

    func testQueryMatchesAnyTermCaseInsensitively() {
        XCTAssertTrue(ModelSettingsPresentation.matches("deepseek", terms: ["Custom", "DeepSeek Pro"]))
        XCTAssertTrue(ModelSettingsPresentation.matches(" CLOUD ", terms: ["Typeflux Cloud"]))
        XCTAssertFalse(ModelSettingsPresentation.matches("gemini", terms: ["Custom", "DeepSeek Pro"]))
        XCTAssertFalse(ModelSettingsPresentation.matches("x", terms: []))
    }

    func testPartitionKeepsOrderAndSplitsByAvailability() {
        let result = partition("")
        XCTAssertEqual(result.connected.map(\.name), ["Typeflux Cloud", "Custom"])
        XCTAssertEqual(result.unconfigured.map(\.name), ["OpenAI", "Ollama"])
    }

    func testPartitionSearchesProviderAndModelNames() {
        let byModel = partition("deepseek")
        XCTAssertEqual(byModel.connected.map(\.name), ["Typeflux Cloud", "Custom"])
        XCTAssertTrue(byModel.unconfigured.isEmpty)

        let byProvider = partition("olla")
        XCTAssertTrue(byProvider.connected.isEmpty)
        XCTAssertEqual(byProvider.unconfigured.map(\.name), ["Ollama"])

        let none = partition("gemini")
        XCTAssertTrue(none.connected.isEmpty)
        XCTAssertTrue(none.unconfigured.isEmpty)
    }

    func testEndpointLabelDropsSchemeAndTrailingSlashes() {
        XCTAssertEqual(
            ModelSettingsPresentation.endpointLabel("https://squirrel.aicode.cc/v1/"),
            "squirrel.aicode.cc/v1"
        )
        XCTAssertEqual(ModelSettingsPresentation.endpointLabel(" http://localhost:11434// "), "localhost:11434")
        XCTAssertEqual(ModelSettingsPresentation.endpointLabel("api.example.com"), "api.example.com")
        XCTAssertEqual(ModelSettingsPresentation.endpointLabel(""), "")
        XCTAssertEqual(ModelSettingsPresentation.endpointLabel("https://"), "")
    }

    func testLanguageProviderDetailCombinesCountAndEndpoint() {
        XCTAssertEqual(
            ModelSettingsPresentation.languageProviderDetail(
                modelCount: 4, baseURL: "https://api.example.com/v1", countFormat: "%d models"
            ),
            "4 models · api.example.com/v1"
        )
        XCTAssertEqual(
            ModelSettingsPresentation.languageProviderDetail(modelCount: 0, baseURL: " ", countFormat: "%d models"),
            "0 models"
        )
    }

    func testLanguageProviderDetailPrefersManagedLabel() {
        XCTAssertEqual(
            ModelSettingsPresentation.languageProviderDetail(
                modelCount: 3, baseURL: "", countFormat: "%d models", managedLabel: "Managed by Typeflux"
            ),
            "3 models · Managed by Typeflux"
        )
    }

    func testCanAddEndpointRequiresNameHostAndModel() {
        XCTAssertTrue(ModelSettingsPresentation.canAddEndpoint(
            name: "Gateway", baseURL: "https://api.example.com/v1", model: "gpt-4.1-mini"
        ))
        XCTAssertTrue(ModelSettingsPresentation.canAddEndpoint(
            name: "Local", baseURL: " HTTP://localhost:11434 ", model: "llama3"
        ))
        XCTAssertFalse(ModelSettingsPresentation.canAddEndpoint(
            name: " ", baseURL: "https://api.example.com", model: "m"
        ))
        XCTAssertFalse(ModelSettingsPresentation.canAddEndpoint(name: "G", baseURL: "https://", model: "m"))
        XCTAssertFalse(ModelSettingsPresentation.canAddEndpoint(name: "G", baseURL: "ftp://host", model: "m"))
        XCTAssertFalse(ModelSettingsPresentation.canAddEndpoint(name: "G", baseURL: "api.example.com", model: "m"))
        XCTAssertFalse(ModelSettingsPresentation.canAddEndpoint(
            name: "G", baseURL: "https://api.example.com", model: "\n"
        ))
    }

    func testConnectionChangedOnlyWhenDraftDiffers() {
        XCTAssertFalse(ModelSettingsPresentation.connectionChanged(
            savedBaseURL: "https://a", savedKey: "k", baseURL: "https://a", key: "k"
        ))
        XCTAssertTrue(ModelSettingsPresentation.connectionChanged(
            savedBaseURL: "https://a", savedKey: "k", baseURL: "https://b", key: "k"
        ))
        XCTAssertTrue(ModelSettingsPresentation.connectionChanged(
            savedBaseURL: "https://a", savedKey: "k", baseURL: "https://a", key: ""
        ))
    }

    func testUsageKeysReflectSceneAssignments() {
        XCTAssertEqual(
            ModelSettingsPresentation.usageKeys(reference: "m", rewriteReference: "m", defaultReference: "m"),
            ["ask.models.rewrite", "models.askDefault"]
        )
        XCTAssertEqual(
            ModelSettingsPresentation.usageKeys(reference: "m", rewriteReference: "x", defaultReference: "m"),
            ["models.askDefault"]
        )
        XCTAssertEqual(
            ModelSettingsPresentation.usageKeys(reference: "m", rewriteReference: "m", defaultReference: "x"),
            ["ask.models.rewrite"]
        )
        XCTAssertTrue(
            ModelSettingsPresentation.usageKeys(reference: "m", rewriteReference: "", defaultReference: "x").isEmpty
        )
    }

    private func partition(_ query: String) -> (connected: [Row], unconfigured: [Row]) {
        ModelSettingsPresentation.partition(
            rows,
            query: query,
            isAvailable: \.available,
            searchTerms: { [$0.name] + $0.models }
        )
    }

    func testUsageHintOnlyShowsWhenARowHasATag() {
        let models = [RegisteredModel(id: "a", name: "A", reference: "custom:a"),
                      RegisteredModel(id: "b", name: "B", reference: "custom:b")]
        XCTAssertFalse(ModelSettingsPresentation.showsUsageHint(models, rewriteReference: "cloud:default",
                                                                defaultReference: "cloud:default"))
        XCTAssertTrue(ModelSettingsPresentation.showsUsageHint(models, rewriteReference: "custom:b",
                                                               defaultReference: "cloud:default"))
        XCTAssertTrue(ModelSettingsPresentation.showsUsageHint(models, rewriteReference: "cloud:default",
                                                               defaultReference: "custom:a"))
        XCTAssertFalse(ModelSettingsPresentation.showsUsageHint([], rewriteReference: "x", defaultReference: "x"))
    }

    func testSceneBlockedNotesExplainGreyedOutActions() {
        XCTAssertEqual(ModelSettingsPresentation.sceneBlockedNotes(rewrite: nil, ask: nil), [])
        XCTAssertEqual(ModelSettingsPresentation.sceneBlockedNotes(rewrite: "Not a chat model", ask: "Not a chat model"),
                       ["Not a chat model"])
        XCTAssertEqual(ModelSettingsPresentation.sceneBlockedNotes(rewrite: "Rewrite off", ask: nil),
                       [L("models.rewriteBlocked", "Rewrite off")])
        XCTAssertEqual(ModelSettingsPresentation.sceneBlockedNotes(rewrite: "R", ask: "A"),
                       [L("models.rewriteBlocked", "R"), L("models.askBlocked", "A")])
        XCTAssertEqual(ModelSettingsPresentation.sceneBlockedNotes(rewrite: nil, ask: "A"), [L("models.askBlocked", "A")])
    }
}
