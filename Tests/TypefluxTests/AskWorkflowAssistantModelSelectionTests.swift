import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskWorkflowAssistantModelSelectionTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func library(_ defaults: UserDefaults) throws -> AskModelLibrary {
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([
            .init(id: "fixture-a", name: "Fixture A", reference: "cloud:fixture-a"),
            .init(id: "fixture-b", name: "Fixture B", reference: "cloud:fixture-b")
        ], providerID: "typefluxCloud")
        var registry = library.registry
        registry.providers.append(.init(id: "endpoint:fixture", name: "Own fixture",
            baseURL: "https://fixture.invalid/v1", models: [
                .init(id: "own", name: "Own model", reference: "custom:fixture")
            ]))
        try library.commit(registry)
        return library
    }

    private func assistant(_ library: AskModelLibrary, api: AskWorkflowScriptedAPI,
                           token: String = "fixture-token", prefersLocal: Bool = false) -> AskWorkflowAssistant {
        AskWorkflowAssistant(dependencies: .init(api: api, session: { ("fixture-owner", token) },
            deviceId: "fixture-device", modelLibrary: library, prefersLocal: { prefersLocal }, defaults: library.defaults))
    }

    @Test func selectedModelIsSentWithoutChangingTheAskDefault() async throws {
        try await UI.withFixture { settings in
            let library = try library(settings.defaults)
            let api = AskWorkflowScriptedAPI([.reply("First"), .reply("Second")])
            let assistant = assistant(library, api: api)
            defer { assistant.stop() }
            assistant.bind(workflowID: "one")
            assistant.selectModel("cloud:fixture-a")
            #expect(assistant.modelName == "Fixture A")
            assistant.send("First request")
            try await UI.wait { !assistant.isBusy }
            assistant.selectModel("cloud:fixture-b")
            assistant.send("Second request")
            try await UI.wait { !assistant.isBusy }
            #expect(await api.sends.map(\.modelRef) == ["cloud:fixture-a", "cloud:fixture-b"])
            #expect(library.defaultReference == "cloud:default")
        }
    }

    @Test func selectionsAreRememberedPerWorkflowAndFollowNewlySavedDrafts() async throws {
        try await UI.withFixture { settings in
            let library = try library(settings.defaults)
            let api = AskWorkflowScriptedAPI([])
            let assistant = assistant(library, api: api)
            assistant.bind(workflowID: "one")
            assistant.selectModel("cloud:fixture-a")
            assistant.bind(workflowID: "two")
            #expect(assistant.selectedModelReference == nil)
            assistant.selectModel("cloud:fixture-b")
            assistant.bind(workflowID: "one")
            #expect(assistant.modelReference(local: false) == "cloud:fixture-a")
            let restored = self.assistant(library, api: api)
            restored.bind(workflowID: "two")
            #expect(restored.modelReference(local: false) == "cloud:fixture-b")
            restored.bind(workflowID: nil)
            restored.selectModel("custom:fixture")
            restored.rebind(to: "saved-draft")
            assistant.bind(workflowID: "saved-draft")
            #expect(assistant.selectedModelReference == "custom:fixture")
            AskWorkflowAssistant.forget(workflowID: "saved-draft", defaults: settings.defaults)
            assistant.bind(workflowID: "saved-draft")
            #expect(assistant.selectedModelReference == nil)
            assistant.stop(); restored.stop()
        }
    }

    @Test func localConversationsKeepTheirModelRestrictions() async throws {
        try await UI.withFixture { settings in
            let library = try library(settings.defaults)
            for (token, prefersLocal) in [("", false), ("fixture-token", true)] {
                let assistant = assistant(library, api: AskWorkflowScriptedAPI([]), token: token,
                                          prefersLocal: prefersLocal)
                #expect(!assistant.canUseCloudModels)
                #expect(assistant.modelReference(local: true) == "custom:fixture")
                assistant.selectModel("cloud:fixture-a")
                #expect(assistant.selectedModelReference == nil)
                assistant.selectModel("custom:fixture")
                assistant.selectModel("")
                #expect(assistant.selectedModelReference == "custom:fixture")
            }
        }
    }

    @Test func aRunningRequestKeepsItsModelUntilItStops() async throws {
        try await UI.withFixture { settings in
            let library = try library(settings.defaults)
            let api = AskWorkflowScriptedAPI([.running], holdRunning: true)
            let assistant = assistant(library, api: api)
            defer { assistant.stop() }
            assistant.selectModel("cloud:fixture-a")
            assistant.send("Hold this request")
            #expect(assistant.isBusy)
            assistant.selectModel("cloud:fixture-b")
            #expect(assistant.selectedModelReference == "cloud:fixture-a")
            assistant.stop()
            assistant.selectModel("cloud:fixture-b")
            #expect(assistant.selectedModelReference == "cloud:fixture-b")
        }
    }

    @Test func theComposerOpensTheModelMenuAndRemovesTheStorageSuffix() async throws {
        try await UI.withFixture { settings in
            let library = try library(settings.defaults)
            let api = AskWorkflowScriptedAPI([.running, .running], holdRunning: true)
            let assistant = assistant(library, api: api)
            assistant.selectModel("cloud:fixture-a")
            let fixture = try AskWorkflowFixture()
            let model = AskWorkflowEditorModel(store: fixture.store, settings: settings, assistant: assistant,
                                               tester: AskWorkflowTester(home: fixture.home.path))
            AskGlassMenuPresenter.shared.hide()
            defer { assistant.stop(); AskGlassMenuPresenter.shared.hide() }
            for language in [AppLanguage.simplifiedChinese, .english] {
                AppLocalization.shared.setLanguage(language)
                try await UI.withWindow(AskWorkflowAssistantPanel(model: model, assistant: assistant),
                                        width: 340, height: 600) { window, host in
                    window.setFrameOrigin(NSPoint(x: 100, y: 100))
                    #expect(!UI.contains(L("ask.workflow.assistant.local"), in: host))
                    #expect(!UI.contains(L("ask.workflow.assistant.cloud"), in: host))
                    let chooser = try #require(UI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == "ask.workflow.assistant.model"
                            && $0.role == NSAccessibility.Role.button.rawValue
                    })
                    try chooser.press()
                    try await UI.wait {
                        AskGlassMenuPresenter.shared.panel.map { UI.contains("Fixture B", in: $0) } == true
                    }
                    let menu = try #require(AskGlassMenuPresenter.shared.panel)
                    try UI.button("Fixture B", in: menu).press()
                    try await UI.wait { assistant.selectedModelReference == "cloud:fixture-b" }
                    try await UI.wait { UI.contains("Fixture B", in: host) }
                    try UI.snapshot(host, name: "workflow-assistant-model-\(language.rawValue)")
                    assistant.send("Hold")
                    try await UI.wait {
                        UI.elements(in: host).first {
                            $0.value("accessibilityIdentifier") as? String == "ask.workflow.assistant.model"
                                && $0.role == NSAccessibility.Role.button.rawValue
                        }?.value("isAccessibilityEnabled") as? Bool == false
                    }
                    assistant.stop()
                }
            }
        }
    }
}
