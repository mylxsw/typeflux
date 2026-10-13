import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ModelProviderFormTests {
    private typealias Support = SettingsBehaviorTestSupport

    @Test func endpointFormValidatesAndPersistsTrimmedValues() async throws {
        try await Support.withFixture { settings in
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            try await TypefluxNavigationTestSupport.withWindow(
                AddModelEndpointView(library: library)
            ) { window, host in
                let saveButton = try Support.button(L("ask.models.save"), in: host)
                #expect(saveButton.value("isAccessibilityEnabled") as? Bool == false)
                try await edit(L("ask.models.name"), value: " Fixture Gateway ", window: window, host: host)
                try await edit(L("ask.models.url"), value: " https://fixture.invalid/v1 ", window: window, host: host)
                try await edit(L("ask.models.modelID"), value: " fixture-model ", window: window, host: host)
                try await edit("API Key", value: " fixture-key ", window: window, host: host)
                try Support.button(L("ask.models.save"), in: host).press()
                let profile = try #require(library.profiles.first { $0.name == "Fixture Gateway" })
                #expect(profile.baseURL == "https://fixture.invalid/v1")
                #expect(profile.model == "fixture-model")
                let provider = try #require(library.registry.resolve(profile.reference)?.0)
                #expect(library.connection(provider).apiKey == "fixture-key")
                #expect(AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
                    .profiles.contains { $0.name == "Fixture Gateway" })
            }
        }
    }

    @Test func providerFormSavesConnectionAndAddsManualModel() async throws {
        try await Support.withFixture { settings in
            let provider = RegisteredProvider(id: "endpoint:fixture", name: "Fixture Gateway",
                                              baseURL: "https://old.invalid/v1",
                                              credentialAccount: "fixture-provider-account",
                                              models: [.init(
                                                  id: "old-model",
                                                  name: "Old"
                                              )])
            try ModelRegistry(providers: [provider]).write(settings.defaults)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            try await TypefluxNavigationTestSupport.withWindow(
                ProviderModelsView(library: library, providerID: provider.id)
            ) { window, host in
                try await edit(
                    L("settings.models.apiEndpoint"),
                    value: "https://new.invalid/v1",
                    window: window,
                    host: host
                )
                try await edit("API Key", value: "fixture-key", window: window, host: host)
                try Support.button(L("ask.models.save"), in: host).press()
                let updated = try #require(library.providers.first { $0.id == provider.id })
                #expect(library.connection(updated).baseURL == "https://new.invalid/v1")
                #expect(library.connection(updated).apiKey == "fixture-key")
                try Support.button(L("models.manual"), in: host).press()
                try await edit(L("ask.models.modelID"), value: " manual-model ", window: window, host: host)
                try Support.button(L("models.add"), in: host).press()
                try await Support
                    .wait {
                        library.providers.first { $0.id == provider.id }?.models
                            .contains { $0.id == "manual-model" } == true }
                #expect(ModelRegistry.read(settings.defaults)?.providers.first { $0.id == provider.id }?
                    .models.contains { $0.id == "manual-model" } == true)
            }
        }
    }

    @Test func catalogSearchAndSelectionKeepExistingAndExcludedModelsDisabled() async throws {
        try await Support.withFixture { _ in
            let state = ModelCatalogSelectionFixture.State()
            var additions = 0
            var cancellations = 0
            let models: [RegisteredModel] = [.init(id: "existing", name: "Existing"),
                                             .init(id: "new", name: "New"), .init(id: "embedding", name: "Embedding")]
            try await TypefluxNavigationTestSupport.withWindow(ModelCatalogSelectionFixture(
                state: state,
                models: models,
                onCancel: { cancellations += 1 },
                onAdd: { additions += 1 }
            )) { window, host in
                let checkboxes = Support.elements(in: host).filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
                #expect(checkboxes.count == 3)
                #expect(checkboxes.filter { $0.value("isAccessibilityEnabled") as? Bool == false }.count == 2)
                try #require(checkboxes.first { $0.value("isAccessibilityEnabled") as? Bool == true }).press()
                try await Support.wait { state.selected == ["existing", "new"] }
                try await Support.wait { Support.contains(L("models.add") + " 1", in: host) }
                try Support.button(L("models.add") + " 1", in: host).press()
                #expect(additions == 1)
                let search = try #require(descendants(host).compactMap { $0 as? NSSearchField }.first)
                #expect(window.makeFirstResponder(search))
                let editor = try #require(window.fieldEditor(false, for: search) as? NSTextView)
                editor.insertText(
                    "Embedding",
                    replacementRange: NSRange(location: 0, length: editor.string.utf16.count)
                )
                try await Support.wait {
                    Support.elements(in: host).filter { $0.role == NSAccessibility.Role.checkBox.rawValue }.count == 1
                }
                try Support.button(L("ask.models.cancel"), in: host).press()
                #expect(cancellations == 1 && state.selected == ["existing", "new"])
            }
        }
    }

    private func edit(_ label: String, value: String, window: NSWindow, host: NSView) async throws {
        // Native LabeledContent can combine its caption with the field's explicit accessibility name.
        let matches: (Support.Element) -> Bool = {
            $0.role.contains("TextField") && ($0.label == label || $0.label == label + ", " + label)
        }
        try await Support.wait { Support.elements(in: host).contains(where: matches) }
        let element = try #require(Support.elements(in: host).first(where: matches))
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first {
            window.convertToScreen($0.convert($0.bounds, to: nil)).intersects(element.frame)
        })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(nil)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private struct ModelCatalogSelectionFixture: View {
    @MainActor final class State: ObservableObject {
        @Published var selected: Set<String> = ["existing"]
    }

    @ObservedObject var state: State
    let models: [RegisteredModel]
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        ModelCatalogView(providerName: "Fixture", models: models, existingIDs: ["existing"],
                         selected: $state.selected, onCancel: onCancel, onAdd: onAdd)
    }
}
