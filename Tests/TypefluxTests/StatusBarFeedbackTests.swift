import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct StatusBarFeedbackTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: InterfaceStyle.allCases)
    func `sidebar header removes the support overflow button`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            for compact in [false, true] {
                let sidebar = StudioSidebar(
                    currentSection: .settings, onSelect: { _ in }, onAccountAction: {},
                    defaults: settings.defaults, compact: compact
                ).environment(\.interfaceStyle, style)
                try await UI.withWindow(sidebar, width: 256, height: compact ? 400 : 750) { _, host in
                    try await UI.wait { UI.contains(L("sidebar.appName"), in: host) }
                    #expect(!UI.contains(L("history.action.more"), in: host))
                    #expect(!UI.elements(in: host).contains {
                        $0.value("accessibilityIdentifier") as? String == "studio.supportMenu"
                    })
                }
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `menu feedback opens and reopens the existing form`(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            settings.interfaceStyle = style
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let windowController = SettingsWindowController.shared
            windowController.window?.close()
            let previousLibrary = windowController.modelLibrary
            windowController.modelLibrary = AskModelLibrary(
                defaults: settings.defaults,
                automaticallyLoadsCatalog: false
            )
            defer {
                windowController.window?.close()
                windowController.modelLibrary = previousLibrary
            }
            let controller = StatusBarController(
                appState: AppStateStore(), settingsStore: settings,
                historyStore: FileHistoryStore(baseDir: directory)
            )
            controller.start()
            defer { controller.stop() }
            let menu = try #require(controller.menu)
            let updateIndex = try #require(menu.items.firstIndex { $0.title == L("menu.checkForUpdates") })
            #expect(menu.items[updateIndex + 1].title == L("menu.feedback"))
            let feedbackMenu = try #require(menu.items[updateIndex + 1].submenu)
            // Exercise first presentation, the existing window, and a newly recreated window.
            for attempt in 0 ..< 3 {
                feedbackMenu.performActionForItem(at: 0)
                let window = try #require(windowController.window)
                try await UI.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                let host = try #require(sheet.contentView)
                try await UI.wait { UI.contains(L("feedback.direct.title"), in: host) }
                #expect(UI.contains(L("feedback.direct.contentLabel"), in: host))
                #expect(UI.contains(L("feedback.direct.submit"), in: host))
                try UI.button(L("common.cancel"), in: host).press()
                try await UI.wait { window.attachedSheet == nil }
                if attempt == 1 { window.close() }
            }
        }
    }
}
