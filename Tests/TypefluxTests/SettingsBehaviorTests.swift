import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Settings rendered behavior", .serialized, .exclusiveUIState)
@MainActor
struct SettingsBehaviorTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport

    @Test func `appearance and interface buttons persist only the fixture preferences`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = makeModel(settings)
            try await RenderedUI.withWindow(StudioView(viewModel: model), width: 1100, height: 900) { _, host in
                try await RenderedUI.wait { RenderedUI.contains(L("settings.appearance.title"), in: host) }
                try await RenderedUI.wait { !model.permissionRows.isEmpty }
                try RenderedUI.button(AppearanceMode.dark.displayName, in: host).press()
                try await RenderedUI.wait { model.appearanceMode == .dark }
                #expect(SettingsStore(defaults: settings.defaults).appearanceMode == .dark)
                #expect(model.preferredColorScheme == .dark)
                try RenderedUI.button(InterfaceStyle.classic.displayName, in: host).press()
                try await RenderedUI.wait { model.interfaceStyle == .classic }
                #expect(SettingsStore(defaults: settings.defaults).interfaceStyle == .classic)
                try RenderedUI.button(AppearanceMode.light.displayName, in: host).press()
                try await RenderedUI.wait { model.appearanceMode == .light }
                #expect(SettingsStore(defaults: settings.defaults).appearanceMode == .light)
                try RenderedUI.snapshot(host, name: "settings-general")
            }
        }
    }

    @Test func `traditional chinese output options follow language and enabled state`() async throws {
        try await RenderedUI.withFixture { settings in
            settings.outputOpenCCEnabled = false
            let model = makeModel(settings)
            try await RenderedUI.withWindow(StudioView(viewModel: model), width: 1100, height: 1200) { _, host in
                try await RenderedUI.wait { RenderedUI.contains(L("settings.general"), in: host) }
                try await RenderedUI.wait { !model.permissionRows.isEmpty }
                #expect(!RenderedUI.contains(L("settings.output.opencc.title"), in: host))
                model.setAppLanguage(.traditionalChinese)
                try await RenderedUI.wait { RenderedUI.contains(L("settings.output.opencc.title"), in: host) }
                #expect(!RenderedUI.contains(L("settings.output.opencc.config.title"), in: host))
                // The switch is label-hidden; identify its row by its title and screen position.
                let title = try #require(RenderedUI.elements(in: host)
                    .first { $0.text == L("settings.output.opencc.title") })
                let toggle = try #require(RenderedUI.elements(in: host).first {
                    $0.role == NSAccessibility.Role.checkBox.rawValue && abs($0.frame.midY - title.frame.midY) < 30
                })
                try toggle.press()
                try await RenderedUI.wait { model.textTransformationEnabled && RenderedUI.contains(
                    L("settings.output.opencc.config.title"),
                    in: host
                ) }
                #expect(SettingsStore(defaults: settings.defaults).outputOpenCCEnabled)
                #expect(settings.isOutputOpenCCEffectiveEnabled)
                try RenderedUI.snapshot(host, name: "settings-traditional-output")
                model.setAppLanguage(.english)
                try await RenderedUI.wait { !RenderedUI.contains(L("settings.output.opencc.title"), in: host) }
                #expect(settings.outputOpenCCEnabled)
                #expect(!settings.isOutputOpenCCEffectiveEnabled)
            }
        }
    }

    private func makeModel(_ settings: SettingsStore) -> StudioViewModel {
        StudioViewModel(
            settingsStore: settings,
            historyStore: SettingsBehaviorHistoryStore(),
            initialSection: .settings,
            modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
        )
    }
}

extension SettingsBehaviorTests {
    @Test func `interrupted window checks restore language defaults and release their content`() async throws {
        let originalLanguage = AppLocalization.shared.language
        var window: NSWindow?
        var fixtureDefaults: UserDefaults?
        var started = false
        var ended = false
        let task = Task { @MainActor in
            defer { ended = true }
            try await RenderedUI.withFixture { settings in
                fixtureDefaults = settings.defaults
                settings.defaults.set("cleanup-check", forKey: "SettingsBehavior.cleanup.marker")
                let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
                model.setLanguage(.traditionalChinese)
                try await RenderedUI.withWindow(OnboardingView(
                    viewModel: model,
                    appearanceMode: .dark
                )) { owned, host in
                    window = owned
                    try await RenderedUI.wait { RenderedUI.contains(AppLanguage.english.displayName, in: host) }
                    started = true
                    try await Task.sleep(for: .seconds(30))
                }
            }
        }
        do {
            try await RenderedUI.wait { started || ended }
            _ = try #require(started && !ended, "The window check must be running before cancellation")
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
        #expect(ended)
        #expect(window?.isVisible == false)
        #expect(window?.contentView == nil)
        #expect(AppLocalization.shared.language == originalLanguage)
        #expect(fixtureDefaults?.object(forKey: "SettingsBehavior.cleanup.marker") == nil)
    }
}

private final class SettingsBehaviorHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        throw UnusedExport()
    }

    private struct UnusedExport: Error {}
}
