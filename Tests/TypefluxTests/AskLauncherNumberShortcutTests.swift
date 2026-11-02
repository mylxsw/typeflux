import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher number hints", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherNumberShortcutTests {
    @Test func chatActionUsesIntentionalInputAndShowsTheMatchingShortcut() {
        let empty = AskDraft(text: " \n ", screenshot: "captured", selection: "Automatic selection", source: "Safari")
        #expect(AskLauncherChatAction.resolve(draft: empty) == .openChat)
        #expect(AskLauncherChatAction.openChat.shortcut == "O")
        #expect(AskLauncherChatAction.resolve(draft: AskDraft(text: "ss")) == .askAI)
        let attached = AskDraft(attachments: [AskAttachment(kind: .file, name: "notes.txt", text: "Notes")])
        #expect(AskLauncherChatAction.resolve(draft: attached) == .askAI)
        #expect(AskLauncherChatAction.resolve(draft: empty, pluginOffersAskAI: true) == .askAI)
        #expect(AskLauncherChatAction.resolve(draft: empty, loadingAttachments: true) == .askAI)
        #expect(AskLauncherChatAction.askAI.shortcut == "↩")
        #expect(AskLauncherChatAction.askAI.hint.contains("⌘↩"))
    }

    @Test func numbersRequireCommandAloneAndStopAtNine() {
        typealias Shortcuts = AskLauncherNumberShortcuts
        for (index, code) in [UInt16(18), 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            #expect(Shortcuts.number(at: index) == index + 1)
            #expect(Shortcuts.number(keyCode: code, modifiers: .command, characters: String(index + 1)) == index + 1)
            #expect(Shortcuts.number(keyCode: code, modifiers: .command, characters: nil) == index + 1)
            let otherModifiers: [NSEvent.ModifierFlags] = [[], .shift, [.command, .shift], [.command, .option], [.command, .control]]
            for flags in otherModifiers {
                #expect(Shortcuts.number(keyCode: code, modifiers: flags, characters: String(index + 1)) == nil)
            }
        }
        #expect(Shortcuts.number(at: -1) == nil)
        #expect(Shortcuts.number(at: 9) == nil)
        #expect(Shortcuts.number(keyCode: 29, modifiers: .command, characters: "0") == nil)
        #expect(Shortcuts.number(keyCode: 18, modifiers: .command, characters: "!") == nil)
        #expect(Shortcuts.number(keyCode: 92, modifiers: [.command, .numericPad], characters: "9") == 9)
    }

    @Test func hintsFollowReleaseExtraModifiersAndWindowFocus() {
        let monitor = AskLauncherCommandMonitor.MonitorView()
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        monitor.update(modifiers: .command, isKeyWindow: true)
        monitor.update(modifiers: .command, isKeyWindow: true)
        #expect(changes == [true])
        monitor.update(modifiers: [], isKeyWindow: true)
        monitor.update(modifiers: .command, isKeyWindow: true)
        monitor.update(modifiers: [.command, .shift], isKeyWindow: true)
        monitor.update(modifiers: .command, isKeyWindow: true)
        monitor.update(modifiers: .command, isKeyWindow: false)
        #expect(changes == [true, false, true, false, true, false])
        monitor.update(modifiers: .command, isKeyWindow: true)
        monitor.stop()
        #expect(!monitor.showing)
        #expect(changes.last == false)
    }

    @Test func consumedRingReleaseClearsHintsWithoutAnAppKitEvent() {
        let monitor = AskLauncherCommandMonitor.MonitorView()
        var session: NSEvent.ModifierFlags = []
        monitor.readModifiers = { _ in session }
        defer { monitor.stop() }

        // Opening Chat after Ring must not inherit cached Command flags.
        monitor.refresh(isKeyWindow: true)
        #expect(!monitor.showing)
        session = .command
        monitor.refresh(isKeyWindow: true)
        #expect(monitor.showing)
        session = []
        monitor.refresh(isKeyWindow: true)
        #expect(!monitor.showing)
        session = [.command, .shift]
        monitor.refresh(isKeyWindow: true)
        #expect(!monitor.showing)
        session = .command
        monitor.refresh(isKeyWindow: false)
        #expect(!monitor.showing)
    }

    @Test func visibleHintsRecheckSessionReleaseOnTimer() async throws {
        let monitor = AskLauncherCommandMonitor.MonitorView()
        var sessionReads = 0
        monitor.readModifiers = { _ in
            sessionReads += 1
            return []
        }
        defer { monitor.stop() }
        monitor.update(modifiers: .command, isKeyWindow: true)
        #expect(monitor.showing)
        try await Task.sleep(for: .milliseconds(250))
        #expect(sessionReads > 0)
        #expect(!monitor.showing)
    }

    @Test func hintsFollowTheSessionWhenRemoteInputAndHardwareDisagree() {
        let monitor = AskLauncherCommandMonitor.MonitorView()
        defer { monitor.stop() }
        let cases: [(NSEvent.ModifierFlags, NSEvent.ModifierFlags, Bool)] = [
            ([], [], false),
            (.command, [], false), // Remote release must override a held local hardware key.
            ([], .command, true), // Remote Command must work without a local hardware press.
            (.command, .command, true),
            ([.command, .shift], .command, true),
            (.command, [.command, .option], false),
            (.command, [.command, .control], false),
            (.command, [.command, .shift], false)
        ]
        for (hardware, session, expected) in cases {
            monitor.readModifiers = { source in
                source == .hidSystemState ? hardware : session
            }
            monitor.refresh(isKeyWindow: true)
            #expect(monitor.showing == expected)
        }
    }

    @Test func remoteReleaseClearsHintsOnTimerWithoutALocalAppKitEvent() async throws {
        let monitor = AskLauncherCommandMonitor.MonitorView()
        var session: NSEvent.ModifierFlags = .command
        var changes: [Bool] = []
        monitor.readModifiers = { source in
            source == .hidSystemState ? .command : session
        }
        monitor.onChange = { changes.append($0) }
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = monitor
        window.makeKeyAndOrderFront(nil)
        defer { monitor.stop(); window.close() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.isKeyWindow)
        #expect(monitor.showing)
        session = []
        try await Task.sleep(for: .milliseconds(250))
        #expect(!monitor.showing)
        #expect(changes == [true, false])
    }

    @Test(arguments: [AskLauncherChatAction.openChat, .askAI, .execute("Open Notes")])
    func chatActionHintRendersInBothThemesAndCompactLayouts(mode: AskLauncherChatAction) async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer {
            AppLocalization.shared.setLanguage(previousLanguage)
        }
        let directory = ProcessInfo.processInfo.environment["TYPEFLUX_NUMBER_SNAPSHOTS"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [640, 440] {
                let size = NSSize(width: width, height: 50)
                var renders: [Data] = []
                for visible in [false, true] {
                    let hosting = NSHostingView(rootView:
                        HStack {
                            Spacer(minLength: 0)
                            AskLauncherOpenChatButton(mode: mode, enabled: true, action: {})
                        }
                            .padding(.horizontal, 14)
                            .frame(height: 50)
                            .environment(\.askLauncherNumberHints, visible)
                            .background(AskTheme.composerSurface)
                    )
                    let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                                    styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = hosting
                    window.orderFront(nil)
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(100))
                    hosting.layoutSubtreeIfNeeded()
                    #expect(hosting.frame.size == size)
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    renders.append(png)
                    if let directory {
                        let theme = appearance == .aqua ? "light" : "dark"
                        try png.write(to: URL(fileURLWithPath: directory)
                            .appendingPathComponent("chat-\(mode)-\(Int(width))-\(theme)-\(visible ? "held" : "idle").png"))
                    }
                }
                if mode.shortcut == nil {
                    #expect(renders[0] == renders[1],
                            "An execution button must not claim the Command-Return AI shortcut")
                } else {
                    #expect(renders[0] != renders[1], "The chat shortcut must appear while Command is held")
                }
            }
        }
    }

    @Test func numberBadgesRenderWithoutChangingTheListSize() async throws {
        let apps = ["Calendar", "Calculator", "Contacts"].map {
            AskAppMatch(entry: AskTestAppIndex.app($0), score: 0.9)
        }
        let results = AskQuickResults(apps: apps, lead: true)
        let size = NSSize(width: AskMetrics.launcherWidth, height: AskQuickResultsView.height(for: results))
        let directory = ProcessInfo.processInfo.environment["TYPEFLUX_NUMBER_SNAPSHOTS"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var renders: [Data] = []
            for visible in [false, true] {
                let view = AskQuickResultsView(results: results, question: "cal", actions: nil,
                                               thumbnails: false, onRun: { _, _ in }, onHighlight: { _ in })
                    .environment(\.askLauncherNumberHints, visible)
                    .background(AskTheme.composerSurface)
                let hosting = NSHostingView(rootView: view)
                let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                                styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(80))
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.frame.size == size)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                renders.append(png)
                if let directory {
                    let theme = appearance == .aqua ? "light" : "dark"
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(theme)-\(visible ? "held" : "idle").png"))
                }
            }
            #expect(renders[0] != renders[1], "Command hints must become visible in both appearances")
        }
    }
}
