import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class BackgroundActivityUITests: XCTestCase {
    private var suites: [String] = []

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Requires a GUI WindowServer session")
        }
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suites.removeAll()
        super.tearDown()
    }

    // MARK: - Menu

    func testMenuShowsTheTaskSectionFirstAndTheDotFollowsTheTasks() throws {
        let (controller, center, source) = try makeController()
        defer { controller.stop() }
        XCTAssertNil(controller.menu?.items.first?.view, "no section while idle")
        XCTAssertEqual(controller.activityIndicatorState, .none)

        source.feed.publish([makeActivity("download")])
        drain(until: { controller.menu?.items.first?.view != nil })

        let section = try XCTUnwrap(controller.menu?.items.first?.view)
        XCTAssertEqual(section.frame.size, NSSize(width: BackgroundActivityMenuLayout.width,
                                                  height: controller.menuActivityLayout.height))
        XCTAssertTrue(try XCTUnwrap(controller.menu?.items[1]).isSeparatorItem)
        XCTAssertEqual(controller.menu?.items[2].title, L("menu.openVoiceStudio"))
        XCTAssertEqual(controller.activityIndicatorState, .running)

        source.feed.publish([makeActivity("download"), makeActivity("approval", kind: .agent, state: .attention)])
        drain()
        XCTAssertEqual(controller.activityIndicatorState, .attention)
        XCTAssertEqual(controller.menuActivityLayout.rows, ["approval", "download"])

        center.indicatorEnabled = false
        drain()
        XCTAssertEqual(controller.activityIndicatorState, .none)

        source.feed.publish([makeActivity("paused", state: .paused)])
        center.indicatorEnabled = true
        drain()
        XCTAssertEqual(controller.activityIndicatorState, .none, "resting work keeps the icon quiet")
    }

    func testOpenMenuKeepsItsRowsUntilItCloses() throws {
        let (controller, _, source) = try makeController()
        defer { controller.stop() }
        source.feed.publish([makeActivity("a")])
        drain()
        let menu = try XCTUnwrap(controller.menu)

        controller.menuWillOpen(menu)
        source.feed.publish([makeActivity("a"), makeActivity("b")])
        drain()
        XCTAssertTrue(controller.menu === menu)
        XCTAssertEqual(controller.menuActivityLayout.rows, ["a"])

        let submenu = NSMenu(title: "other")
        controller.menuWillOpen(submenu)
        controller.menuDidClose(submenu)
        XCTAssertTrue(controller.menu === menu, "closing a submenu does not rebuild")

        controller.menuDidClose(menu)
        XCTAssertFalse(controller.menu === menu)
        XCTAssertEqual(controller.menuActivityLayout.rows, ["a", "b"])

        // Progress alone never rebuilds the menu.
        let rebuilt = controller.menu
        source.feed.publish([makeActivity("a", detail: "50%"), makeActivity("b")])
        drain()
        XCTAssertTrue(controller.menu === rebuilt)
    }

    func testMenuSectionRoutesActionsAndOpensTheWindow() throws {
        let (controller, center, source) = try makeController()
        defer { controller.stop() }
        var opened: [BackgroundActivity.Route] = []
        center.onOpen = { opened.append($0) }
        var routed = makeActivity("agent", kind: .agent)
        routed.route = .conversation("c1")
        source.feed.publish([routed, makeActivity("download")])
        drain()
        let host = try XCTUnwrap(controller.menu?.items.first?.view as? NSHostingView<BackgroundActivityMenuSection>)

        host.rootView.perform(.cancel, "download")
        host.rootView.perform(.open, "agent")
        XCTAssertEqual(source.performed.map(\.1), ["download"])
        XCTAssertEqual(opened, [.conversation("c1")])

        host.rootView.showAll()
        let window = try XCTUnwrap(controller.activityWindow?.window)
        XCTAssertTrue(window.isVisible)
        window.close()
    }

    func testMenuLayoutLimitsRowsAndKeepsTitles() {
        let activities = (0 ..< 6).map { makeActivity("t\($0)") }
        let layout = BackgroundActivityMenuLayout(activities: activities)

        XCTAssertEqual(layout.rows, ["t0", "t1", "t2", "t3"])
        XCTAssertEqual(layout.hiddenCount, 2)
        XCTAssertEqual(layout.titles["t2"], "T2")
        XCTAssertEqual(layout.height, BackgroundActivityMenuLayout.verticalPadding * 2
            + BackgroundActivityMenuLayout.headerHeight + 4 * BackgroundActivityRowView.height
            + BackgroundActivityMenuLayout.moreHeight)
        XCTAssertFalse(layout.isEmpty)

        let small = BackgroundActivityMenuLayout(activities: [makeActivity("x")])
        XCTAssertEqual(small.hiddenCount, 0)
        XCTAssertEqual(small.height, BackgroundActivityMenuLayout.verticalPadding * 2
            + BackgroundActivityMenuLayout.headerHeight + BackgroundActivityRowView.height)
        XCTAssertTrue(BackgroundActivityMenuLayout(activities: []).isEmpty)
    }

    func testAccessibilityTitleDescribesTasks() throws {
        let center = try makeCenter()
        let source = FakeActivitySource()
        center.register(source)
        XCTAssertEqual(StatusBarController.accessibilityTitle("Ready", center: center), "Ready")

        source.feed.publish([makeActivity("a"), makeActivity("f", state: .failed)])
        XCTAssertEqual(
            StatusBarController.accessibilityTitle("Ready", center: center),
            ["Ready", L("activity.accessibility", 1), L("activity.accessibility.attention")]
                .joined(separator: L("activity.accessibility.separator"))
        )
    }

    // MARK: - Dot

    func testIndicatorColorsAndAnimations() {
        XCTAssertNil(StatusItemActivityIndicator.color(for: .none))
        XCTAssertEqual(StatusItemActivityIndicator.color(for: .running), .systemBlue)
        XCTAssertEqual(StatusItemActivityIndicator.color(for: .attention), .systemOrange)
        XCTAssertNil(StatusItemActivityIndicator.animation(for: .none))
        let breathe = try? XCTUnwrap(StatusItemActivityIndicator.animation(for: .running))
        let blink = try? XCTUnwrap(StatusItemActivityIndicator.animation(for: .attention))
        XCTAssertEqual(breathe?.toValue as? CGFloat, 0.15)
        XCTAssertEqual(blink?.toValue as? CGFloat, 0.45)
        XCTAssertEqual(breathe?.autoreverses, true)
        XCTAssertEqual(breathe?.repeatCount, .infinity)
    }

    func testMarkImageFillsOnlyTheInfinityCutOut() throws {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let size = NSSize(width: 22, height: 22)
        let image = try XCTUnwrap(StatusItemActivityIndicator.markImage(
            symbol: StudioTheme.Symbol.brand, configuration: configuration, size: size, color: .systemBlue
        ))
        XCTAssertFalse(image.isTemplate)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        var colored = 0
        for x in 0 ..< 44 {
            for y in 0 ..< 44 {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                colored += 1
                XCTAssertGreaterThan(color.blueComponent, color.redComponent, "only the tint color is drawn")
            }
        }
        XCTAssertGreaterThan(colored, 20, "the ∞ cut-out is filled")
        XCTAssertLessThan(colored, 44 * 44 / 3, "the disc around the ∞ stays clear")
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(bitmap.colorAt(x: 22, y: 2)?.alphaComponent ?? 1, 0, accuracy: 0.05,
                       "the icon's ring is not tinted")
    }

    func testIndicatorBreathesOnlyWhileRunningWithMotionAllowed() throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let indicator = StatusItemActivityIndicator()
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        func apply(_ state: BackgroundActivityIndicator, reduceMotion: Bool = false) {
            indicator.apply(state, to: button, symbol: StudioTheme.Symbol.brand, configuration: configuration,
                            size: NSSize(width: 22, height: 22), reduceMotion: reduceMotion)
        }

        apply(.running)
        XCTAssertTrue(indicator.mark.superview === button)
        XCTAssertFalse(indicator.mark.isHidden)
        XCTAssertNotNil(indicator.mark.image)
        XCTAssertTrue(indicator.isAnimating)
        XCTAssertEqual(item.length, NSStatusItem.squareLength, "the icon keeps its width")
        XCTAssertNil(indicator.mark.hitTest(NSPoint(x: 5, y: 5)), "clicks reach the status bar button")
        let runningImage = indicator.mark.image
        apply(.running)
        XCTAssertTrue(indicator.mark.image === runningImage, "the tinted image is reused")

        apply(.running, reduceMotion: true)
        XCTAssertFalse(indicator.isAnimating)
        XCTAssertFalse(indicator.mark.isHidden, "without motion the ∞ stays tinted")

        apply(.attention)
        XCTAssertTrue(indicator.isAnimating)
        XCTAssertFalse(indicator.mark.image === runningImage)
        XCTAssertEqual(indicator.state, .attention)

        apply(.none)
        XCTAssertTrue(indicator.mark.isHidden)
        XCTAssertFalse(indicator.isAnimating)
        XCTAssertEqual(button.subviews.filter { $0 === indicator.mark }.count, 1)
    }

    // MARK: - Views and window

    func testRowsRenderEveryStateAndAction() {
        var states: [BackgroundActivity] = []
        for state in [BackgroundActivity.State.attention, .failed, .running, .paused, .waiting] {
            for kind in BackgroundActivity.Kind.allCases {
                var item = makeActivity("\(state)-\(kind)", kind: kind, state: state)
                item.actions = BackgroundActivity.Action.allCases
                item.progress = state == .waiting ? nil : 0.5
                item.route = .conversation("c")
                states.append(item)
            }
        }
        for item in states {
            for hover in [true, false] {
                render(BackgroundActivityRowView(activity: item, revealsActionsOnHover: hover) { _ in })
            }
        }
        for action in BackgroundActivity.Action.allCases {
            XCTAssertFalse(BackgroundActivityRowView.symbol(action).isEmpty)
            XCTAssertEqual(BackgroundActivityRowView.label(action), L("activity.action.\(action.rawValue)"))
            XCTAssertNotEqual(BackgroundActivityRowView.label(action), "activity.action.\(action.rawValue)")
        }
    }

    func testMenuSectionRendersLiveAndEndedRows() throws {
        let center = try makeCenter()
        let source = FakeActivitySource()
        center.register(source)
        let activities = (0 ..< 5).map { makeActivity("t\($0)") }
        source.feed.publish(activities)
        let layout = BackgroundActivityMenuLayout(activities: center.activities)
        source.feed.publish(Array(activities.dropFirst()))

        let item = BackgroundActivityMenuSection.menuItem(center: center, layout: layout,
                                                          perform: { _, _ in }, showAll: {})
        let view = try XCTUnwrap(item.view)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.height, layout.height)

        source.feed.publish([makeActivity("p", state: .paused)])
        render(BackgroundActivityMenuSection(center: center, layout: BackgroundActivityMenuLayout(
            activities: center.activities
        ), perform: { _, _ in }, showAll: {}))
    }

    func testWindowShowsActiveAndRecentTasks() throws {
        let center = try makeCenter()
        let source = FakeActivitySource()
        center.register(source)
        source.feed.publish([makeActivity("a", kind: .agent), makeActivity("d"), makeActivity("i", kind: .index)])
        source.feed.complete("done", kind: .download, title: "Done")

        for tab in [BackgroundActivityWindowView.Tab.active, .recent] {
            render(BackgroundActivityWindowView(center: center, tab: tab))
        }
        source.feed.publish([])
        center.clearRecent()
        for tab in [BackgroundActivityWindowView.Tab.active, .recent] {
            render(BackgroundActivityWindowView(center: center, tab: tab))
        }

        let (settings, _) = try makeSettings()
        let controller = BackgroundActivityWindowController(center: center, settingsStore: settings)
        controller.show(activate: false)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, L("activity.window.title"))
        XCTAssertEqual(window.identifier, BackgroundActivityWindowController.identifier)
        controller.show(activate: false)
        XCTAssertTrue(controller.window === window, "showing again reuses the window")
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        drain()
        window.close()
        XCTAssertNil(controller.window)
    }

    func testWindowCopy() {
        XCTAssertEqual(BackgroundActivityWindowView.groupTitle(.agent), L("activity.group.agent"))
        XCTAssertEqual(BackgroundActivityWindowView.groupTitle(.download), L("activity.group.download"))
        XCTAssertEqual(BackgroundActivityWindowView.groupTitle(.index), L("activity.group.index"))

        let now = Date(timeIntervalSince1970: 10000)
        let fresh = BackgroundActivityCompletion(activityID: "x", kind: .index, title: "X",
                                                 finishedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(BackgroundActivityWindowView.finished(fresh, now: now),
                       L("activity.window.finished", L("activity.window.justNow")))
        let older = BackgroundActivityCompletion(activityID: "x", kind: .index, title: "X",
                                                 finishedAt: now.addingTimeInterval(-600))
        XCTAssertNotEqual(BackgroundActivityWindowView.finished(older, now: now),
                          L("activity.window.finished", L("activity.window.justNow")))
    }

    // MARK: - Helpers

    private func makeController() throws -> (StatusBarController, BackgroundActivityCenter, FakeActivitySource) {
        let (settings, _) = try makeSettings()
        let center = BackgroundActivityCenter(settings: settings, notifications: NoopLocalNotificationService(),
                                              coalesceInterval: 0)
        let source = FakeActivitySource()
        center.register(source)
        let controller = StatusBarController(appState: AppStateStore(), settingsStore: settings,
                                             historyStore: ActivityEmptyHistoryStore(), activityCenter: center)
        controller.start()
        return (controller, center, source)
    }

    private func makeCenter() throws -> BackgroundActivityCenter {
        try BackgroundActivityCenter(settings: makeSettings().0, notifications: NoopLocalNotificationService(),
                                     coalesceInterval: 0)
    }

    private func makeSettings() throws -> (SettingsStore, String) {
        let suite = "BackgroundActivityUITests.\(UUID().uuidString)"
        suites.append(suite)
        return try (SettingsStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite))), suite)
    }

    private func render(_ view: some View) {
        let host = NSHostingView(rootView: view.frame(width: 520))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
    }

    /// Lets main queue work run; with a condition, waits up to two seconds for it.
    private func drain(until condition: (() -> Bool)? = nil) {
        let deadline = Date().addingTimeInterval(condition == nil ? 0.05 : 2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline && !(condition?() ?? false)
    }
}

private final class ActivityEmptyHistoryStore: HistoryStore {
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
        URL(fileURLWithPath: "/tmp/history.md")
    }
}
