import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask launcher position settings", .exclusiveUIState)
@MainActor
struct AskLauncherPositionSettingsTests {
    private func store() throws -> SettingsStore {
        SettingsStore(defaults: try #require(UserDefaults(suiteName: "AskLauncherPosition-\(UUID().uuidString)")))
    }

    @Test func opensCentredWithNothingRememberedByDefault() throws {
        let settings = try store()
        #expect(settings.askLauncherPosition == .center)
        #expect(settings.askLauncherAnchors.isEmpty)
    }

    @Test func remembersPositionsPerDisplay() throws {
        let settings = try store()
        settings.askLauncherPosition = .lastPosition
        settings.askLauncherAnchors["built-in"] = .init(left: 40, fromTop: 120)
        settings.askLauncherAnchors["external"] = .init(left: 900, fromTop: 30)
        let reloaded = SettingsStore(defaults: settings.defaults)
        #expect(reloaded.askLauncherPosition == .lastPosition)
        #expect(reloaded.askLauncherAnchors["built-in"] == .init(left: 40, fromTop: 120))
        #expect(reloaded.askLauncherAnchors["external"] == .init(left: 900, fromTop: 30))

        reloaded.askLauncherAnchors["external"] = nil
        #expect(Array(reloaded.askLauncherAnchors.keys) == ["built-in"])
        reloaded.askLauncherAnchors = [:]
        #expect(reloaded.defaults.object(forKey: "ask.launcher.anchors") == nil)
    }

    @Test func choosingCentreForgetsRememberedPositions() throws {
        let settings = try store()
        settings.askLauncherPosition = .lastPosition
        settings.askLauncherAnchors["built-in"] = .init(left: 40, fromTop: 120)
        settings.askLauncherPosition = .center
        #expect(settings.askLauncherAnchors.isEmpty)
    }

    @Test func unreadableValuesFallBackToTheDefaults() throws {
        let settings = try store()
        settings.defaults.set("sideways", forKey: "ask.launcher.position")
        settings.defaults.set(Data("not json".utf8), forKey: "ask.launcher.anchors")
        #expect(settings.askLauncherPosition == .center)
        #expect(settings.askLauncherAnchors.isEmpty)
    }

    @Test func settingsPageChangesAndResetsThePosition() throws {
        let settings = try store()
        let viewModel = StudioViewModel(settingsStore: settings, historyStore: LauncherPositionHistoryStore(),
                                        initialSection: .settings)
        #expect(viewModel.askLauncherPosition == .center)
        #expect(!viewModel.hasRememberedLauncherPositions)

        viewModel.setAskLauncherPosition(.lastPosition)
        #expect(settings.askLauncherPosition == .lastPosition)
        // The launcher is moved while the page is open.
        settings.askLauncherAnchors["built-in"] = .init(left: 10, fromTop: 10)
        viewModel.refreshAskLauncherPositions()
        #expect(viewModel.hasRememberedLauncherPositions)

        viewModel.resetAskLauncherPositions()
        #expect(settings.askLauncherAnchors.isEmpty)
        #expect(!viewModel.hasRememberedLauncherPositions)
        #expect(viewModel.askLauncherPosition == .lastPosition)

        settings.askLauncherAnchors["built-in"] = .init(left: 10, fromTop: 10)
        viewModel.setAskLauncherPosition(.center)
        #expect(settings.askLauncherAnchors.isEmpty)
        #expect(!viewModel.hasRememberedLauncherPositions)
    }
}

/// Opt-in render of the shortcuts page with the position setting (set TYPEFLUX_ASK_SNAPSHOTS).
@Suite("Ask launcher position snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherPositionVisualTests {
    @Test func renderShortcutSettings() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: "position-snapshot-\(UUID())")))
            settings.askLauncherPosition = .lastPosition
            settings.askLauncherAnchors["built-in"] = .init(left: 40, fromTop: 120)
            let model = StudioViewModel(settingsStore: settings, historyStore: LauncherPositionHistoryStore(),
                                        initialSection: .settings)
            let size = CGSize(width: 1100, height: 2100)
            let host = NSHostingView(rootView: StudioView(viewModel: model).frame(width: size.width, height: size.height)
                .preferredColorScheme(scheme))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("launcher-position-settings-\(name).png"))
        }
    }
}

private final class LauncherPositionHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] { [] }
    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] { [] }
    func record(id _: UUID) -> HistoryRecord? { nil }
    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL { URL(fileURLWithPath: "/tmp/typeflux-launcher-position-history.md") }
}
