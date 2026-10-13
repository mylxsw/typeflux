import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Grouped settings behavior", .exclusiveUIState)
@MainActor
struct GroupedSettingsBehaviorTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport

    @Test func generalSwitchesPersistAndConditionalRowsFollowTheirValues() async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                initialSection: .settings,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false))
            var managementRequests = 0
            try await RenderedUI.withWindow(
                GeneralSettingsView(viewModel: model, onManageMemory: { managementRequests += 1 }),
                width: 640, height: 2200
            ) { _, host in
                let controls: [(String, () -> Bool)] = [
                    ("settings.instantVoiceInput", { settings.instantVoiceInputEnabled }),
                    ("settings.mouseVoice", { settings.mouseVoiceInputEnabled }),
                    ("settings.mute", { settings.muteSystemOutputDuringRecording }),
                    ("settings.advanced.autoVocabulary", { settings.automaticVocabularyCollectionEnabled }),
                    ("settings.advanced.recentInputMemory", { settings.recentInputMemoryEnabled }),
                    ("settings.advanced.globalSoul", { settings.globalSoulMemoryEnabled }),
                    ("settings.advanced.autoUpdate", { settings.autoUpdateEnabled }),
                    ("settings.analyticsSharing", { settings.analyticsSharingEnabled })
                ]
                for (identifier, value) in controls {
                    let before = value()
                    let control = try #require(RenderedUI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == identifier
                            && $0.role == NSAccessibility.Role.checkBox.rawValue
                    })
                    try control.press()
                    try await RenderedUI.wait { value() != before }
                    try await Task.sleep(for: .milliseconds(50))
                    let updated = try #require(RenderedUI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == identifier
                            && $0.role == NSAccessibility.Role.checkBox.rawValue
                    })
                    try updated.press()
                    try await RenderedUI.wait { value() == before }
                }
                try RenderedUI.button(L("settings.advanced.recentInputMemory.manage"), in: host).press()
                #expect(managementRequests == 1)
            }
        }
    }

    @Test func screenshotResetRequiresConfirmationAndCancellationPreservesTheFolder() async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            settings.screenshotSaveDirectory = root.appendingPathComponent("captures")
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                initialSection: .settings,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false))
            try await RenderedUI.withWindow(
                GeneralSettingsView(viewModel: model, onManageMemory: {}), width: 640, height: 1800
            ) { window, host in
                let folder = model.screenshotSaveDirectory
                try RenderedUI.button(L("settings.shortcuts.screenshot.saveLocation.reset"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                #expect(model.screenshotSaveDirectory == folder)
                try RenderedUI.button(L("common.cancel"), in: try #require(window.attachedSheet)).press()
                try await RenderedUI.wait { window.attachedSheet == nil }
                #expect(model.screenshotSaveDirectory == folder)
                try RenderedUI.button(L("settings.shortcuts.screenshot.saveLocation.reset"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                try RenderedUI.button(L("common.reset"), in: try #require(window.attachedSheet)).press()
                try await RenderedUI.wait {
                    model.screenshotSaveDirectory == SettingsStore.defaultScreenshotSaveDirectory
                }
                #expect(settings.screenshotSaveDirectory == SettingsStore.defaultScreenshotSaveDirectory)
            }
        }
    }

    @Test func launcherResetKeepsRememberedPositionsUntilConfirmed() async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            settings.askLauncherPosition = .lastPosition
            settings.askLauncherAnchors["fixture-display"] = .init(left: 40, fromTop: 120)
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                initialSection: .settings,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false))
            try await RenderedUI.withWindow(
                GeneralSettingsView(viewModel: model, onManageMemory: {}), width: 640, height: 1800
            ) { window, host in
                let original = settings.askLauncherAnchors
                try RenderedUI.button(L("settings.shortcuts.launcherPosition.reset"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                #expect(settings.askLauncherAnchors == original)
                try RenderedUI.button(L("common.cancel"), in: try #require(window.attachedSheet)).press()
                try await RenderedUI.wait { window.attachedSheet == nil }
                #expect(settings.askLauncherAnchors == original)
                try RenderedUI.button(L("settings.shortcuts.launcherPosition.reset"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                try RenderedUI.button(L("common.reset"), in: try #require(window.attachedSheet)).press()
                try await RenderedUI.wait { settings.askLauncherAnchors.isEmpty }
                #expect(settings.askLauncherPosition == .lastPosition)
            }
        }
    }

    @Test func keywordDeletionRequiresConfirmationAndFinishesOnce() async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = HotkeySettingsModel(settingsStore: settings,
                workflows: AskWorkflowStore(settings: settings, root: root))
            let shortcut = KeywordHotkey(binding: .defaultAsk, keyword: "fy", pluginID: AskTranslatePlugin.id)
            model.save(shortcut)
            var completions = 0
            try await RenderedUI.withWindow(KeywordHotkeyEditorSheet(model: model,
                draft: KeywordHotkeyDraft(editing: shortcut), onDone: { completions += 1 }),
                width: 520, height: 440) { window, host in
                try RenderedUI.button(L("hotkeys.keyword.delete"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                #expect(model.keywordHotkey(shortcut.id) != nil)
                try RenderedUI.button(L("common.cancel"), in: try #require(window.attachedSheet)).press()
                try await RenderedUI.wait { window.attachedSheet == nil }
                #expect(model.keywordHotkey(shortcut.id) != nil)
                #expect(completions == 0)
                try RenderedUI.button(L("hotkeys.keyword.delete"), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                try RenderedUI.button(L("hotkeys.keyword.delete"), in: try #require(window.attachedSheet)).press()
                try await RenderedUI.wait { model.keywordHotkey(shortcut.id) == nil }
                #expect(completions == 1)
            }
        }
    }

    @Test func glassAccessibilityOverridesDisableAdjustment() async throws {
        try await RenderedUI.withFixture { _ in
            for options in [TypefluxAccessibilityOptions(reduceTransparency: true),
                            TypefluxAccessibilityOptions(increasedContrast: true)] {
                var value = 0.6
                try await RenderedUI.withWindow(LiquidGlassIntensitySetting(value: Binding(
                    get: { value }, set: { value = $0 }
                )).environment(\.typefluxAccessibilityOptions, options), width: 640, height: 300) { _, host in
                    let slider = try #require(RenderedUI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == "settings.liquidGlassIntensity.slider"
                    })
                    #expect(slider.value("isAccessibilityEnabled") as? Bool == false)
                    #expect(RenderedUI.contains(L("settings.glassIntensity.accessibility"), in: host))
                    #expect(value == 0.6)
                }
            }
        }
    }

    @Test func serverChoicesRetainTheirHealthAndLatencyLabels() async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                initialSection: .settings,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false))
            let view = AdvancedSettingsView(viewModel: model)
            let server = "https://api.example.com"
            #expect(view.serverLabel(server, statuses: []).contains(L("settings.servers.tag.notTested")))
            for latency in [nil, 120.0, 200.0, 400.0] {
                let status = CloudEndpointStatus(baseURL: try #require(URL(string: server)), latencyMs: latency,
                    lastProbeAt: nil, lastSuccessAt: nil, consecutiveFailures: 0, cooldownUntil: nil,
                    serverID: nil, serverVersion: nil, lastError: nil)
                let key = latency.map { $0 < 150 ? "fast" : $0 < 350 ? "average" : "slow" } ?? "notTested"
                let tag = latency.map { L("settings.servers.tag." + key, Int($0)) }
                    ?? L("settings.servers.tag." + key)
                #expect(view.serverLabel(server, statuses: [status]) == "api.example.com · " + tag)
            }
            let failed = CloudEndpointStatus(baseURL: try #require(URL(string: server)), latencyMs: 100,
                lastProbeAt: nil, lastSuccessAt: nil, consecutiveFailures: 1, cooldownUntil: nil,
                serverID: nil, serverVersion: nil, lastError: "Unavailable")
            #expect(view.serverLabel(server, statuses: [failed]).contains(L("settings.servers.tag.unavailable")))
        }
    }

    @Test func titleIsInTheDetailToolbarAndUpdatesAfterNavigation() async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let controller = SettingsWindowController()
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                            initialSection: .settings)
            let window = try #require(controller.window)
            let model = try #require(controller.viewModel)
            defer { window.close() }
            window.setContentSize(NSSize(width: 1100, height: 800))
            for section in [StudioSection.settings, .vocabulary, .account] {
                model.navigate(to: section)
                try await RenderedUI.wait { window.title == section.heading }
                try await Task.sleep(for: .milliseconds(300))
                let title = try #require(RenderedUI.elements(in: window).first {
                    $0.value("accessibilityIdentifier") as? String == "typeflux.window.title"
                })
                #expect(title.text == section.heading || title.label == section.heading)
                #expect(window.titleVisibility == .hidden)
                #expect(title.frame.minX >= window.frame.minX + 180)
                #expect(title.frame.minX < window.frame.minX + 320)
            }
        }
    }
}
