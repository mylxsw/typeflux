import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct HotkeySettingsViewTests {
    private let binding = HotkeyBinding(
        keyCode: 15,
        modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    )

    private func render(_ view: some View, size: NSSize, name: String, light: Bool = false,
                        check: (NSWindow) async throws -> Void = { _ in }) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(StudioTheme.windowBackground))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(180))
        hosting.layoutSubtreeIfNeeded()
        try await check(window)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    @Test func `shortcuts page lists every core feature and keyword shortcuts`() async throws {
        let previous = AppLocalization.shared.language
        let snapshots = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] != nil
        if snapshots {
            AppLocalization.shared.setLanguage(.simplifiedChinese)
        }
        defer {
            if snapshots {
                AppLocalization.shared.setLanguage(previous)
            }
        }
        let name = "HotkeySettingsViewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = AppLocalization.shared.language
        let model = StudioViewModel(settingsStore: store, historyStore: SQLiteHistoryStore(
            baseDir: FileManager.default.temporaryDirectory.appendingPathComponent("hotkeys-\(UUID())")
        ), initialSection: .hotkeys)

        for light in [false, true] {
            try await render(StudioView(viewModel: model), size: NSSize(width: 1100, height: 900),
                             name: "hotkeys-empty-\(light ? "light" : "dark")", light: light) { window in
                #expect(SettingsBehaviorTestSupport.contains(AppHotkeyAction.openChat.title, in: window))
                #expect(SettingsBehaviorTestSupport.contains(BuiltInHotkey.activation.title, in: window))
                #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.empty"), in: window))
            }
        }

        store.setHotkey(binding, for: .openChat)
        store.keywordHotkeys = [
            KeywordHotkey(
                binding: HotkeyBinding(
                    keyCode: 15,
                    modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.command).rawValue)
                ),
                keyword: "rw",
                pluginID: AskPromptPlugin.id
            ),
            KeywordHotkey(binding: HotkeyBinding(keyCode: 17, modifierFlags: binding.modifierFlags),
                          keyword: "gone", pluginID: "workflow.gone")
        ]
        for light in [false, true] {
            try await render(StudioView(viewModel: model), size: NSSize(width: 1100, height: 1000),
                             name: "hotkeys-page-\(light ? "light" : "dark")", light: light) { window in
                #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.status.missing"), in: window))
                #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.empty"), in: window))
            }
        }
    }

    @Test func `compact tables remove descriptions and keep columns aligned`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { store in
            let shortcut = KeywordHotkey(binding: binding, keyword: "fy", pluginID: AskTranslatePlugin.id)
            store.keywordHotkeys = [shortcut]
            let viewModel = StudioViewModel(settingsStore: store, historyStore: SQLiteHistoryStore(
                baseDir: FileManager.default.temporaryDirectory.appendingPathComponent("hotkeys-compact-\(UUID())")
            ), initialSection: .hotkeys)
            for width: CGFloat in [520, 820] {
                store.keywordHotkeys = [shortcut]
                try await render(HotkeySettingsView(viewModel: viewModel, settingsStore: store, compact: width < 720),
                                 size: NSSize(width: width, height: 1000),
                                 name: "hotkeys-table-\(Int(width))") { window in
                    let elements = SettingsBehaviorTestSupport.elements(in: window)
                    func element(_ identifier: String) throws -> SettingsBehaviorTestSupport.Element {
                        try #require(elements.first { $0.value("accessibilityIdentifier") as? String == identifier })
                    }
                    #expect(!SettingsBehaviorTestSupport.contains(L("studio.subheading.hotkeys"), in: window))
                    #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.builtIn.activation.subtitle"), in: window))
                    #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.action.openChat.subtitle"), in: window))
                    let voice = try element("hotkeys.row.builtIn.activation").frame
                    let keyword = try element("hotkeys.row.keyword." + shortcut.id.uuidString).frame
                    #expect(abs(voice.height - keyword.height) < 1)
                    let voiceKeys = try element("hotkeys.binding.builtIn.activation").frame
                    let keywordKeys = try element("hotkeys.binding.keyword." + shortcut.id.uuidString).frame
                    #expect(abs(voiceKeys.minX - keywordKeys.minX) < 1)
                    let auxiliaryKeys = try element("hotkeys.binding.builtIn.auxiliary").frame
                    let rowSpacing = abs(voiceKeys.midY - auxiliaryKeys.midY)
                    #expect(rowSpacing >= 44 && rowSpacing <= 46)
                    let add = try element("hotkeys.keyword.add").frame
                    let search = try element("hotkeys.search.toggle").frame
                    #expect(search.minY > voice.maxY)
                    #expect(add.maxY < voice.minY)
                    #expect(add.minY > keyword.maxY)
                    #expect(!elements.contains { $0.value("accessibilityIdentifier") as? String == "hotkeys.search" })
                    let toggle = try element("hotkeys.enabled." + shortcut.id.uuidString)
                    try toggle.press()
                    try await SettingsBehaviorTestSupport.wait { store.keywordHotkeys.first?.enabled == false }
                    let keys = try element("hotkeys.binding.builtIn.activation")
                    try keys.press()
                    try await SettingsBehaviorTestSupport.wait {
                        SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: window)
                    }
                    try keys.press()
                    try await SettingsBehaviorTestSupport.wait {
                        !SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: window)
                    }
                }
            }
        }
    }

    @Test func `title search expands focuses filters and clears on close`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { store in
            let viewModel = StudioViewModel(settingsStore: store, historyStore: SQLiteHistoryStore(
                baseDir: FileManager.default.temporaryDirectory.appendingPathComponent("hotkeys-search-\(UUID())")
            ), initialSection: .hotkeys)
            try await SettingsBehaviorTestSupport.withWindow(
                HotkeySettingsView(viewModel: viewModel, settingsStore: store, compact: true), width: 520, height: 980
            ) { window, _ in
                let originalBinding = store.hotkey(.activation)
                try SettingsBehaviorTestSupport.button(
                    L("hotkeys.recordAccessibility", BuiltInHotkey.activation.title), in: window
                ).press()
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: window)
                }
                try SettingsBehaviorTestSupport.button(L("hotkeys.search"), in: window).press()
                #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: window))
                try await SettingsBehaviorTestSupport.wait {
                    window.firstResponder is NSTextView
                }
                let editor = try #require(window.firstResponder as? NSTextView)
                editor.insertText("screenshot", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await SettingsBehaviorTestSupport.wait {
                    !SettingsBehaviorTestSupport.contains(BuiltInHotkey.activation.title, in: window)
                }
                #expect(SettingsBehaviorTestSupport.contains(BuiltInHotkey.screenshot.title, in: window))
                #expect(store.hotkey(.activation) == originalBinding)
                try SettingsBehaviorTestSupport.button(L("hotkeys.search.close"), in: window).press()
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(BuiltInHotkey.activation.title, in: window)
                }
                #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.search.close"), in: window))
                try SettingsBehaviorTestSupport.button(L("hotkeys.search"), in: window).press()
                try await SettingsBehaviorTestSupport.wait { window.firstResponder is NSTextView }
                let reopened = try #require(window.firstResponder as? NSTextView)
                #expect(reopened.string.isEmpty)
                reopened.insertText("unmatched-shortcut", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("hotkeys.noMatch", "unmatched-shortcut"), in: window)
                }
                let escape = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
                ))
                window.sendEvent(escape)
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(BuiltInHotkey.activation.title, in: window)
                }
            }
        }
    }

    @Test func `keyword editor renders conflicts and effect`() async throws {
        let name = "HotkeySettingsViewTests.sheet.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hotkey-sheet-\(UUID())")
        let model = HotkeySettingsModel(settingsStore: store, workflows: AskWorkflowStore(settings: store, root: root))
        let owner = KeywordHotkey(binding: binding, keyword: "fy", pluginID: AskTranslatePlugin.id)
        model.save(owner)
        let option = try #require(HotkeySettingsPresentation.templates(in: model.options).first)
        var draft = KeywordHotkeyDraft(adding: option)
        draft.record(binding)
        for light in [false, true] {
            try await render(KeywordHotkeyEditorSheet(model: model, draft: draft, onDone: {}),
                             size: NSSize(width: 540, height: 330), name: "hotkeys-sheet-\(light ? "light" : "dark")",
                             light: light) { window in
                #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.sheet.takeKeys"), in: window))
            }
        }
        try await render(KeywordHotkeyEditorSheet(model: model, draft: KeywordHotkeyDraft(editing: owner), onDone: {}),
                         size: NSSize(width: 540, height: 330), name: "hotkeys-sheet-edit") { window in
            #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.delete"), in: window))
        }
    }
}
