import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// These regressions share the suite's exclusive UI state and acceptance filter.
@MainActor
extension UnifiedSettingsBehaviorTests {
    @Test(arguments: [AskBrowserSearchEntry.Kind.tab, .bookmark])
    func `browser source identifiers remain distinct and edits preserve the other source`(
        kind: AskBrowserSearchEntry.Kind
    ) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            for style in InterfaceStyle.allCases {
                settings.askBrowserSearchSettings.tabsEnabled = false
                settings.askBrowserSearchSettings.bookmarksEnabled = false
                let view = LauncherSearchSettingsView(settings: settings, index: AskTestFileIndex(),
                                                      fullDiskAccess: { true }, tab: .browsers)
                    .environment(\.interfaceStyle, style)
                try await SettingsBehaviorTestSupport.withWindow(view, width: 640, height: 900) { _, host in
                    let identifier = "launcher.search.browser.\(kind.rawValue).enabled"
                    try await SettingsBehaviorTestSupport.wait { regressionElements(identifier, in: host).count == 1 }
                    let matchingSwitch = regressionElements(identifier, in: host).first
                    let toggle = try #require(matchingSwitch)
                    let frame = toggle.frame
                    #expect(frame.width > 0 && frame.height > 0)
                    try toggle.press()
                    #expect(settings.askBrowserSearchSettings.tabsEnabled == (kind == .tab))
                    #expect(settings.askBrowserSearchSettings.bookmarksEnabled == (kind == .bookmark))
                    try toggle.press()
                    #expect(!settings.askBrowserSearchSettings.tabsEnabled)
                    #expect(!settings.askBrowserSearchSettings.bookmarksEnabled)
                }
            }
        }
    }

    @Test func `persona menu selection targets each picker and preserves the unsaved definition`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let fixture = try PersonaLibraryFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            model.selectPersona(fixture.custom.id)
            model.personaDraftPrompt = "Unsaved definition"
            let originalDefault = model.defaultPersonaSelectionID
            let view = StudioPersonaLibraryView(viewModel: model) { model.personaPendingDeletion = $0 }
            try await SettingsBehaviorTestSupport.withWindow(view, width: 950, height: 650) { window, host in
                window.setFrameOrigin(NSPoint(x: 100, y: 100))
                try await SettingsBehaviorTestSupport.wait {
                    regressionElements("personas.auxiliarySelection", in: host).count == 1
                        && regressionElements("personas.defaultSelection", in: host).count == 1
                }
                try Self.selectPopupItem(fixture.custom.name, identifier: "personas.auxiliarySelection", in: window)
                #expect(model.auxiliaryPersonaID == fixture.custom.id.uuidString)
                #expect(model.defaultPersonaSelectionID == originalDefault)
                // Let AppKit finish closing the first tracking loop before opening the next picker.
                try await Task.sleep(for: .milliseconds(200))
                try Self.selectPopupItem(
                    L("personas.redesign.none"),
                    identifier: "personas.defaultSelection",
                    in: window
                )
                #expect(model.defaultPersonaSelectionID == nil)
                #expect(model.auxiliaryPersonaID == fixture.custom.id.uuidString)
                #expect(model.personaDraftPrompt == "Unsaved definition")
            }
        }
    }

    @Test func `keyword disclosure actions keep row identities and sorted persisted state`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let fixture = try AskWorkflowFixture()
            let settings = fixture.settings
            let key = "ask.keywordCollapsedSections"
            for style in InterfaceStyle.allCases {
                settings.defaults.set(["system", "search"], forKey: key)
                let view = AskLauncherPluginSettingsView(settings: settings, workflows: fixture.store,
                                                         initialFilter: .translate)
                    .environment(\.interfaceStyle, style)
                try await SettingsBehaviorTestSupport.withWindow(view, width: 400, height: 600) { _, host in
                    let section = "ask.settings.keywords.section.translate"
                    let row = "ask.settings.keywords.row.fy"
                    try await SettingsBehaviorTestSupport.wait { regressionElements(row, in: host).count == 1 }
                    let headers = regressionElements(section, in: host)
                    #expect(headers.count == 1)
                    let firstHeader = headers.first
                    let header = try #require(firstHeader)
                    #expect(header.role == NSAccessibility.Role.button.rawValue)
                    #expect(regressionElements("ask.settings.keywords.edit.fy", in: host).count == 1)
                    try header.press()
                    try await SettingsBehaviorTestSupport.wait { regressionElements(row, in: host).isEmpty }
                    #expect(settings.defaults.stringArray(forKey: key) == ["search", "system", "translate"])
                }
                try await SettingsBehaviorTestSupport.withWindow(view, width: 400, height: 600) { _, host in
                    let section = "ask.settings.keywords.section.translate"
                    try await SettingsBehaviorTestSupport.wait {
                        !regressionElements(section, in: host).isEmpty
                            && regressionElements("ask.settings.keywords.row.fy", in: host).isEmpty
                    }
                    #expect(regressionElements("ask.settings.keywords.row.fy", in: host).isEmpty)
                    let matchingHeader = regressionElements(section, in: host).first
                    let header = try #require(matchingHeader)
                    try header.press()
                    try await SettingsBehaviorTestSupport.wait {
                        regressionElements("ask.settings.keywords.row.fy", in: host).count == 1
                    }
                    #expect(settings.defaults.stringArray(forKey: key) == ["search", "system"])
                }
            }
        }
    }

    @Test(arguments: [500.0, 650.0])
    func `long persona definitions leave native save and undo actions visible`(height: Double) async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            for style in InterfaceStyle.allCases {
                for creating in [false, true] {
                    let fixture = try PersonaLibraryFixture()
                    defer { fixture.cleanUp() }
                    let model = fixture.model
                    if creating {
                        model.beginCreatingPersona(name: "Long definition")
                    } else {
                        model.selectPersona(fixture.custom.id)
                    }
                    model.personaDraftPrompt = Array(repeating: "Keep the original meaning.", count: 80)
                        .joined(separator: "\n")
                    let view = StudioPersonaLibraryView(viewModel: model) { model.personaPendingDeletion = $0 }
                        .environment(\.interfaceStyle, style)
                    try await SettingsBehaviorTestSupport.withWindow(view, width: 950, height: height) { window, host in
                        try await SettingsBehaviorTestSupport.wait {
                            regressionElements("personas.saveDraft", in: host).count == 1
                        }
                        try verifyDefinition(model: model, in: host)
                        try await saveAndUndo(fixture, window: window, host: host)
                    }
                }
            }
        }
    }

    private func verifyDefinition(model: StudioViewModel, in host: NSView) throws {
        let matchingEditor = nativeDescendants(host).compactMap { $0 as? NSTextView }
            .first { $0.string == model.personaDraftPrompt }
        let editor = try #require(matchingEditor)
        let editorScroll = editor.enclosingScrollView
        let scroll = try #require(editorScroll)
        host.layoutSubtreeIfNeeded()
        let rect = host.convert(scroll.bounds, from: scroll)
        #expect(rect.height > 100)
        #expect(rect.minY >= 0 && rect.maxY <= host.bounds.height)
        #expect(editor.isEditable)
    }

    private func saveAndUndo(_ fixture: PersonaLibraryFixture, window: NSWindow, host: NSView) async throws {
        let model = fixture.model
        let expectedPrompt = model.personaDraftPrompt
        let matchingSave = regressionElements("personas.saveDraft", in: host).first
        let save = try #require(matchingSave)
        let bounds = window.convertToScreen(host.bounds)
        #expect(save.frame.height > 0 && bounds.contains(save.frame))
        try save.press()
        let savedPersona = model.selectedPersona
        let saved = try #require(savedPersona)
        #expect(!model.isCreatingPersonaDraft && !model.hasPersonaDraftChanges)
        #expect(fixture.store.personas.first { $0.id == saved.id }?.prompt == expectedPrompt)
        model.deletePersona(id: saved.id)
        try await SettingsBehaviorTestSupport.wait {
            regressionElements("personas.undoAction", in: host).count == 1
        }
        let matchingUndo = regressionElements("personas.undoAction", in: host).first
        let undo = try #require(matchingUndo)
        #expect(undo.frame.height > 0 && bounds.contains(undo.frame))
        try undo.press()
        #expect(model.personas.contains { $0.id == saved.id && $0.prompt == expectedPrompt })
    }

    private func regressionElements(_ identifier: String, in root: Any) -> [SettingsBehaviorTestSupport.Element] {
        SettingsBehaviorTestSupport.elements(in: root).filter {
            $0.value("accessibilityIdentifier") as? String == identifier
        }
    }

    private func nativeDescendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + nativeDescendants($0) }
    }
}
