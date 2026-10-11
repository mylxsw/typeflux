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
            try await render(StudioView(viewModel: model), size: NSSize(width: 1100, height: 1300),
                             name: "hotkeys-page-\(light ? "light" : "dark")", light: light) { window in
                #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.status.missing"), in: window))
                #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.empty"), in: window))
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
