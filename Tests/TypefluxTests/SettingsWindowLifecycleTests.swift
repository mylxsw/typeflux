import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct SettingsWindowLifecycleTests {
    @Test func `closing settings releases its hosting tree while the menu bar app stays resident`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let previousDelegate = NSApp.delegate
            let policy = TypefluxTestActivationPolicyController()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            // Exercise the production close handler without hiding the test process through the Dock controller.
            let controller = SettingsWindowController(dockVisibility: DockVisibilityController(app: policy))
            defer {
                controller.window?.close()
                try? FileManager.default.removeItem(at: root)
            }
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                            initialSection: .history)
            let window = try #require(controller.window)
            #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
            #expect(window.contentView != nil)
            window.close()
            #expect(controller.window == nil && controller.viewModel == nil)
            #expect(window.contentView == nil && !window.isVisible)
            #expect(policy.currentActivationPolicy == .accessory)
            #expect(NSApp.activationPolicy() == .regular)
            #expect(NSApp.delegate === previousDelegate)
        }
    }
}
