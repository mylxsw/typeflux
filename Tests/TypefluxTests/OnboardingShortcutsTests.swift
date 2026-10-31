import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingShortcutsTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `settings are live and rejected conflicts preserve the previous binding`() async throws {
        try await UI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let model = OnboardingShortcutsModel(session: session, systemReader: { .none })
            let candidate = HotkeyBinding(keyCode: 15, modifierFlags: NSEvent.ModifierFlags.option.rawValue)
            #expect(model.apply(candidate, to: .action(.translate), recorded: true))
            #expect(settings.actionHotkeys[.translate] == candidate)
            #expect(!model.apply(candidate, to: .builtIn(.screenshot), recorded: true))
            #expect(model.conflict(.builtIn(.screenshot)) != nil)
            #expect(settings.screenshotHotkey != candidate)
            #expect(!model.apply(.rightCommandActivation, to: .builtIn(.persona), recorded: true))
            let unmodified = HotkeyBinding(keyCode: 0, modifierFlags: 0)
            let accepted = model.apply(unmodified, to: .action(.translate), recorded: true)
            #expect(!accepted)
            #expect(settings.actionHotkeys[.translate] == candidate)
            #expect(model.errors[.action(.translate)] == OnboardingShortcutsModel.text("needsModifier"))
            #expect(model.apply(nil, to: .action(.translate)))
            #expect(settings.actionHotkeys[.translate] == nil)
            model.restore(.action(.translate))
            #expect(model.conflict(.action(.translate)) == nil)
            settings.askHotkey = .defaultHistory
            settings.historyHotkey = .defaultAsk
            settings.setHotkey(candidate, for: .openNotes)
            model.restoreAll()
            #expect(settings.actionHotkeys[.openNotes] == candidate)
            #expect(!model.apply(candidate, to: .action(.translate)))
            #expect(model.errors[.action(.translate)]?.contains(AppHotkeyAction.openNotes.title) == true)
            model.restore(.action(.translate))
            for key in BuiltInHotkey.allCases {
                #expect(settings.hotkey(key) == key.defaultBinding)
            }
            #expect(settings.actionHotkeys[.ring] == RingConfiguration.defaultHotkey)
            #expect(model.binding(.builtIn(.ask)) == .defaultAsk)
            session.currentStep = .shortcuts
            model.useDefaults()
            #expect(session.currentStep == .try)
        }
    }

    @Test func `presets move standard auxiliary chords and reject outside owners atomically`() async throws {
        try await UI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let model = OnboardingShortcutsModel(session: session, systemReader: { .none })
            model.restoreAll()
            model.preset(.rightCommand)
            #expect(settings.activationHotkey == .rightCommandActivation)
            #expect(settings.askHotkey == .rightCommandAsk)
            #expect(settings.auxiliaryHotkey?.signature == HotkeyBinding.auxiliaryChord(baseKeyCode: 54).signature)
            model.preset(.rightOption)
            #expect(settings.activationHotkey == .rightOptionActivation)
            #expect(settings.auxiliaryHotkey?.signature == HotkeyBinding.auxiliaryChord(baseKeyCode: 61).signature)
            model.preset(nil)
            #expect(settings.activationHotkey == .defaultActivation)
            #expect(settings.auxiliaryHotkey?.signature == HotkeyBinding.defaultAuxiliary.signature)
            settings.setHotkey(.rightCommandActivation, for: .ring)
            model.refresh()
            model.preset(.rightCommand)
            #expect(settings.activationHotkey == .defaultActivation)
            #expect(settings.askHotkey == .defaultAsk)
            #expect(model.errors[.builtIn(.activation)] != nil)
            settings.setHotkey(nil, for: .ring)
            settings.auxiliaryHotkey = nil
            model.preset(.rightOption)
            #expect(settings.auxiliaryHotkey == nil)
            let custom = HotkeyBinding(keyCode: 15, modifierFlags: NSEvent.ModifierFlags.option.rawValue)
            settings.auxiliaryHotkey = custom
            model.preset(.rightCommand)
            #expect(settings.auxiliaryHotkey == custom)
        }
    }

    @Test func `system conflicts refresh and alternatives respect every owner`() async throws {
        try await UI.withFixture { settings in
            var system = SystemSymbolicHotkeys(enabled: [.init(
                keyCode: 49,
                modifierFlags: NSEvent.ModifierFlags.command.rawValue
            )])
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let model = OnboardingShortcutsModel(session: session, systemReader: { system })
            settings.askHotkey = .init(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.command.rawValue)
            model.refresh()
            #expect(model.conflict(.builtIn(.ask))?.contains("Spotlight") == true)
            #expect(model.canOfferAlternative)
            settings.setHotkey(model.alternative, for: .translate)
            model.refresh()
            #expect(!model.canOfferAlternative)
            settings.setHotkey(nil, for: .translate)
            #expect(model.apply(model.alternative, to: .builtIn(.ask)))
            #expect(!model.canOfferAlternative)
            system = .none
            model.refresh()
            #expect(model.conflict(.builtIn(.ask)) == nil)
            session.isGlobeKeyReady = false
            settings.activationHotkey = .defaultActivation
            model.shortcuts.reload()
            #expect(model.isGlobeConflict(.builtIn(.activation)))
            #expect(!model.isGlobeConflict(.builtIn(.auxiliary)))
            settings.askHotkey = HotkeyBinding(keyCode: HotkeyBinding.functionKeyCode,
                                               modifierFlags: NSEvent.ModifierFlags.function.rawValue, pressCount: 2)
            model.shortcuts.reload()
            #expect(model.isGlobeConflict(.builtIn(.ask)))
            #expect(model.conflictCount > 0)
            model.startRecording(.action(.translate))
            #expect(model.isBusy && model.recordingTarget == .action(.translate))
            model.stopRecording()
            #expect(!model.recorder.isRecording && !model.isBusy && model.recordingTarget == nil)
        }
    }

    @Test func `recorded callbacks save and cancel without leaving a busy page`() async throws {
        try await UI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            var opened = false
            let model = OnboardingShortcutsModel(
                session: session,
                systemReader: { .none },
                openKeyboardSettings: { opened = true }
            )
            model.openGuide()
            #expect(opened && model.guideVisible)
            model.startRecording(.action(.translate))
            #expect(model.recorder.processRecordedEvent(eventType: .keyDown, keyCode: 15,
                                                        modifierFlags: NSEvent.ModifierFlags.option.rawValue,
                                                        isRepeat: false))
            #expect(settings.actionHotkeys[.translate]?.keyCode == 15)
            #expect(!model.isBusy)
            model.startRecording(.builtIn(.auxiliary))
            #expect(model.recorder.processRecordedEvent(
                eventType: .keyDown,
                keyCode: 53,
                modifierFlags: 0,
                isRepeat: false
            ))
            #expect(!model.isBusy && model.recordingTarget == nil)
            #expect(model.describe(.gesture) == OnboardingShortcutsModel.text("needsModifier"))
        }
    }

    @Test func `globe changes are reread on application activation`() async throws {
        try await UI.withFixture { settings in
            let reader = OnboardingShortcutsGlobeReader()
            let session = OnboardingViewModel(settingsStore: settings, globeKeyReader: reader, onComplete: {})
            session.currentStep = .shortcuts
            let model = session.shortcutsModel
            try await UI
                .withWindow(OnboardingView(viewModel: session, appearanceMode: .dark), width: 960,
                            height: 664) { _, _ in
                    #expect(model.isGlobeConflict(.builtIn(.activation)))
                    reader.usage = .doNothing
                    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                    #expect(!model.isGlobeConflict(.builtIn(.activation)))
                }
        }
    }

    @Test func `escape cancels either capture mode without saving`() {
        for auxiliary in [false, true] {
            let recorder = HotkeyRecorder()
            var cancelled = false
            var saved = false
            recorder.start(supportsAuxiliaryBindings: auxiliary, onCancel: { cancelled = true }) { _ in saved = true }
            #expect(recorder.processRecordedEvent(eventType: .keyDown, keyCode: 53, modifierFlags: 0, isRepeat: false))
            #expect(cancelled && !saved && !recorder.isRecording)
            recorder.stop()
        }
    }

    @Test func `preset checkmarks compare physical bindings rather than persisted identities`() async throws {
        try await UI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let model = OnboardingShortcutsModel(session: session, systemReader: { .none })
            for (index, preset) in [HotkeyBinding.defaultActivation, .rightCommandActivation, .rightOptionActivation]
                .enumerated() {
                settings.activationHotkey = HotkeyBinding(keyCode: preset.keyCode, modifierFlags: preset.modifierFlags)
                model.refresh()
                let actions = model.menuActions(.builtIn(.activation))
                for position in 0 ..< 3 {
                    guard case let .toggle(_, isOn, _, _) = actions[position] else {
                        Issue.record("Expected a voice preset toggle")
                        continue
                    }
                    #expect(isOn == (position == index))
                }
            }
        }
    }

    @Test func `menus expose presets and recording reset clear for every card`() async throws {
        try await UI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            let model = OnboardingShortcutsModel(session: session, systemReader: { .none })
            model.restoreAll()
            for target in OnboardingShortcutsModel.targets {
                let menu = TFMenuAction.entries(model.menuActions(target))
                #expect(menu.handlers.count == (target == .builtIn(.activation) ? 6 : 3))
                for handler in menu.handlers {
                    handler()
                }
                #expect(model.binding(target) == nil)
                #expect(!model.isBusy)
            }
        }
    }

    @Test func `card buttons record suggest reset and present the guide`() async throws {
        try await UI.withFixture { settings in
            let session = OnboardingViewModel(settingsStore: settings,
                                              globeKeyReader: OnboardingShortcutsGlobeReader(), onComplete: {})
            settings.askHotkey = .init(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.command.rawValue)
            var opened = false
            let model = OnboardingShortcutsModel(session: session, systemReader: {
                .init(enabled: [.init(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.command.rawValue)])
            }, openKeyboardSettings: { opened = true })
            let page = OnboardingShortcutsPage(viewModel: session, model: model)
            try await UI.withWindow(page, width: 960, height: 560) { _, host in
                try UI.button(OnboardingShortcutsModel.text("fix"), in: host).press()
                #expect(opened && model.guideVisible)
                try await UI.wait { UI.contains("×", in: host) }
                try UI.button("×", in: host).press()
                #expect(!model.guideVisible)
                try UI.button(OnboardingShortcutsModel.text("alternative"), in: host).press()
                #expect(settings.askHotkey?.signature == model.alternative.signature)
                try UI.button(OnboardingShortcutsModel.text("translate"), in: host).press()
                #expect(model.recordingTarget == .action(.translate))
                _ = model.recorder.processRecordedEvent(eventType: .keyDown, keyCode: 15,
                                                        modifierFlags: NSEvent.ModifierFlags.option.rawValue,
                                                        isRepeat: false)
                #expect(settings.actionHotkeys[.translate]?.keyCode == 15)
                try UI.button(OnboardingShortcutsModel.text("resetAll"), in: host).press()
                #expect(settings.actionHotkeys[.translate] == nil)
                #expect(settings.askHotkey == .defaultAsk)
            }
            session.currentStep = .shortcuts
            try await UI.withWindow(
                OnboardingView(viewModel: session, appearanceMode: .light),
                width: 960,
                height: 664
            ) { _, host in
                try UI.button(OnboardingShortcutsModel.text("useDefaults"), in: host).press()
                #expect(session.currentStep == .try)
            }
        }
    }

    @Test func `native menu capture includes its popup`() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_NATIVE_MENU_CAPTURE"] == "1" else { return }
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_GUL303_SNAPSHOTS"] else { return }
        try await UI.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(previousPolicy) }
            let session = OnboardingViewModel(settingsStore: settings, onComplete: {})
            session.currentStep = .shortcuts
            for language in [AppLanguage.english, .simplifiedChinese] {
                session.setLanguage(language)
                for dark in [false, true] {
                    let content = OnboardingView(viewModel: session, appearanceMode: dark ? .dark : .light)
                    try await UI.withWindow(content, width: 960, height: 664) { window, host in
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.titleVisibility = .hidden
                        window.titlebarAppearsTransparent = true
                        let screen = try #require(NSScreen.screens.first)
                        window.setFrameOrigin(NSPoint(
                            x: screen.visibleFrame.minX + max(0, (screen.visibleFrame.width - window.frame.width) / 2),
                            y: screen.visibleFrame.minY + max(0, (screen.visibleFrame.height - window.frame.height) / 2)
                        ))
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                        NSApp.activate(ignoringOtherApps: true)
                        try await Task.sleep(for: .milliseconds(200))
                        func buttons(_ view: NSView) -> [NSPopUpButton] {
                            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(buttons)
                        }
                        let button = try #require(buttons(host).first {
                            $0.accessibilityIdentifier() == "onboarding.shortcuts.activation"
                        })
                        let menu = try #require(button.menu)
                        let screenHeight = screen.frame.maxY
                        let frame = window.frame
                        let region = "\(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
                        print(
                            "Native menu capture: screen=\(screen.frame), window=\(frame), region=\(region), permission=\(CGPreflightScreenCaptureAccess())"
                        )
                        let path = URL(fileURLWithPath: directory).appendingPathComponent(
                            "shortcuts-menu-\(language.rawValue)-\(dark ? "dark" : "light").png"
                        )
                        try FileManager.default.createDirectory(
                            at: path.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        var captureStatus: Int32 = -1
                        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                defer { menu.cancelTracking() }
                                let process = Process()
                                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                process.arguments = ["-x", "-R", region, path.path]
                                do {
                                    try process.run()
                                    process.waitUntilExit()
                                    captureStatus = process.terminationStatus
                                } catch { captureStatus = -1 }
                            }
                        }
                        RunLoop.main.add(timer, forMode: .eventTracking)
                        RunLoop.main.add(timer, forMode: .common)
                        button.performClick(nil)
                        timer.invalidate()
                        #expect(captureStatus == 0)
                    }
                }
            }
        }
    }

    @Test func `shortcut states render in both appearances and languages`() async throws {
        try await UI.withFixture { settings in
            let reader = OnboardingShortcutsGlobeReader()
            let session = OnboardingViewModel(settingsStore: settings, globeKeyReader: reader, onComplete: {})
            session.currentStep = .shortcuts
            var system = SystemSymbolicHotkeys.none
            let model = OnboardingShortcutsModel(session: session, systemReader: { system })
            session.shortcutsModel = model
            for language in [AppLanguage.english, .simplifiedChinese] {
                session.setLanguage(language)
                for dark in [false, true] {
                    for state in [
                        "default",
                        "system",
                        "recording",
                        "internal",
                        "invalid",
                        "guide",
                        "guide-ready",
                        "ready"
                    ] {
                        system = state == "system"
                            ? .init(enabled: [.init(
                                keyCode: 49,
                                modifierFlags: NSEvent.ModifierFlags.command.rawValue
                            )])
                            : .none
                        reader.usage = state == "guide-ready" ? .doNothing : .showEmojiAndSymbols
                        model.restoreAll()
                        model.guideVisible = state.hasPrefix("guide")
                        if state == "system" {
                            settings.askHotkey = .init(
                                keyCode: 49,
                                modifierFlags: NSEvent.ModifierFlags.command.rawValue
                            )
                            model.refresh()
                        }
                        if state == "internal", let history = settings.historyHotkey {
                            model.apply(history, to: .builtIn(.screenshot))
                        }
                        if state == "invalid" {
                            model.apply(.init(keyCode: 0, modifierFlags: 0), to: .action(.translate), recorded: true)
                        }
                        if state == "ready" {
                            model.preset(.rightOption)
                        }
                        let content = OnboardingView(viewModel: session, appearanceMode: dark ? .dark : .light)
                        try await UI.withWindow(content, width: 960, height: 664) { _, host in
                            if state == "recording" {
                                model.startRecording(.action(.translate))
                            }
                            if state.hasPrefix("guide") {
                                model.guideVisible = true
                            }
                            try await Task.sleep(for: .milliseconds(200))
                            #expect(UI.contains(OnboardingShortcutsModel.text("title"), in: host))
                            try UI.snapshot(
                                host,
                                name: "shortcuts-\(state)-\(language.rawValue)-\(dark ? "dark" : "light")"
                            )
                            model.stopRecording()
                        }
                    }
                }
            }
        }
    }
}

private final class OnboardingShortcutsGlobeReader: GlobeKeyPreferenceReading {
    var usage: GlobeKeyUsage = .showEmojiAndSymbols
    func currentUsage() -> GlobeKeyUsage? {
        usage
    }
}
