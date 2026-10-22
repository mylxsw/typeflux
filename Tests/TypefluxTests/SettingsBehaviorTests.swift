import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Settings rendered behavior", .serialized, .exclusiveUIState)
@MainActor
struct SettingsBehaviorTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport

    @Test func `memory management sheet renders its settings controls and navigation`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = makeModel(settings)
            for language in [AppLanguage.simplifiedChinese, .english] {
                AppLocalization.shared.setLanguage(language)
                for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                    try await RenderedUI.withWindow(RecentInputMemoryManagementView(viewModel: model),
                                                    width: 900, height: 680) { window, host in
                        window.appearance = NSAppearance(named: appearance)
                        try await RenderedUI.wait {
                            RenderedUI.contains(L("settings.advanced.recentInputMemory.manage"), in: host)
                        }
                        _ = try RenderedUI.button(L("settings.advanced.recentInputMemory.close"), in: host)
                        let search = try #require(RenderedUI.elements(in: host).first {
                            $0.value("accessibilityIdentifier") as? String == "settings.memory.search"
                        })
                        #expect(search.frame.width > 200)
                        try RenderedUI.button(L("settings.advanced.globalSoul.manage"), in: host).press()
                        try await RenderedUI.wait {
                            RenderedUI.contains(L("settings.advanced.globalSoul.empty"), in: host)
                                || model.globalSoulMemory != nil
                        }
                        try RenderedUI.button(L("settings.advanced.recentInputMemory.allApps"), in: host).press()
                    }
                }
            }
        }
    }

    @Test func `description hint opens and closes on click`() async throws {
        let detail = "This setting controls the fixture behavior."
        try await RenderedUI.withFixture { _ in
            try await RenderedUI.withWindow(
                SettingsDescriptionHint(detail: detail, visible: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center),
                width: 500, height: 300
            ) { window, host in
                window.setFrameOrigin(NSPoint(x: 80, y: 80))
                let hint = try RenderedUI.button(detail, in: host)
                try hint.press()
                try await RenderedUI.wait {
                    NSApp.windows.contains { $0.isVisible && $0.parent === window && RenderedUI.contains(detail, in: $0) }
                }
                try hint.press()
                try await RenderedUI.wait {
                    !NSApp.windows.contains { $0.isVisible && $0.parent === window && RenderedUI.contains(detail, in: $0) }
                }
            }
        }
    }

    @Test func `appearance and interface buttons persist only the fixture preferences`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = makeModel(settings)
            try await RenderedUI.withWindow(StudioView(viewModel: model, settingsPane: .appearance), width: 1100, height: 900) { _, host in
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
                try RenderedUI.snapshot(host, name: "settings-appearance")
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
                    try await RenderedUI.wait { RenderedUI.contains(AppLanguage.traditionalChinese.displayName, in: host) }
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

extension SettingsBehaviorTests {
    @Test func narrowSettingsKeepStyleControlsInsideTheWindow() async throws {
        try await RenderedUI.withFixture { settings in
            let model = makeModel(settings)
            for style in InterfaceStyle.allCases {
                model.setInterfaceStyle(style)
                for width: CGFloat in [720, 900, 1100, 1440] {
                    try await RenderedUI.withWindow(StudioView(viewModel: model, settingsPane: .appearance), width: width, height: 900) { window, host in
                        try await RenderedUI.wait { RenderedUI.contains(L("settings.interfaceStyle.title"), in: host) }
                        let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                        for choice in InterfaceStyle.allCases {
                            let button = try RenderedUI.button(choice.displayName, in: host)
                            #expect(button.frame.width >= 20)
                            #expect(button.frame.minX >= bounds.minX - 1 && button.frame.maxX <= bounds.maxX + 1,
                                    "the style picker must stay within the viewport")
                        }
                        if width < 1040 {
                            let navigation = try RenderedUI.button(L("ask.sidebar.toggle"), in: host)
                            #expect(navigation.frame.width >= 20, "collapsed navigation remains reachable")
                            window.setFrameOrigin(NSPoint(x: 80, y: 80))
                            try navigation.press()
                            try await RenderedUI.wait {
                                NSApp.windows.contains { $0.isVisible && $0.parent === window }
                            }
                            let popover = try #require(NSApp.windows.first { $0.isVisible && $0.parent === window })
                            try RenderedUI.button(StudioSection.launcher.title, in: popover).press()
                            try await RenderedUI.wait { model.currentSection == .launcher }
                            model.navigate(to: .settings)
                            try await RenderedUI.wait { RenderedUI.contains(L("settings.interfaceStyle.title"), in: host) }
                        }
                        try RenderedUI.snapshot(host, name: "responsive-settings-\(style.rawValue)-\(Int(width))")
                    }
                }
            }
        }
    }
}
