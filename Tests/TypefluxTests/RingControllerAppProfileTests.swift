import AppKit
@testable import Typeflux
import XCTest

/// The ring opens with the front app's own actions; the middle switches to the global ones.
@MainActor
final class RingControllerAppProfileTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var menu: FakeRingMenu!
    private var front: NSRunningApplication?
    private var features: [RingFeature] = []
    private var time: TimeInterval = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "RingControllerAppProfileTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        menu = FakeRingMenu()
        features = []
        time = 0
        // Any other app works as "the app in front"; the test only needs its bundle identifier.
        let own = ProcessInfo.processInfo.processIdentifier
        front = NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier != own && $0.bundleIdentifier != nil }
        if front == nil {
            throw XCTSkip("needs another running app")
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        menu = nil
        super.tearDown()
    }

    private var bundle: String {
        front?.bundleIdentifier ?? ""
    }

    private func makeController() -> RingController {
        let executor = RingActionExecutor(environment: FakeRingEnvironment())
        executor.handlers.feature = { [weak self] in self?.features.append($0) }
        return RingController(settingsStore: store, menu: menu, executor: executor,
                              pointerLocation: { CGPoint(x: 100, y: 100) },
                              frontmostApplication: { [weak self] in self?.front },
                              now: { [weak self] in self?.time ?? 0 })
    }

    @discardableResult
    private func addProfile(enabled: Bool = true, actions: [RingAction] = [.feature(.notes), .feature(.wordBook)],
                            global: [RingAction]? = nil) -> RingAppProfile {
        var configuration = store.ringConfiguration
        let profile = RingAppProfile(bundleIdentifier: bundle, appName: "Front", isEnabled: enabled, actions: actions)
        configuration.appProfiles = [profile]
        if let global {
            configuration.actions = global
        }
        store.ringConfiguration = configuration
        return profile
    }

    func testOpensWithTheFrontAppsActionsAndTheMiddleSwitches() async throws {
        let profile = addProfile()
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        XCTAssertEqual(menu.items.count, 6, "closed, the ring holds the global actions")
        XCTAssertNil(menu.onCenterClick)

        controller.pressBegan()
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(controller.page, .app(profile.id))
        XCTAssertEqual(menu.items.map(\.id), profile.actions.map(\.id.uuidString))
        XCTAssertEqual(menu.centerTitle, "Front")
        XCTAssertEqual(menu.center, RingMenuCenter(appBundleIdentifier: bundle, pageCount: 2, pageIndex: 0))
        let click = try XCTUnwrap(menu.onCenterClick)

        click()
        XCTAssertEqual(controller.page, .global)
        XCTAssertEqual(menu.items.count, 6)
        XCTAssertEqual(menu.centerTitle, "Typeflux")
        XCTAssertEqual(menu.center, RingMenuCenter(pageCount: 2, pageIndex: 1))
        let global = store.ringConfiguration.actions[2]
        menu.onSelect(global.id.uuidString)
        menu.onSelect(profile.actions[0].id.uuidString)
        try await waitUntil { self.features == [.translate] }

        click()
        XCTAssertEqual(controller.page, .app(profile.id))
        menu.onSelect(profile.actions[0].id.uuidString)
        try await waitUntil { self.features == [.translate, .notes] }
    }

    func testEveryOpeningStartsWithTheAppsActions() {
        let profile = addProfile()
        let controller = makeController()
        controller.pressBegan()
        controller.switchPage()
        XCTAssertEqual(controller.page, .global)
        controller.pressEnded()
        controller.pressBegan()
        XCTAssertFalse(menu.isVisible, "a second press closes")
        controller.pressEnded()
        controller.pressBegan()
        controller.pressEnded()
        XCTAssertEqual(controller.page, .app(profile.id))
    }

    func testOffEmptyOrOtherAppsUseTheGlobalActionsAndTheMiddleCloses() {
        addProfile(enabled: false)
        let controller = makeController()
        controller.pressBegan()
        XCTAssertEqual(controller.page, .global)
        XCTAssertNil(menu.onCenterClick)
        XCTAssertEqual(menu.center, .plain)
        XCTAssertFalse(controller.canSwitchPage)
        controller.switchPage()
        XCTAssertEqual(controller.page, .global, "nothing to switch to")
        controller.cancelPress()

        addProfile(actions: [])
        controller.pressBegan()
        XCTAssertEqual(controller.page, .global)
        controller.cancelPress()

        front = nil
        addProfile()
        controller.pressBegan()
        XCTAssertEqual(controller.page, .global, "Typeflux itself in front")
    }

    func testWithoutGlobalActionsOnlyTheAppPageShows() {
        let profile = addProfile(global: [])
        let controller = makeController()
        controller.pressBegan()
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(controller.page, .app(profile.id))
        XCTAssertNil(menu.onCenterClick)
        XCTAssertEqual(menu.center.pageCount, 1)
        controller.cancelPress()

        front = nil
        controller.pressBegan()
        XCTAssertFalse(menu.isVisible, "elsewhere there is nothing to show")
    }

    func testRemovingTheOpenProfileFallsBackAndEmptyingEverythingCloses() {
        addProfile()
        let controller = makeController()
        controller.pressBegan()
        var configuration = store.ringConfiguration
        configuration.appProfiles = []
        store.ringConfiguration = configuration
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(controller.page, .global)
        XCTAssertEqual(menu.items.count, 6)

        configuration.actions = []
        store.ringConfiguration = configuration
        XCTAssertFalse(menu.isVisible)
    }

    func testUnrelatedSettingsChangesDoNotRedrawTheRing() {
        addProfile()
        let controller = makeController()
        controller.pressBegan()
        let count = menu.configurations
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        controller.reload()
        XCTAssertEqual(menu.configurations, count)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0 ..< 100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}
