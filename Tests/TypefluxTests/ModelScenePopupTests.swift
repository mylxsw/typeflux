import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite(.exclusiveUIState)
@MainActor
struct ModelScenePopupTests {
    @Test func `native popup search selection and unavailable value`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            for enabled in [false, true] {
                for initial in ["a", "missing"] {
                    var value = initial
                    let binding = Binding(get: { value }, set: { value = $0 })
                    let popup = TypefluxSearchablePopup("Model", selectedTitle: initial, searchPrompt: "Search models",
                                                        options: [("Alpha", "a"), ("Beta", "b")], selection: binding)
                    try await SettingsBehaviorTestSupport
                        .withWindow(popup.disabled(!enabled), width: 300, height: 80) { _, host in
                            let button = try #require(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
                            #expect(!button.isBordered)
                            #expect(button.isEnabled == enabled)
                            #expect(button.accessibilityLabel() == "Model")
                            let menu = try #require(button.menu)
                            let coordinator = try #require(menu.delegate as? TypefluxSearchablePopup<String>
                                .Coordinator)
                            #expect(menu.items.first?.view != nil)
                            if initial == "missing" {
                                #expect(button.selectedItem?.isEnabled == false)
                            }
                            coordinator.query = " BETA "
                            #expect(menu.items.filter { $0.tag >= 0 && !$0.isHidden }.map(\.title) == ["Beta"])
                            coordinator.query = "no-result"
                            #expect(menu.items.filter { $0.tag >= 0 && !$0.isHidden }.isEmpty)
                            coordinator.menuWillOpen(menu)
                            #expect(menu.items.filter { $0.tag >= 0 && !$0.isHidden }.count == 2)
                            coordinator.menuDidClose(menu)
                            try selectItem(at: 2, in: menu)
                            #expect(value == "b")
                            let invalid = NSMenuItem()
                            invalid.tag = -1
                            coordinator.choose(invalid)
                            #expect(value == "b")
                            coordinator.menu = nil
                            coordinator.query = ""
                        }
                }
            }
        }
    }

    @Test func `scene popups persist language selection`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.setLLMAPIKey("fixture", for: .openAI)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            try await SettingsBehaviorTestSupport.withWindow(ModelScenePicker(library: library,
                                                                              reference: Binding(
                                                                                  get: { library.defaultReference },
                                                                                  set: { library.defaultReference = $0 }
                                                                              ),
                                                                              scenario: "ask",
                                                                              title: "Ask model")) { _, host in
                let button = try #require(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
                let menu = try #require(button.menu)
                let coordinator = try #require(menu.delegate as? TypefluxSearchablePopup<String>.Coordinator)
                coordinator.menuWillOpen(menu)
                let index = try #require(menu.items.firstIndex { $0.title.contains("OpenAI") && $0.action != nil })
                try selectItem(at: index, in: menu)
                try await SettingsBehaviorTestSupport.wait { coordinator.pendingUpdate != nil }
                #expect(button.menu === menu)
                coordinator.menuDidClose(menu)
                try await SettingsBehaviorTestSupport.wait { button.selectedItem?.title == menu.items[index].title }
                #expect(library.registry.resolve(library.defaultReference)?.0.remote == .openAI)
                #expect(AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
                    .defaultReference == library.defaultReference)
            }
        }
    }

    @Test func inlineSearchEditsAndClearsTheNativeField() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let coordinator = TypefluxSearchablePopup<String>.Coordinator(selection: .constant("a"))
            let search = coordinator.searchView(prompt: "Search models")
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 80),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = search
            window.orderFront(nil)
            defer { TypefluxNavigationTestSupport.closeWindow(window) }
            search.layoutSubtreeIfNeeded()
            let field = try #require(descendants(search).compactMap { $0 as? NSSearchField }.first)
            let delegate = try #require(field.delegate as? TypefluxNativeSearchField.Coordinator)
            // Let SwiftUI install a nonempty value before the native edit and clear. Changing
            // the binding back to its initial value in one turn can coalesce away the redraw.
            coordinator.query = "Alpha"
            try await SettingsBehaviorTestSupport.wait("Popup search binding installation") {
                field.stringValue == "Alpha"
            }
            field.stringValue = "Beta"
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(coordinator.query == "Beta")
            coordinator.query = ""
            try await SettingsBehaviorTestSupport.wait("Popup search clear without editor focus") {
                field.stringValue.isEmpty
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func selectItem(at index: Int, in menu: NSMenu) throws {
        let item = menu.items[index]
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }
}
