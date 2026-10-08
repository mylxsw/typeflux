import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher number hints", .serialized)
@MainActor
struct AskLauncherNumberShortcutTests {
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
                    let mode = appearance == .aqua ? "light" : "dark"
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(mode)-\(visible ? "held" : "idle").png"))
                }
            }
            #expect(renders[0] != renders[1], "Command hints must become visible in both appearances")
        }
    }
}
