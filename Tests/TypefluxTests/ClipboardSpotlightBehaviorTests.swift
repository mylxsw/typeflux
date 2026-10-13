import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ClipboardSpotlightBehaviorTests {
    @Test func contentModesCoverEveryKindAndKeepSnippetsSeparate() {
        let kinds: [ClipboardEntryKind] = [.voice, .text, .code, .link, .image, .images,
                                           .pdf, .document, .video, .audio, .files]
        let entries = kinds.map { ClipboardTestSupport.entry($0) }
        var snippet = ClipboardTestSupport.entry(.text, text: "Permanent text")
        snippet.snippet = ClipboardSnippet(name: "Signature", alias: "signature")
        let all = entries + [snippet]
        let expected: [(ClipboardCategory, [ClipboardEntryKind])] = [
            (.all, kinds), (.text, [.voice, .text, .code]), (.image, [.image, .images]),
            (.link, [.link]), (.snippet, [.text])
        ]
        for (category, matching) in expected {
            let filtered = ClipboardFeed.filter(all, category: category, query: "")
            #expect(filtered.map(\.kind) == matching)
            #expect(filtered.allSatisfy { ($0.snippet != nil) == (category == .snippet) })
            #expect(category.spotlightMode.id == category.rawValue)
            #expect(!category.spotlightMode.title.hasPrefix("clipboard."))
            #expect(!category.spotlightMode.systemImage.isEmpty)
        }
        #expect(ClipboardCategory.allCases.map(\.rawValue) == ["all", "text", "image", "link", "snippet"])
    }

    @Test func modesComposeWithQueryAndSourceFilter() {
        let notes = ClipboardTestSupport.entry(.text, text: "Quarterly report", sourceBundleID: "notes")
        let code = ClipboardTestSupport.entry(.code, text: "let report = 1", sourceBundleID: "notes")
        let link = ClipboardTestSupport.entry(.link, text: "https://example.com/report", sourceBundleID: "notes")
        let other = ClipboardTestSupport.entry(.text, text: "Quarterly report", sourceBundleID: "other")
        let entries = [notes, code, link, other]
        #expect(ClipboardFeed.filter(entries, category: .text, query: " REPORT ",
                                    sourceBundleID: "notes").map(\.id) == [notes.id, code.id])
        #expect(ClipboardFeed.filter(entries, category: .link, query: "report",
                                    sourceBundleID: "notes").map(\.id) == [link.id])
        #expect(ClipboardFeed.filter(entries, category: .image, query: "").isEmpty)
        #expect(ClipboardFeed.filter(entries, category: .all, query: "absent").isEmpty)
        #expect(ClipboardFeed.filter([], category: .snippet, query: "").isEmpty)
    }

    @Test func changingModeResetsViewportSelectionAndPreviewBeforeQuickPaste() {
        let model = ClipboardPanelModel()
        let texts = (1 ... 20).map { ClipboardTestSupport.entry(.text, text: "Text \($0)") }
        let image = ClipboardTestSupport.entry(.image, imagePath: "/fixture.png")
        model.fileExists = { _ in true }
        model.previewDelay = 0
        model.showsPreview = true
        model.reset(entries: texts + [image])
        model.select(index: 12)
        model.updateFirstVisibleIndex(10)
        let scrollRequest = model.scrollToTopRequest
        model.category = .image
        #expect(model.selectedIndex == 0 && model.firstVisibleIndex == 0)
        #expect(model.scrollToTopRequest > scrollRequest)
        #expect(model.selectedEntry?.id == image.id && model.previewEntry?.id == image.id)
        var actions: [ClipboardEntryAction] = []
        model.onAction = { action, entry in
            actions.append(action)
            #expect(entry.id == image.id)
        }
        model.quickPaste(number: 1)
        model.quickPaste(number: 2)
        #expect(actions == [.paste])
        model.query = "absent"
        #expect(model.selectedEntry == nil && model.previewEntry == nil)
        model.quickPaste(number: 1)
        #expect(actions == [.paste])
    }

    @Test func nativeSearchAndModeButtonsUseExistingKeyboardAndNonactivatingPanel() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            let model = ClipboardPanelModel()
            let text = ClipboardTestSupport.entry(.text, text: "Text match")
            let link = ClipboardTestSupport.entry(.link, text: "https://example.com")
            model.reset(entries: [text, link])
            let controller = ClipboardPanelController(settingsStore: settings)
            var ownedWindow: NSWindow?
            defer {
                controller.dismiss()
                if let ownedWindow { TypefluxNavigationTestSupport.closeWindow(ownedWindow) }
            }
            var actions: [ClipboardEntryAction] = []
            var dismissed = 0
            model.onAction = { action, _ in actions.append(action) }
            model.onDismiss = { dismissed += 1 }
            for style in InterfaceStyle.allCases {
                settings.interfaceStyle = style
                controller.present(model)
                let window = try #require(controller.presentedWindow)
                ownedWindow = window
                let host = try #require(window.contentView)
                #expect(window.canBecomeKey && !window.canBecomeMain && window.styleMask.contains(.nonactivatingPanel))
                #expect(NSApp.activationPolicy() == previousPolicy)
                let field = try await focusSearch(in: host, window: window, after: "opening \(style)")
                #expect(field.accessibilityLabel() == L("clipboard.search.placeholder"))
                #expect(field.frame.width > 0)
                try verifyModeButtons(in: host)
                _ = try await selectMode(.link, model: model, window: window, host: host)
                #expect(model.visibleEntries.map(\.id) == [link.id])
                let search = try await selectMode(.text, model: model, window: window, host: host)
                try TypefluxNavigationTestSupport.changeText("match", in: search)
                try await TypefluxNavigationTestSupport.wait("search binding propagates 'match' in \(style)",
                    in: window, host: host, diagnostics: { "modelQuery=\(model.query.debugDescription)" },
                    until: { model.query == "match" })
                #expect(model.visibleEntries.map(\.id) == [text.id])
                _ = try await selectMode(.text, model: model, window: window, host: host)
                #expect(model.query == "match")
                try verifyPasteShortcuts(window: window, controller: controller, actions: { actions })
                #expect(try press(53, window: window, controller: controller))
                #expect(model.query.isEmpty && dismissed == 0)
                model.category = .all
                controller.dismiss()
            }
            controller.present(model)
            let window = try #require(controller.presentedWindow)
            #expect(try press(53, window: window, controller: controller))
            #expect(dismissed == 1)
        }
    }

    @Test func editorsRetainDraftsAndReturnSearchFocusOnCancel() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = ClipboardPanelModel()
            model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Original")])
            let controller = ClipboardPanelController(settingsStore: settings)
            controller.present(model)
            let window = try #require(controller.presentedWindow)
            defer {
                controller.dismiss()
                TypefluxNavigationTestSupport.closeWindow(window)
            }
            let host = try #require(window.contentView)
            model.perform(.saveSnippet)
            try await TypefluxNavigationTestSupport.wait("snippet Save control is rendered", in: window, host: host) {
                SettingsBehaviorTestSupport.contains(L("clipboard.snippet.save"), in: host)
            }
            let save = try SettingsBehaviorTestSupport.button(L("clipboard.snippet.save"), in: host)
            #expect(save.value("accessibilityIdentifier") as? String == "snippet.save")
            try await focusModal(.saveSnippet, in: host, window: window)
            // SwiftUI owns this action; its AX proxy has no native target/action sender.
            model.commitSnippet()
            try await TypefluxNavigationTestSupport.wait("empty snippet name produces a validation error",
                in: window, host: host) { model.snippetError != nil }
            #expect(model.snippetDraft?.text == "Original")
            #expect(try press(36, window: window, controller: controller) == false)
            #expect(try press(53, window: window, controller: controller))
            try await focusSearch(in: host, window: window, after: "cancelling invalid snippet")
            model.perform(.editBeforePaste)
            try await focusModal(.editBeforePaste, in: host, window: window)
            #expect(try press(36, window: window, controller: controller) == false)
            #expect(model.editingText == "Original")
            #expect(try press(53, window: window, controller: controller))
            try await focusSearch(in: host, window: window, after: "cancelling edit-before-paste")
        }
    }

    @Test func inputMethodCompositionKeepsNavigationReturnAndEscape() throws {
        let suite = "ClipboardSpotlightIME-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ClipboardPanelModel()
        model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Original")])
        let controller = ClipboardPanelController(settingsStore: SettingsStore(defaults: defaults))
        controller.present(model)
        defer { controller.dismiss() }
        let window = try #require(controller.presentedWindow)
        let editor = NSTextView(frame: .zero)
        window.contentView?.addSubview(editor)
        defer { editor.removeFromSuperview() }
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        for code: UInt16 in [123, 124, 125, 126, 36, 53] {
            #expect(try press(code, window: window, controller: controller) == false)
        }
        model.perform(.saveSnippet)
        #expect(try press(53, window: window, controller: controller) == false)
        #expect(model.snippetDraft != nil)
        editor.unmarkText()
        #expect(try press(53, window: window, controller: controller))
        #expect(model.snippetDraft == nil)
    }

    @Test func sheetConfirmationUsesCommandReturnAndKeepsItsIdentifier() async throws {
        var confirmed = 0
        var cancelled = 0
        let view = TypefluxSheet(title: "Edit", cancelTitle: "Cancel", confirmTitle: "Save",
                                 confirmIdentifier: "snippet.save",
                                 confirmShortcut: KeyboardShortcut(.return, modifiers: .command),
                                 cancel: { cancelled += 1 }, confirm: { confirmed += 1 },
                                 content: { Text("Draft content") })
        try await TypefluxNavigationTestSupport.withWindow(view) { window, host in
            let button = try SettingsBehaviorTestSupport.button("Save", in: host)
            #expect(button.value("accessibilityIdentifier") as? String == "snippet.save")
            try TypefluxNavigationTestSupport.sendKey(36, to: window, keyEquivalent: true)
            #expect(confirmed == 0)
            try TypefluxNavigationTestSupport.sendKey(36, modifiers: .command, to: window, keyEquivalent: true)
            #expect(confirmed == 1)
            try TypefluxNavigationTestSupport.sendKey(53, to: window, keyEquivalent: true)
            #expect(cancelled == 1)
        }
    }

    @Test func accessibilityFallbacksRemoveGlassEvenWithAMaterialOverride() async throws {
        let model = ClipboardPanelModel()
        model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Readable result")])
        for reduced in [false, true] {
            let view = ClipboardPanelView(model: model, focusRequest: 0)
                .environment(\.interfaceStyle, .liquidGlass)
                .environment(\.typefluxAccessibilityOptions,
                             TypefluxAccessibilityOptions(reduceTransparency: reduced, increasedContrast: !reduced))
                .environment(\.glassMaterialOverride, .liquidGlass)
            try await TypefluxNavigationTestSupport.withWindow(view) { _, host in
                #expect(!descendants(host).contains {
                    $0 is NSVisualEffectView || NSStringFromClass(type(of: $0)).contains("NSGlassEffectView")
                })
            }
        }
    }

    @Test func panelOwnedSheetKeysDoNotRegisterCompetingShortcuts() async throws {
        var actions = 0
        let view = TypefluxSheet(title: "Edit", cancelTitle: "Cancel", confirmTitle: "Save",
                                 cancelShortcut: nil, confirmShortcut: nil,
                                 cancel: { actions += 1 }, confirm: { actions += 1 },
                                 content: { Text("Draft content") })
        try await TypefluxNavigationTestSupport.withWindow(view) { window, _ in
            try TypefluxNavigationTestSupport.sendKey(36, to: window, keyEquivalent: true)
            try TypefluxNavigationTestSupport.sendKey(36, modifiers: .command, to: window, keyEquivalent: true)
            try TypefluxNavigationTestSupport.sendKey(53, to: window, keyEquivalent: true)
            #expect(actions == 0)
        }
    }

}

extension ClipboardSpotlightBehaviorTests {
    @Test func repeatedModalCancellationRestoresTheSameSearchFieldAndQuery() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            let model = ClipboardPanelModel()
            model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Original")])
            let controller = ClipboardPanelController(settingsStore: settings)
            var ownedWindow: NSWindow?
            defer {
                controller.dismiss()
                if let ownedWindow { TypefluxNavigationTestSupport.closeWindow(ownedWindow) }
            }
            for style in InterfaceStyle.allCases {
                settings.interfaceStyle = style
                controller.present(model)
                let window = try #require(controller.presentedWindow)
                ownedWindow = window
                let host = try #require(window.contentView)
                #expect(window.canBecomeKey && window.styleMask.contains(.nonactivatingPanel))
                let field = try await focusSearch(in: host, window: window, after: "opening \(style)")
                try TypefluxNavigationTestSupport.changeText("Orig", in: field)
                try await TypefluxNavigationTestSupport.wait("search binding propagates 'Orig' in \(style)",
                    in: window, host: host, diagnostics: { "modelQuery=\(model.query.debugDescription)" },
                    until: { model.query == "Orig" })
                for action in [ClipboardEntryAction.saveSnippet, .editBeforePaste, .saveSnippet, .editBeforePaste] {
                    model.perform(action)
                    try await focusModal(action, in: host, window: window)
                    #expect(try press(53, window: window, controller: controller))
                    try await TypefluxNavigationTestSupport.wait("Escape clears \(action) in \(style)",
                        in: window, host: host,
                        diagnostics: { "snippet=\(model.snippetDraft != nil), edit=\(model.editingText != nil)" },
                        until: { model.snippetDraft == nil && model.editingText == nil })
                    let restored = try await focusSearch(in: host, window: window, after: "cancelling \(action) in \(style)")
                    #expect(restored === field)
                    #expect(model.query == "Orig" && field.stringValue == "Orig")
                    #expect(NSApp.activationPolicy() == previousPolicy)
                }
                model.query = ""
                controller.dismiss()
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func verifyModeButtons(in host: NSView) throws {
        for category in ClipboardCategory.allCases {
            let button = try SettingsBehaviorTestSupport.button(category.title, in: host)
            #expect(button.frame.width > 0)
        }
    }

    private func selectMode(_ category: ClipboardCategory, model: ClipboardPanelModel,
                            window: NSWindow, host: NSView) async throws -> NSSearchField {
        // Exercise the same binding setter as the SwiftUI mode button without AX press tracking.
        model.category = category
        #expect(model.category == category)
        // Style changes can replace native views; resolve the field from the presented panel each time.
        return try await focusSearch(in: host, window: window, after: "selecting mode \(category.rawValue)")
    }

    @discardableResult
    private func focusSearch(in host: NSView, window: NSWindow, after context: String) async throws -> NSSearchField {
        try await TypefluxNavigationTestSupport.wait("native search field without a modal editor after \(context)",
            in: window, host: host) {
            TypefluxNavigationTestSupport.searchField(in: host) != nil && modalTarget(in: host) == nil
        }
        host.layoutSubtreeIfNeeded()
        let field = try #require(TypefluxNavigationTestSupport.searchField(in: host,
                                                                         identifier: "typeflux.spotlight.search"))
        try TypefluxNavigationTestSupport.focus(field, in: window)
        return field
    }

    private func focusModal(_ action: ClipboardEntryAction, in host: NSView, window: NSWindow) async throws {
        func target() -> NSView? {
            modalTarget(in: host, snippet: action == .saveSnippet)
        }
        try await TypefluxNavigationTestSupport.wait("native \(action) editor is mounted", in: window, host: host) {
            target() != nil
        }
        try TypefluxNavigationTestSupport.focus(#require(target()), in: window)
    }

    private func modalTarget(in host: NSView, snippet: Bool? = nil) -> NSView? {
        let views = TypefluxNavigationTestSupport.descendants(of: host)
        let name: NSView? = views.compactMap { $0 as? NSTextField }.first { $0.isEditable && !($0 is NSSearchField) }
        if snippet == true { return name }
        let text: NSView? = views.compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor }
        return snippet == false ? (name == nil ? text : nil) : (name ?? text)
    }

    private func verifyPasteShortcuts(window: NSWindow, controller: ClipboardPanelController,
                                      actions: () -> [ClipboardEntryAction]) throws {
        #expect(try press(36, window: window, controller: controller))
        #expect(try press(36, modifiers: .command, window: window, controller: controller))
        #expect(try press(18, characters: "1", modifiers: .command, window: window, controller: controller))
        #expect(Array(actions().suffix(3)) == [.paste, .pastePlainText, .paste])
    }

    private func press(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                       window: NSWindow, controller: ClipboardPanelController) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: code))
        return controller.handleKeyDown(event)
    }
}
