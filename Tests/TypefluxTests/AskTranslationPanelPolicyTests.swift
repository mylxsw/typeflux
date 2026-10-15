import AppKit
import ApplicationServices
import Testing
@testable import Typeflux

@Suite("Translation panel policies", .exclusiveUIState)
@MainActor
struct AskTranslationPanelPolicyTests {
    @Test func `preferences round trip and P 1 data receives defaults`() throws {
        let old = Data(#"{"services":[{"id":"device","kind":{"device":{}},"enabled":true}]}"#.utf8)
        let decoded = try JSONDecoder().decode(AskTranslationSettings.self, from: old)
        #expect(decoded.panelPosition == .center && decoded.maxHeight == .eighty)
        #expect(decoded.autoCopy == .none && decoded.keepState == .minute)
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let editor = fixture.model.configuration
        editor.setPanelPreference(.mouse, at: \.panelPosition)
        editor.setPanelPreference(.sixty, at: \.maxHeight)
        editor.setPanelPreference(.third, at: \.autoCopy)
        editor.setPanelPreference(.forever, at: \.keepState)
        let settings = fixture.settings.askTranslationSettings
        #expect(try JSONDecoder().decode(AskTranslationSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(settings.normalized().autoCopy == .third)
        for preference in AskTranslationKeepState.allCases {
            #expect(!preference.title.isEmpty)
            #expect(preference.retains(dismissedAt: nil, now: fixture.time) == (preference == .forever))
        }
        for preference in AskTranslationPanelPosition.allCases {
            #expect(!preference.title.isEmpty)
        }
        for preference in AskTranslationPanelHeight.allCases {
            #expect(!preference.title.isEmpty)
        }
        for preference in AskTranslationAutoCopy.allCases {
            #expect(!preference.title.isEmpty)
        }
    }

    @Test func `placement clamps and every entry follows the selected position`() {
        let screen = CGRect(x: -1200, y: -500, width: 1000, height: 800)
        let size = CGSize(width: 700, height: 500)
        let mouse = CGPoint(x: -1000, y: 200)
        let last = CGPoint(x: -1150, y: -450)
        let center = AskTranslationPanelPlacement.frame(size: size, screen: screen, position: .center, mouse: mouse)
        #expect(center.midX == screen.midX && center.midY == screen.midY)
        let near = AskTranslationPanelPlacement.frame(size: size, screen: screen, position: .mouse, mouse: mouse)
        #expect(near.origin == CGPoint(x: mouse.x + 12, y: mouse.y - size.height - 12))
        let previous = AskTranslationPanelPlacement.frame(size: size, screen: screen, position: .lastPosition,
                                                          mouse: mouse, last: last)
        #expect(previous.origin == last)
        for position in AskTranslationPanelPosition.allCases {
            for point in [CGPoint(x: -99999, y: -99999), CGPoint(x: 99999, y: 99999)] {
                let frame = AskTranslationPanelPlacement.frame(size: size, screen: screen, position: position,
                                                               mouse: point, last: point)
                #expect(screen.contains(frame))
            }
        }
        let centered = AskTranslationPanelPlacement.frame(
            size: size,
            screen: screen,
            position: .lastPosition,
            mouse: .zero
        )
        #expect(centered.midX == screen.midX && centered.midY == screen.midY)
        let huge = AskTranslationPanelPlacement.frame(size: CGSize(width: 2000, height: 2000), screen: screen,
                                                      position: .center, mouse: .zero)
        #expect(huge == screen)
        for preference in AskTranslationPanelHeight.allCases {
            let actual = AskTranslationPanelPlacement.height(content: 2000, screen: screen, preference: preference)
            #expect(abs(actual - CGFloat(800 * preference.fraction)) < 0.001)
            #expect(AskTranslationPanelPlacement.height(content: 0, screen: screen, preference: preference) == 1)
        }
        var bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(AXTextInjector.appKitSelectionBounds(AXValueCreate(.cgRect, &bounds),
                                                     primaryScreenHeight: 1000) == CGRect(
                x: 10,
                y: 940,
                width: 30,
                height: 40
            ))
        #expect(AXTextInjector.appKitSelectionBounds(nil, primaryScreenHeight: 1000) == nil)
        #expect(AXTextInjector.appKitSelectionBounds("invalid" as CFString, primaryScreenHeight: 1000) == nil)
        var range = CFRange(location: 0, length: 3)
        #expect(AXTextInjector.appKitSelectionBounds(AXValueCreate(.cfRange, &range), primaryScreenHeight: 1000) == nil)
        bounds = .zero
        #expect(AXTextInjector.appKitSelectionBounds(AXValueCreate(.cgRect, &bounds), primaryScreenHeight: 1000) == nil)
        let injector = AXTextInjector()
        #expect(injector.selectionBounds(element: AXUIElementCreateSystemWide(), range: nil) == nil)
    }

    @Test func `complete keyboard table leaves IME editing keys to the editor`() {
        let expected: [(UInt16, NSEvent.ModifierFlags, AskTranslationPanelKeyCommand)] = [
            (36, [], .submit), (76, [], .submit), (53, [], .escape), (48, [], .language(1)),
            (48, .shift, .language(-1)), (35, .command, .pin), (51, .command, .clear),
            (126, .command, .move(-1)), (125, .command, .move(1)), (1, [.command, .shift], .swap),
            (15, .command, .action(.commandR)), (1, .command, .action(.commandS)),
            (11, .command, .action(.commandB)), (8, .command, .action(.commandC)),
            (8, [.command, .shift], .action(.shiftCommandC)), (36, .option, .action(.optionEnter)),
            (126, [], .history(-1)), (125, [], .history(1))
        ]
        for (key, modifiers, action) in expected {
            #expect(AskTranslationPanelKeyCommand.command(keyCode: key, modifiers: modifiers,
                                                          atStart: true, atEnd: true) == action)
        }
        for (key, number) in [(UInt16(18), 1), (19, 2), (20, 3), (21, 4), (23, 5), (22, 6), (26, 7), (28, 8), (25, 9)] {
            #expect(AskTranslationPanelKeyCommand.command(keyCode: key, modifiers: .command) == .copy(number))
        }
        #expect(AskTranslationPanelKeyCommand.command(keyCode: 36, modifiers: .shift) == nil)
        #expect(AskTranslationPanelKeyCommand.command(keyCode: 126, modifiers: []) == nil)
        #expect(AskTranslationPanelKeyCommand.command(keyCode: 125, modifiers: []) == nil)
        #expect(AskTranslationPanelKeyCommand.command(keyCode: 8, modifiers: .command, hasSelection: true) == nil)
        #expect(AskTranslationPanelKeyCommand
            .command(keyCode: 126, modifiers: [], atStart: true, hasSelection: true) == nil)
        #expect(AskTranslationPanelKeyCommand.command(keyCode: 0, modifiers: []) == nil)
        #expect(AskTranslationPanelKeyCommand.command(keyCode: 0, modifiers: .command) == nil)
        #expect(AskTranslationPanelKeyCommand.command(keyCode: 0, modifiers: [.command, .shift]) == nil)
    }

    @Test func `translation hotkeys start unset and share conflict checks and registration`() {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let shortcuts = HotkeySettingsModel(
            settingsStore: fixture.settings,
            workflows: AskWorkflowStore(
                settings: fixture.settings,
                root: fixture.directory.appendingPathComponent("workflows")
            )
        )
        let pool = SystemHotkeyPool(name: "translation panel test")
        defer { pool.unregisterAll() }
        for (index, action) in AppHotkeyAction.translation.enumerated() {
            let target = HotkeyTarget.action(action)
            #expect(shortcuts.row(for: target)?.binding == nil)
            #expect(shortcuts.row(for: target)?.group == .content)
            #expect(!HotkeySettingsPresentation.icon(of: action).isEmpty)
            let binding = HotkeyBinding(
                keyCode: 0 + index,
                modifierFlags: NSEvent.ModifierFlags.control.union([.option, .shift]).rawValue
            )
            #expect(shortcuts.setHotkey(binding, for: action) == nil)
            #expect(shortcuts.check(binding, for: .action(.openChat)).problem == .taken(target))
        }
        pool.register(fixture.settings.hotkeyAssignments.filter {
            if case .action = $0.key {
                true
            } else {
                false
            }
        })
        #expect(pool.registeredTargets == Set(AppHotkeyAction.translation.map(HotkeyTarget.action)))
        for action in AppHotkeyAction.translation {
            shortcuts.unsetHotkey(for: action)
        }
        #expect(fixture.settings.actionHotkeys.isEmpty)
    }
}

extension AskTranslationPanelPolicyTests {
    @Test(arguments: 0 ..< 8)
    func `translation shortcut migration preserves one owner and releases discarded keys`(
        combination: Int
    ) throws {
        let input = combination & 1 != 0
        let selection = combination & 2 != 0
        let current = combination & 4 != 0
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let inputBinding = HotkeyBinding(
            keyCode: 0,
            modifierFlags: NSEvent.ModifierFlags.control.union(.option).rawValue
        )
        let selectionBinding = HotkeyBinding(
            keyCode: 1,
            modifierFlags: NSEvent.ModifierFlags.control.union(.option).rawValue
        )
        let currentBinding = HotkeyBinding(
            keyCode: 2,
            modifierFlags: NSEvent.ModifierFlags.control.union(.option).rawValue
        )
        let screenshotBinding = HotkeyBinding(
            keyCode: 3,
            modifierFlags: NSEvent.ModifierFlags.control.union(.option).rawValue
        )
        var stored = ["screenshotTranslation": screenshotBinding]
        if input {
            stored["inputTranslation"] = inputBinding
        }
        if selection {
            stored["selectionTranslation"] = selectionBinding
        }
        if current {
            stored["translate"] = currentBinding
        }
        try fixture.defaults.set(JSONEncoder().encode(stored), forKey: "hotkey.actions.json")
        let migrated = SettingsStore(defaults: fixture.defaults)
        let expected = current ? currentBinding : selection ? selectionBinding : input ? inputBinding : nil
        #expect(migrated.actionHotkeys[.translate]?.signature == expected?.signature)
        #expect(migrated.actionHotkeys[.screenshotTranslation]?.signature == screenshotBinding.signature)
        let raw = try JSONDecoder().decode([String: HotkeyBinding].self,
                                           from: #require(fixture.defaults.data(forKey: "hotkey.actions.json")))
        #expect(raw["inputTranslation"] == nil && raw["selectionTranslation"] == nil)
        #expect(migrated.hotkeyAssignments[.action(.translate)]?.signature == expected?.signature)
        let rows = HotkeySettingsPresentation.rows(settingsStore: migrated, keywords: [])
        #expect(rows.filter { $0.target == .action(.translate) }.count == 1)
        if let expected {
            #expect(HotkeyConflictChecker.check(expected, for: .action(.openChat),
                                                among: migrated.hotkeyAssignments)
                    .problem == .taken(.action(.translate)))
            for discarded in [inputBinding, selectionBinding] where discarded.signature != expected.signature {
                #expect(HotkeyConflictChecker.check(discarded, for: .action(.openChat),
                                                    among: migrated.hotkeyAssignments).canSave)
            }
        }
        migrated.setHotkey(nil, for: .translate)
        #expect(SettingsStore(defaults: fixture.defaults).actionHotkeys[.translate] == nil)
    }

    @Test func `resizing remembers a viewport limit while short content fits and screens cap it`() {
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 1000)
        #expect(AskTranslationPanelPlacement.size(content: 400, screen: screen, preference: .eighty)
            == CGSize(width: AskTranslationPanelPlacement.width, height: 400))
        #expect(AskTranslationPanelPlacement.size(content: 2000, screen: screen, preference: .eighty,
                                                  remembered: CGSize(width: 820, height: 600))
                == CGSize(width: 820, height: 600))
        #expect(AskTranslationPanelPlacement.size(content: 350, screen: screen, preference: .eighty,
                                                  remembered: CGSize(width: 820, height: 600)).height == 350)
        #expect(AskTranslationPanelPlacement.size(content: 0, screen: screen, preference: .eighty,
                                                  remembered: .zero) == AskTranslationPanelPlacement.minimumSize)
        #expect(AskTranslationPanelPlacement.size(content: 2000, screen: screen, preference: .sixty,
                                                  remembered: CGSize(width: 2000, height: 2000))
                == CGSize(width: 1400, height: 600))
        #expect(AskTranslationPanelPlacement.size(content: 500, screen: screen, preference: .full,
                                                  remembered: CGSize(width: CGFloat.nan, height: CGFloat.infinity))
                == CGSize(width: AskTranslationPanelPlacement.width, height: 500))
        let small = CGRect(x: -600, y: -400, width: 400, height: 200)
        #expect(AskTranslationPanelPlacement.size(content: 900, screen: small, preference: .full) == small.size)
        for style in InterfaceStyle.allCases {
            for contrast in [false, true] {
                let chrome = AskTranslationAppearance.chrome(style: style, increasedContrast: contrast)
                #expect(chrome.corner == AskComposerChrome.launcher.corner)
                #expect(chrome.editorFontSize == AskComposerChrome.launcher.editorFontSize)
                #expect(chrome.idleBorder == (!style.usesGlass && !contrast
                        ? AskClassic.launcherBorder : AskComposerChrome.launcher.idleBorder))
            }
        }
    }
}
