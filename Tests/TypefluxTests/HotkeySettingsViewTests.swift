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
                    #expect(!elements.contains { $0.value("accessibilityIdentifier") as? String == "hotkeys.search" })
                    #expect(add.maxY < voice.minY)
                    #expect(add.minY > keyword.maxY)
                    #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.column.name"), in: window))
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

    @Test func `keyword templates open a preselected draft without saving on cancel`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { store in
            let viewModel = StudioViewModel(settingsStore: store, historyStore: SQLiteHistoryStore(
                baseDir: FileManager.default.temporaryDirectory.appendingPathComponent("hotkeys-template-\(UUID())")
            ), initialSection: .hotkeys)
            try await SettingsBehaviorTestSupport.withWindow(
                HotkeySettingsView(viewModel: viewModel, settingsStore: store, compact: true), width: 520, height: 980
            ) { window, _ in
                try await Task.sleep(for: .milliseconds(100))
                let elements = SettingsBehaviorTestSupport.elements(in: window)
                let containsTextField = elements.contains { $0.role == NSAccessibility.Role.textField.rawValue }
                #expect(!containsTextField)
                let templates = elements.filter {
                    ($0.value("accessibilityIdentifier") as? String ?? "").hasPrefix("hotkeys.keyword.template.")
                }
                #expect(templates.count == 3)
                let template = try #require(templates.first {
                    $0.value("accessibilityIdentifier") as? String == "hotkeys.keyword.template.rw"
                })
                #expect(template.frame.height >= 44)
                try template.press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.sheet.hint"), in: sheet)
                }
                let picker = try #require(SettingsBehaviorTestSupport.elements(in: sheet).first {
                    $0.value("accessibilityIdentifier") as? String == "hotkeys.keyword.sheet.keyword"
                })
                #expect(picker.text.contains("rw"))
                #expect(store.keywordHotkeys.isEmpty)
                try SettingsBehaviorTestSupport.button(L("hotkeys.keyword.sheet.record"), in: sheet).press()
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: sheet)
                }
                try SettingsBehaviorTestSupport.button(L("ask.workflow.cancel"), in: sheet).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
                #expect(store.keywordHotkeys.isEmpty)

                // Canceling a draft also releases its recorder before another row records.
                let keys = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                    $0.value("accessibilityIdentifier") as? String == "hotkeys.binding.builtIn.activation"
                })
                try keys.press()
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: window)
                }
                try keys.press()
            }
        }
    }

    @Test func `keyword edit ends row recording and preserves the shortcut on save`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { store in
            let shortcut = KeywordHotkey(binding: binding, keyword: "fy", pluginID: AskTranslatePlugin.id)
            store.keywordHotkeys = [shortcut]
            let viewModel = StudioViewModel(settingsStore: store, historyStore: SQLiteHistoryStore(
                baseDir: FileManager.default.temporaryDirectory.appendingPathComponent("hotkeys-edit-\(UUID())")
            ), initialSection: .hotkeys)
            try await SettingsBehaviorTestSupport.withWindow(
                HotkeySettingsView(viewModel: viewModel, settingsStore: store, compact: true), width: 520, height: 980
            ) { window, _ in
                @MainActor func control(_ identifier: String) throws -> SettingsBehaviorTestSupport.Element {
                    try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                        $0.value("accessibilityIdentifier") as? String == identifier
                    })
                }
                try await Task.sleep(for: .milliseconds(100))
                try control("hotkeys.binding.keyword." + shortcut.id.uuidString).press()
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: window)
                }
                try control("hotkeys.keyword.edit." + shortcut.id.uuidString).press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.sheet.hint"), in: sheet)
                }
                #expect(!SettingsBehaviorTestSupport.contains(L("hotkeys.recording"), in: window.contentView!))
                let save = try #require(SettingsBehaviorTestSupport.elements(in: sheet).first {
                    $0.value("accessibilityIdentifier") as? String == "hotkeys.keyword.sheet.save"
                })
                try save.press()
                try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
                #expect(store.keywordHotkeys == [shortcut])
            }
        }
    }

    @Test func `keyword editor renders concise guidance and conflicts`() async throws {
        let previous = AppLocalization.shared.language
        if ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] != nil {
            AppLocalization.shared.setLanguage(.simplifiedChinese)
        }
        defer { AppLocalization.shared.setLanguage(previous) }
        let name = "HotkeySettingsViewTests.sheet.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hotkey-sheet-\(UUID())")
        let model = HotkeySettingsModel(settingsStore: store, workflows: AskWorkflowStore(settings: store, root: root))
        let owner = KeywordHotkey(binding: binding, keyword: "fy", pluginID: AskTranslatePlugin.id)
        model.save(owner)
        try await render(KeywordHotkeyEditorSheet(model: model, draft: KeywordHotkeyDraft(adding: nil), onDone: {}),
                         size: NSSize(width: 480, height: 260), name: "hotkeys-sheet-add") { window in
            #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.sheet.choose"), in: window))
            #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.sheet.record"), in: window))
            let save = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                $0.value("accessibilityIdentifier") as? String == "hotkeys.keyword.sheet.save"
            })
            #expect(save.value("isAccessibilityEnabled") as? Bool == false)
        }
        let option = try #require(HotkeySettingsPresentation.templates(in: model.options).first)
        var draft = KeywordHotkeyDraft(adding: option)
        draft.record(binding)
        for light in [false, true] {
            try await render(KeywordHotkeyEditorSheet(model: model, draft: draft, onDone: {}),
                             size: NSSize(width: 480, height: 300), name: "hotkeys-sheet-\(light ? "light" : "dark")",
                             light: light) { window in
                #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.sheet.takeKeys"), in: window))
                #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.sheet.hint"), in: window))
            }
        }
        try await render(KeywordHotkeyEditorSheet(model: model, draft: KeywordHotkeyDraft(editing: owner), onDone: {}),
                         size: NSSize(width: 480, height: 300), name: "hotkeys-sheet-edit") { window in
            #expect(SettingsBehaviorTestSupport.contains(L("hotkeys.keyword.delete"), in: window))
        }
    }
}
