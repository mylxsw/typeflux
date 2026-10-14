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

    @Test func `placement clamps to every screen and selection overrides preferences`() {
        let screen = CGRect(x: -1200, y: -500, width: 1000, height: 800)
        let size = CGSize(width: 452, height: 500)
        for position in AskTranslationPanelPosition.allCases {
            for mouse in [CGPoint(x: -99999, y: -99999), CGPoint(x: 99999, y: 99999)] {
                let frame = AskTranslationPanelPlacement.frame(size: size, screen: screen, position: position,
                                                               mouse: mouse, last: CGPoint(x: 99999, y: 99999))
                #expect(screen.contains(frame))
                let near = AskTranslationPanelPlacement.frame(size: size, screen: screen, position: position,
                                                              mouse: mouse, selection: CGRect(
                                                                  x: -1150,
                                                                  y: 250,
                                                                  width: 100,
                                                                  height: 20
                                                              ))
                #expect(near.minX == -1150 && near.maxY == 242)
            }
        }
        let above = AskTranslationPanelPlacement.frame(size: size, screen: screen, position: .center,
                                                       mouse: .zero, selection: CGRect(
                                                           x: -1150,
                                                           y: -450,
                                                           width: 30,
                                                           height: 20
                                                       ))
        #expect(above.minY == -422)
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
