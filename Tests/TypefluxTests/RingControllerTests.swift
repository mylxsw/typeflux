import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class RingControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var menu: FakeRingMenu!
    private var environment: FakeRingEnvironment!
    private var pointer = CGPoint(x: 100, y: 100)
    private var features: [RingFeature] = []

    override func setUp() {
        super.setUp()
        suiteName = "RingControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        menu = FakeRingMenu()
        environment = FakeRingEnvironment()
        pointer = CGPoint(x: 100, y: 100)
        features = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        menu = nil
        environment = nil
        super.tearDown()
    }

    private func makeController() -> RingController {
        let executor = RingActionExecutor(environment: environment)
        executor.handlers.feature = { [weak self] in self?.features.append($0) }
        return RingController(settingsStore: store, menu: menu, executor: executor,
                              pointerLocation: { [weak self] in self?.pointer ?? .zero },
                              frontmostApplication: { nil })
    }

    // MARK: - Gesture

    func testHoldMoveReleaseActivates() {
        var gesture = RingHotkeyGesture()
        XCTAssertEqual(gesture.pressBegan(isVisible: false, at: .zero), .show)
        XCTAssertTrue(gesture.isHeld)
        XCTAssertEqual(gesture.pressBegan(isVisible: true, at: .zero), .ignore, "key repeat is ignored")
        XCTAssertEqual(gesture.pressEnded(isVisible: true, at: CGPoint(x: 0, y: 25)), .activate)
        XCTAssertFalse(gesture.isHeld)
    }

    func testTapKeepsTheRingOpenAndAnotherPressCloses() {
        var gesture = RingHotkeyGesture()
        _ = gesture.pressBegan(isVisible: false, at: .zero)
        XCTAssertEqual(gesture.pressEnded(isVisible: true, at: CGPoint(x: 5, y: 5)), .keepOpen)
        XCTAssertEqual(gesture.pressBegan(isVisible: true, at: .zero), .dismiss)
        XCTAssertEqual(gesture.pressEnded(isVisible: false, at: CGPoint(x: 50, y: 50)), .keepOpen)
        XCTAssertEqual(gesture.pressEnded(isVisible: true, at: .zero), .keepOpen, "a release without a press")
        _ = gesture.pressBegan(isVisible: false, at: .zero)
        XCTAssertEqual(gesture.pressEnded(isVisible: false, at: CGPoint(x: 50, y: 0)), .keepOpen, "already closed")
    }

    // MARK: - Controller

    func testConfiguresTheMenuAndFollowsSettings() {
        let controller = makeController()
        XCTAssertEqual(menu.items.count, 6)
        XCTAssertEqual(menu.style, .frosted)
        XCTAssertEqual(menu.centerTitle, "Typeflux")
        XCTAssertEqual(controller.configuration, store.ringConfiguration)

        var configuration = store.ringConfiguration
        configuration.actions = [RingAction(kind: .app(bundleIdentifier: "com.apple.Notes", name: "Notes"),
                                            title: "Screenshot Translation", symbol: "app")]
        configuration.style = .liquidGlass
        store.ringConfiguration = configuration
        XCTAssertEqual(menu.items, [RingMenuItem(id: configuration.actions[0].id.uuidString,
                                                 label: "Screenshot\nTranslation", symbol: "app",
                                                 bundleIdentifier: "com.apple.Notes")])
        XCTAssertEqual(menu.style, .liquidGlass)
    }

    func testHoldAndReleaseRunsThePointedSlice() async throws {
        let controller = makeController()
        controller.pressBegan()
        XCTAssertEqual(menu.shownAt, [CGPoint(x: 100, y: 100)])
        pointer = CGPoint(x: 100, y: 160)
        menu.pointed = store.ringConfiguration.actions[3].id.uuidString
        controller.pressEnded()
        try await waitUntil { self.features == [.screenshot] }
        XCTAssertEqual(menu.dismissals, 0)
        withExtendedLifetime(controller) {}
    }

    func testSingleModifierOnlyTakesKeyboardFocusAfterTap() {
        store.setHotkey(.rightOptionActivation, for: .ring)
        let controller = makeController()
        controller.pressBegan()
        XCTAssertFalse(menu.takesKeyboardFocus)
        XCTAssertEqual(menu.keyboardFocusRequests, 0)
        controller.pressEnded()
        XCTAssertEqual(menu.keyboardFocusRequests, 1)
    }

    func testCancelledPressNeverRunsAndNextPressCanOpen() {
        let controller = makeController()
        controller.pressBegan()
        pointer = CGPoint(x: 100, y: 160)
        menu.pointed = store.ringConfiguration.actions[3].id.uuidString
        controller.cancelPress()
        controller.pressEnded()
        XCTAssertFalse(menu.isVisible)
        XCTAssertEqual(menu.activations, 0)
        controller.pressBegan()
        XCTAssertTrue(menu.isVisible)
    }

    func testReleasingInTheMiddleCloses() {
        let controller = makeController()
        controller.pressBegan()
        pointer = CGPoint(x: 140, y: 100)
        menu.pointed = nil
        controller.pressEnded()
        XCTAssertEqual(menu.dismissals, 1)
    }

    func testTapLeavesTheRingOpenAndPressingAgainCloses() {
        let controller = makeController()
        controller.pressBegan()
        controller.pressEnded()
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(menu.activations, 0)
        controller.pressBegan()
        XCTAssertEqual(menu.dismissals, 1)
    }

    func testStaysClosedWhileRecordingOffOrEmpty() {
        let controller = makeController()
        controller.isRecordingActive = { true }
        controller.pressBegan()
        XCTAssertTrue(menu.shownAt.isEmpty)

        controller.isRecordingActive = { false }
        var configuration = store.ringConfiguration
        configuration.enabled = false
        store.ringConfiguration = configuration
        controller.pressBegan()
        XCTAssertTrue(menu.shownAt.isEmpty)

        configuration.enabled = true
        configuration.actions = []
        store.ringConfiguration = configuration
        controller.pressBegan()
        XCTAssertTrue(menu.shownAt.isEmpty)
    }

    func testTurningTheRingOffClosesAnOpenRing() {
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        menu.isVisible = true
        var configuration = store.ringConfiguration
        configuration.enabled = false
        store.ringConfiguration = configuration
        XCTAssertEqual(menu.dismissals, 1)
    }

    func testSelectingAnActionRunsItAndUnknownIDsAreIgnored() async throws {
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        let action = store.ringConfiguration.actions[2]
        menu.onSelect(action.id.uuidString)
        menu.onSelect("unknown")
        try await waitUntil { self.features == [.translate] }
        XCTAssertEqual(features, [.translate])
    }

    func testOpieStyleMapping() {
        XCTAssertEqual(OpieRingMenu.style(.classic), .classic)
        XCTAssertEqual(OpieRingMenu.style(.frosted), .frosted)
        XCTAssertEqual(OpieRingMenu.style(.liquidGlass), .liquidGlass)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class FakeRingMenu: RingMenuPresenting {
    var isVisible = false
    var onSelect: (String) -> Void = { _ in }
    var items: [RingMenuItem] = []
    var style: RingStyle?
    var centerTitle = ""
    var shownAt: [CGPoint] = []
    var dismissals = 0
    var activations = 0
    /// The slice under the pointer; nil is the middle.
    var pointed: String?

    func configure(items: [RingMenuItem], style: RingStyle, centerTitle: String) {
        self.items = items
        self.style = style
        self.centerTitle = centerTitle
    }

    var takesKeyboardFocus = true
    var keyboardFocusRequests = 0

    func focusKeyboard() { keyboardFocusRequests += 1 }

    func show(at point: CGPoint, takesKeyboardFocus: Bool) {
        self.takesKeyboardFocus = takesKeyboardFocus
        shownAt.append(point)
        isVisible = true
    }

    func dismiss() {
        dismissals += 1
        isVisible = false
    }

    func activatePointedItem() -> Bool {
        activations += 1
        guard let pointed else { return false }
        isVisible = false
        onSelect(pointed)
        return true
    }
}

@MainActor
final class FakeRingEnvironment: RingSystemEnvironment {
    var applications: [String: URL] = [:]
    var directories: Set<String> = []
    var scriptsSucceed = true
    var opened: [URL] = []
    var openedApplications: [URL] = []
    var processes: [[String]] = []
    var scripts: [String] = []
    var keyStrokes: [(Int, UInt)] = []
    var activated: [NSRunningApplication?] = []
    var keepAwake: [Bool] = []

    func applicationURL(bundleIdentifier: String) -> URL? {
        applications[bundleIdentifier]
    }

    func openApplication(at url: URL) {
        openedApplications.append(url)
    }

    func open(_ url: URL) {
        opened.append(url)
    }

    func directoryExists(atPath path: String) -> Bool {
        directories.contains(path)
    }

    func runProcess(_ executable: String, arguments: [String]) {
        processes.append([executable] + arguments)
    }

    func runAppleScript(_ source: String) -> Bool {
        scripts.append(source)
        return scriptsSucceed
    }

    func postKeyStroke(keyCode: Int, modifierFlags: UInt) {
        keyStrokes.append((keyCode, modifierFlags))
    }

    func activate(_ application: NSRunningApplication?) {
        activated.append(application)
    }

    func setKeepAwake(_ enabled: Bool) -> Bool {
        keepAwake.append(enabled)
        return enabled
    }
}
