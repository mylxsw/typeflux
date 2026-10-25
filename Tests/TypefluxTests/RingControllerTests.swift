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
    private var time: TimeInterval = 0
    private var features: [RingFeature] = []

    override func setUp() {
        super.setUp()
        suiteName = "RingControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        menu = FakeRingMenu()
        environment = FakeRingEnvironment()
        pointer = CGPoint(x: 100, y: 100)
        features = []
        time = 0
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
                              frontmostApplication: { nil },
                              now: { [weak self] in self?.time ?? 0 })
    }

    // MARK: - Gesture

    func testHoldReleaseActivatesAtDurationBoundaryAndIgnoresRepeats() {
        var gesture = RingHotkeyGesture()
        XCTAssertEqual(gesture.pressBegan(isVisible: false, at: 0), .show)
        XCTAssertTrue(gesture.isHeld)
        XCTAssertEqual(gesture.pressBegan(isVisible: true, at: 0.2), .ignore)
        XCTAssertEqual(gesture.pressEnded(isVisible: true, at: RingHotkeyGesture.holdDuration), .activate)
        XCTAssertFalse(gesture.isHeld)
        XCTAssertEqual(gesture.pressEnded(isVisible: true, at: 1), .keepOpen)
    }

    func testTapKeepsTheRingOpenAndAnotherPressCloses() {
        var gesture = RingHotkeyGesture()
        _ = gesture.pressBegan(isVisible: false, at: 0)
        XCTAssertEqual(gesture.pressEnded(isVisible: true, at: 0.299), .keepOpen)
        XCTAssertEqual(gesture.pressBegan(isVisible: true, at: 1), .dismiss)
        XCTAssertEqual(gesture.pressEnded(isVisible: false, at: 2), .keepOpen)
        _ = gesture.pressBegan(isVisible: false, at: 3)
        XCTAssertEqual(gesture.pressEnded(isVisible: false, at: 4), .keepOpen, "already closed")
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
        time = 0.5
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
        time = 0.5
        menu.pointed = nil
        controller.pressEnded()
        XCTAssertEqual(menu.dismissals, 1)
    }

    func testQuickTapWithPointerMovementWaitsForClick() async throws {
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        controller.pressBegan()
        pointer = CGPoint(x: 100, y: 400)
        let id = store.ringConfiguration.actions[3].id.uuidString
        menu.pointed = id
        time = 0.1
        controller.pressEnded()
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(menu.activations, 0)
        XCTAssertTrue(features.isEmpty)
        menu.onSelect(id)
        try await waitUntil { self.features == [.screenshot] }
    }

    func testHoldReturningToCenterDismissesWithoutActionOrFocus() {
        let controller = makeController()
        controller.pressBegan()
        pointer = CGPoint(x: 300, y: 100)
        pointer = CGPoint(x: 100, y: 100)
        time = 1
        controller.pressEnded()
        XCTAssertFalse(menu.isVisible)
        XCTAssertEqual(menu.dismissals, 1)
        XCTAssertEqual(menu.keyboardFocusRequests, 0)
        XCTAssertTrue(features.isEmpty)
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

    func testStaysClosedWhileRecordingUnassignedOrEmpty() {
        let controller = makeController()
        controller.isRecordingActive = { true }
        controller.pressBegan()
        XCTAssertTrue(menu.shownAt.isEmpty)

        controller.isRecordingActive = { false }
        var configuration = store.ringConfiguration
        store.setHotkey(nil, for: .ring)
        controller.pressBegan()
        XCTAssertTrue(menu.shownAt.isEmpty)

        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        configuration.actions = []
        store.ringConfiguration = configuration
        controller.pressBegan()
        XCTAssertTrue(menu.shownAt.isEmpty)
    }

    func testClearingTheShortcutClosesAnOpenRing() {
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        controller.pressBegan()
        XCTAssertTrue(menu.isVisible)
        store.setHotkey(nil, for: .ring)
        XCTAssertEqual(menu.dismissals, 1)
        controller.pressEnded()
        XCTAssertEqual(menu.activations, 0)
        controller.pressBegan()
        XCTAssertFalse(menu.isVisible)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        controller.pressBegan()
        XCTAssertTrue(menu.isVisible)
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

    func testDiagnosticsCoverShowVisibilityDismissAndBlockedRequests() async {
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        let collector = ShortcutLatencyEventCollector(), trace = diagnosticTestTrace(.ring)
        ShortcutLatency.$eventSink.withValue(collector.sink) {
            ShortcutLatency.$current.withValue(trace) { controller.pressBegan() }
        }
        await drainMainQueue()
        XCTAssertEqual(collector.stages, [.ringShowStarted, .ringShowFinished, .windowOrdered, .visibleNextTurn])
        ShortcutLatency.$eventSink.withValue(collector.sink) {
            ShortcutLatency.$current.withValue(trace) {
                controller.pressEnded()
                controller.pressBegan()
                controller.isRecordingActive = { true }
                controller.pressBegan()
            }
        }
        XCTAssertEqual(collector.stages.suffix(2), [.dismissed, .blocked])
        XCTAssertTrue(collector.events.allSatisfy { $0.trace == trace })
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0 ..< 100 where !condition() {
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

    var onCenterClick: (() -> Void)?
    var center = RingMenuCenter.plain
    var configurations = 0

    func configure(items: [RingMenuItem], style: RingStyle, centerTitle: String, center: RingMenuCenter) {
        self.items = items
        self.style = style
        self.centerTitle = centerTitle
        self.center = center
        configurations += 1
    }

    var takesKeyboardFocus = true
    var keyboardFocusRequests = 0

    func focusKeyboard() {
        keyboardFocusRequests += 1
    }

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
