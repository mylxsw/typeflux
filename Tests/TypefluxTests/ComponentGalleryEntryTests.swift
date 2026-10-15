import AppKit
import Testing
@testable import Typeflux

/// The component gallery is reachable from the menu bar item and the app menu in developer builds.
@Suite("Component gallery entry points", .serialized, .exclusiveUIState)
@MainActor
struct ComponentGalleryEntryTests {
    @Test func statusBarMenuOffersTheGalleryNextToAbout() throws {
        let suite = "ComponentGalleryEntry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = StatusBarController(
            appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults),
            historyStore: FileHistoryStore(baseDir: directory)
        )
        controller.start()
        defer { controller.stop() }
        let items = try #require(controller.menu?.items)
        let gallery = items.firstIndex { $0.title == L("appMenu.componentGallery") }
        #expect((gallery != nil) == ComponentGalleryAccess.isAvailable())
        if let gallery {
            let about = try #require(items.firstIndex { $0.title == L("menu.about") })
            #expect(gallery == about + 1)
            #expect(items[gallery].target === controller)
            #expect(items[gallery].action != nil)
        }
    }

    @Test func appMenuOffersTheGallery() throws {
        _ = NSApplication.shared
        let original = NSApp.mainMenu
        defer { NSApp.mainMenu = original }
        AppMenuController.install()
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let gallery = appMenu.items.first { $0.title == L("appMenu.componentGallery") }
        #expect((gallery != nil) == ComponentGalleryAccess.isAvailable())
        #expect(gallery?.action != nil && gallery?.target != nil || gallery == nil)
    }

    @Test func testBuildsExposeTheGallery() {
        // `swift test` builds debug, and `make run` passes -DDEBUG, so developer builds always offer it.
        #expect(ComponentGalleryAccess.isDebugBuild)
    }
}
