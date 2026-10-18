import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask launcher position settings", .exclusiveUIState)
@MainActor
struct AskLauncherPositionSettingsTests {
    @MainActor
    private final class InputSourceProbe: AskLauncherInputSourceListing {
        var calls = 0

        func availableSources() -> [AskLauncherInputSource] {
            calls += 1
            return []
        }
    }

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

    @Test func launcherGeneralPaneChangesThePosition() throws {
        let settings = try store()
        let view = LauncherSettingsView(settings: settings)

        view.setLauncherPosition(.lastPosition)
        #expect(settings.askLauncherPosition == .lastPosition)
        // The launcher is moved while the page is open; choosing centre forgets it.
        settings.askLauncherAnchors["built-in"] = .init(left: 10, fromTop: 10)
        view.setLauncherPosition(.center)
        #expect(settings.askLauncherPosition == .center)
        #expect(settings.askLauncherAnchors.isEmpty)
    }

    @Test func launcherGeneralPaneShowsOnlyThePositionChoice() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.askLauncherPosition = .lastPosition
            settings.askLauncherAnchors["built-in"] = .init(left: 40, fromTop: 120)
            try await SettingsBehaviorTestSupport.withWindow(LauncherSettingsView(settings: settings, pane: .basics),
                                                              width: 900, height: 900) { window, _ in
                #expect(SettingsBehaviorTestSupport.contains(L("settings.shortcuts.launcherPosition.title"), in: window))
                #expect(SettingsBehaviorTestSupport.contains(L("launcher.inputSource.title"), in: window))
                #expect(SettingsBehaviorTestSupport.contains(L("settings.shortcuts.launcherPosition.center"), in: window))
                #expect(SettingsBehaviorTestSupport.contains(L("settings.shortcuts.launcherPosition.last"), in: window))
                // No separate "Center again" link beside the choice.
                #expect(!SettingsBehaviorTestSupport.elements(in: window).contains {
                    $0.role == NSAccessibility.Role.link.rawValue
                        || ($0.role == NSAccessibility.Role.button.rawValue && $0.label == "Center again")
                })
                #expect(settings.askLauncherAnchors["built-in"] == .init(left: 40, fromTop: 120))
            }
        }
    }

    @Test func otherLauncherPanesDoNotEnumerateInputSources() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let probe = InputSourceProbe()
            try await SettingsBehaviorTestSupport.withWindow(
                LauncherSettingsView(settings: settings, pane: .keywords, inputSources: probe),
                width: 900, height: 700
            ) { window, _ in
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("ask.settings.keywords.listFootnote"), in: window)
                }
                #expect(probe.calls == 0)
            }
            try await SettingsBehaviorTestSupport.withWindow(
                LauncherSettingsView(settings: settings, pane: .basics, inputSources: probe),
                width: 900, height: 700
            ) { window, _ in
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("launcher.inputSource.title"), in: window)
                }
                #expect(probe.calls == 1)
            }
        }
    }

    @Test func settingsGeneralTabNoLongerShowsTheLauncherPosition() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = StudioViewModel(settingsStore: settings, historyStore: LauncherPositionHistoryStore(),
                                        initialSection: .settings)
            try await SettingsBehaviorTestSupport.withWindow(StudioView(viewModel: model),
                                                              width: 1100, height: 1000) { window, _ in
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("settings.launchAtLogin.title"), in: window)
                }
                #expect(!SettingsBehaviorTestSupport.contains(L("settings.shortcuts.launcherPosition.title"), in: window))
            }
        }
    }
}

/// Opt-in render of the launcher general pane with the position setting (set TYPEFLUX_ASK_SNAPSHOTS).
@Suite("Ask launcher position snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherPositionVisualTests {
    @Test func renderLauncherGeneralPane() async throws {
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
                                        initialSection: .launcher)
            let size = CGSize(width: 1100, height: 1200)
            let host = NSHostingView(rootView: StudioView(viewModel: model, launcherPane: .basics).frame(width: size.width, height: size.height)
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
