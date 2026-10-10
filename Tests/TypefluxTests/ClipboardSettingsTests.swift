import AppKit
@testable import Typeflux
import SwiftUI
import XCTest

/// Settings → Launcher → Clipboard: stored preferences, the settings model, and how the monitor,
/// store and panel placement apply them.
final class ClipboardSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suite = "ClipboardSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults)
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardSettingsTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Stored preferences

    func testDefaults() {
        XCTAssertTrue(settings.clipboardHistoryEnabled)
        XCTAssertFalse(settings.clipboardShowsPreview)
        XCTAssertEqual(settings.clipboardMaxItems, ClipboardMonitor.maximumItemCount)
        XCTAssertEqual(settings.clipboardStorageLimit, .gigabyte1)
        XCTAssertFalse(settings.clipboardPlainTextOnly)
        XCTAssertFalse(settings.clipboardSingleClickPastes)
        XCTAssertTrue(settings.clipboardSelectsFirstUnpinned)
        XCTAssertEqual(settings.clipboardPanelPosition, .launcher)
        XCTAssertNil(settings.clipboardPausedUntil)
        XCTAssertFalse(settings.isClipboardRecordingPaused())
        XCTAssertEqual(settings.clipboardCapturePolicy(), ClipboardCapturePolicy(
            isRecording: true, plainTextOnly: false, maxItemCount: 500, maxImageBytes: 1024 * 1024 * 1024,
            ignoredBundleIDs: Set(ClipboardIgnoredApp.defaults.map(\.bundleID))
        ))
    }

    func testRetentionFollowsTheOldHistorySettingUntilChosen() {
        for (policy, expected) in [
            (HistoryRetentionPolicy.never, ClipboardRetention.oneDay), (.oneDay, .oneDay),
            (.oneWeek, .oneWeek), (.oneMonth, .oneMonth), (.forever, .forever)
        ] {
            settings.historyRetentionPolicy = policy
            XCTAssertEqual(settings.clipboardRetention, expected)
        }
        settings.clipboardRetention = .threeMonths
        settings.historyRetentionPolicy = .oneDay
        XCTAssertEqual(settings.clipboardRetention, .threeMonths, "Once chosen it no longer follows voice history")
        defaults.set(12345, forKey: "clipboard.retentionDays")
        XCTAssertEqual(settings.clipboardRetention, .oneMonth, "Unknown values fall back")
    }

    func testValuesRoundTripAndRejectUnknownOnes() {
        settings.clipboardMaxItems = 2000
        settings.clipboardStorageLimit = .unlimited
        settings.clipboardPlainTextOnly = true
        settings.clipboardSingleClickPastes = true
        settings.clipboardShowsPreview = true
        settings.clipboardSelectsFirstUnpinned = false
        settings.clipboardPanelPosition = .mouse
        settings.clipboardHistoryEnabled = false
        XCTAssertEqual(settings.clipboardMaxItems, 2000)
        XCTAssertEqual(settings.clipboardStorageLimit, .unlimited)
        XCTAssertTrue(settings.clipboardPlainTextOnly)
        XCTAssertTrue(settings.clipboardSingleClickPastes)
        XCTAssertTrue(settings.clipboardShowsPreview)
        XCTAssertFalse(settings.clipboardSelectsFirstUnpinned)
        XCTAssertEqual(settings.clipboardPanelPosition, .mouse)
        XCTAssertEqual(settings.clipboardCapturePolicy(), ClipboardCapturePolicy(
            isRecording: false, plainTextOnly: true, maxItemCount: 2000, maxImageBytes: nil,
            ignoredBundleIDs: Set(ClipboardIgnoredApp.defaults.map(\.bundleID))
        ))

        settings.clipboardMaxItems = 7
        XCTAssertEqual(settings.clipboardMaxItems, ClipboardMonitor.maximumItemCount)
        defaults.set(3, forKey: "clipboard.storageLimitMB")
        XCTAssertEqual(settings.clipboardStorageLimit, .gigabyte1)
        defaults.set("nowhere", forKey: "clipboard.panelPosition")
        XCTAssertEqual(settings.clipboardPanelPosition, .launcher)
    }

    func testPauseEndsByItselfOrWhenResumed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .clipboardRecordingPauseDidChange, object: settings, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.pauseClipboardRecording(for: .fifteenMinutes, now: now)
        XCTAssertTrue(settings.isClipboardRecordingPaused(now: now))
        XCTAssertTrue(settings.isClipboardRecordingPaused(now: now.addingTimeInterval(14 * 60)))
        XCTAssertFalse(settings.isClipboardRecordingPaused(now: now.addingTimeInterval(15 * 60)))
        XCTAssertFalse(settings.clipboardCapturePolicy(now: now).isRecording)
        XCTAssertTrue(settings.clipboardCapturePolicy(now: now.addingTimeInterval(3600)).isRecording)

        settings.pauseClipboardRecording(for: .untilResumed, now: now)
        XCTAssertEqual(settings.clipboardPausedUntil, .distantFuture)
        XCTAssertTrue(settings.isClipboardRecordingPaused(now: now.addingTimeInterval(86400 * 365)))
        settings.resumeClipboardRecording()
        XCTAssertNil(settings.clipboardPausedUntil)
        XCTAssertFalse(settings.isClipboardRecordingPaused(now: now))
        XCTAssertEqual(posts, 3)
    }

    func testOptionTitlesAndValues() {
        XCTAssertEqual(ClipboardRetention.allCases.map(\.days), [1, 7, 30, 90, 365, nil])
        XCTAssertEqual(ClipboardRetention.oneWeek.id, 7)
        XCTAssertEqual(Set(ClipboardRetention.allCases.map(\.title)).count, ClipboardRetention.allCases.count)
        XCTAssertEqual(ClipboardStorageLimit.gigabytes2.bytes, 2048 * 1024 * 1024)
        XCTAssertNil(ClipboardStorageLimit.unlimited.bytes)
        XCTAssertEqual(ClipboardStorageLimit.unlimited.title, L("clipboard.settings.storage.unlimited"))
        XCTAssertEqual(
            ClipboardStorageLimit.gigabyte1.title,
            ByteCountFormatter.string(fromByteCount: 1 << 30, countStyle: .memory),
            "Binary units, so the option reads as a round number"
        )
        XCTAssertFalse(ClipboardStorageLimit.megabytes500.title.isEmpty)
        XCTAssertEqual(ClipboardStorageLimit.megabytes500.id, 500)
        XCTAssertEqual(ClipboardPanelPosition.screenCenter.id, "screenCenter")
        XCTAssertEqual(Set(ClipboardPanelPosition.allCases.map(\.title)).count, 3)
        XCTAssertEqual(ClipboardPauseDuration.allCases.map(\.interval), [900, 3600, nil])
        XCTAssertEqual(Set(ClipboardPauseDuration.allCases.map(\.title)).count, 3)
        XCTAssertEqual(ClipboardPauseDuration.oneHour.id, .oneHour)
        XCTAssertEqual(ClipboardItemLimit.options, [200, 500, 1000, 2000, 5000])
    }

    // MARK: - Settings model

    func testModelWritesEveryChangeThrough() {
        let model = ClipboardSettingsModel(store: settings)
        model.setHistoryEnabled(false)
        model.setRetention(.oneYear)
        model.setMaxItems(1000)
        model.setStorageLimit(.megabytes500)
        model.setPlainTextOnly(true)
        model.setSingleClickPastes(true)
        model.setShowsPreview(true)
        model.setSelectsFirstUnpinned(false)
        model.setPanelPosition(.screenCenter)

        XCTAssertFalse(settings.clipboardHistoryEnabled)
        XCTAssertEqual(settings.clipboardRetention, .oneYear)
        XCTAssertEqual(settings.clipboardMaxItems, 1000)
        XCTAssertEqual(settings.clipboardStorageLimit, .megabytes500)
        XCTAssertTrue(settings.clipboardPlainTextOnly)
        XCTAssertTrue(settings.clipboardSingleClickPastes)
        XCTAssertTrue(settings.clipboardShowsPreview)
        XCTAssertFalse(settings.clipboardSelectsFirstUnpinned)
        XCTAssertEqual(settings.clipboardPanelPosition, .screenCenter)

        let reloaded = ClipboardSettingsModel(store: settings)
        XCTAssertFalse(reloaded.historyEnabled)
        XCTAssertEqual(reloaded.retention, .oneYear)
        XCTAssertEqual(reloaded.maxItems, 1000)
        XCTAssertEqual(reloaded.storageLimit, .megabytes500)
        XCTAssertTrue(reloaded.plainTextOnly)
        XCTAssertTrue(reloaded.singleClickPastes)
        XCTAssertTrue(reloaded.showsPreview)
        XCTAssertFalse(reloaded.selectsFirstUnpinned)
        XCTAssertEqual(reloaded.panelPosition, .screenCenter)
    }

    func testModelPauseChoices() {
        var now = Date(timeIntervalSince1970: 2_000_000)
        let model = ClipboardSettingsModel(store: settings, now: { now })
        XCTAssertEqual(model.pause, .recording)
        XCTAssertEqual(model.pauseOptions.map(\.value), [
            .recording, .pause(.fifteenMinutes), .pause(.oneHour), .pause(.untilResumed)
        ])

        model.setPause(.pause(.oneHour))
        let until = now.addingTimeInterval(3600)
        XCTAssertEqual(model.pause, .pausedUntil(until))
        XCTAssertEqual(model.pauseOptions.count, 5, "The running pause is listed with its end time")
        XCTAssertEqual(model.pauseOptions[1].value, .pausedUntil(until))
        model.setPause(.pausedUntil(until))
        XCTAssertEqual(settings.clipboardPausedUntil, until, "Choosing the running pause changes nothing")

        model.setPause(.pause(.untilResumed))
        XCTAssertEqual(model.pause, .pause(.untilResumed))

        // The panel resumes recording: the open settings page follows.
        settings.resumeClipboardRecording()
        XCTAssertEqual(model.pause, .recording)

        model.setPause(.pause(.fifteenMinutes))
        now = now.addingTimeInterval(20 * 60)
        model.reloadPause()
        XCTAssertEqual(model.pause, .recording, "An expired pause reads as recording")
        model.setPause(.recording)
        XCTAssertNil(settings.clipboardPausedUntil)
    }

    @MainActor
    func testSettingsPaneDraws() throws {
        settings.pauseClipboardRecording(for: .oneHour)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: ScrollView {
                LauncherSettingsView(settings: settings, pane: .clipboard).padding(24)
            }.frame(width: 760, height: 1100))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 1100)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR"] {
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output)
                    .appendingPathComponent("clipboard-settings-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }

    @MainActor
    func testSettingsCanOpenAtTheClipboardPane() {
        let viewModel = StudioViewModel(
            settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: directory.appendingPathComponent("history")),
            initialSection: .settings
        )
        XCTAssertNil(viewModel.launcherPaneRequest)
        viewModel.navigate(toLauncherPane: .clipboard)
        XCTAssertEqual(viewModel.currentSection, .launcher)
        XCTAssertEqual(viewModel.launcherPaneRequest, .clipboard)
    }

    // MARK: - Applying the settings

    func testPlainTextOnlySkipsFilesAndImages() {
        let png = ClipboardTestSupport.imageData(width: 4, height: 4)
        let file = PasteboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])
        XCTAssertNotNil(ClipboardCaptureRules.capture(from: file))
        XCTAssertNil(ClipboardCaptureRules.capture(from: file, plainTextOnly: true))
        let image = PasteboardContents(imageData: png)
        XCTAssertNil(ClipboardCaptureRules.capture(from: image, plainTextOnly: true))
        let imageWithURL = PasteboardContents(string: "https://example.com/a.png", imageData: png)
        XCTAssertEqual(ClipboardCaptureRules.capture(from: imageWithURL, plainTextOnly: true), .text("https://example.com/a.png"))
        guard case .image = ClipboardCaptureRules.capture(from: imageWithURL) else {
            return XCTFail("Without the option the image wins")
        }
    }

    func testMonitorFollowsThePolicy() {
        final class Pasteboard: PasteboardReading {
            var changeCount = 0
            var contents = PasteboardContents()
            func readContents() -> PasteboardContents { contents }
        }
        let pasteboard = Pasteboard()
        let store = InMemoryClipboardHistoryStore()
        var policy = ClipboardCapturePolicy(isRecording: false, plainTextOnly: true, maxItemCount: 200, maxImageBytes: 99)
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, store: store, isEnabled: { true }, policy: { policy },
            sourceProvider: { nil }, suppression: ClipboardCaptureSuppression(gracePeriod: 0, uptime: { 0 })
        )
        monitor.start()
        defer { monitor.stop() }

        pasteboard.contents = PasteboardContents(string: "while paused")
        pasteboard.changeCount += 1
        XCTAssertFalse(monitor.poll(), "Paused: nothing is read")

        policy.isRecording = true
        pasteboard.contents = PasteboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])
        pasteboard.changeCount += 1
        XCTAssertTrue(monitor.poll())
        pasteboard.contents = PasteboardContents(string: "kept")
        pasteboard.changeCount += 1
        XCTAssertTrue(monitor.poll())
        monitor.drain()
        XCTAssertEqual(store.storedItems.compactMap(\.text), ["kept"], "Files are skipped in plain-text mode")
        XCTAssertEqual(store.trimCounts, [200])
        XCTAssertEqual(store.trimImageBytes, [99])

        policy.maxImageBytes = nil
        ClipboardMonitor.applyLimits(of: policy, to: store)
        XCTAssertEqual(store.trimImageBytes, [99], "No image limit, no image trim")
    }

    func testStoreTrimsImagesToTheByteLimitOldestFirstKeepingPinned() throws {
        let store = SQLiteClipboardHistoryStore(baseDir: directory, notificationCenter: NotificationCenter())
        func image(_ side: Int, at seconds: TimeInterval) throws -> ClipboardItem {
            let png = ClipboardTestSupport.imageData(width: side, height: side)
            return try XCTUnwrap(store.record(
                .image(png: png, pixelWidth: side, pixelHeight: side), source: nil,
                at: Date(timeIntervalSince1970: seconds)
            ))
        }
        let oldestPinned = try image(30, at: 1)
        store.setPinned(true, id: oldestPinned.id)
        let old = try image(31, at: 2)
        let middle = try image(32, at: 3)
        let newest = try image(33, at: 4)
        store.record(.text("text is not an image"), source: nil, at: Date(timeIntervalSince1970: 0))
        let total = [oldestPinned, old, middle, newest].reduce(Int64(0)) { $0 + $1.byteSize }

        store.trim(toMaxImageBytes: total)
        XCTAssertEqual(store.items(limit: 10).count, 5, "Within the limit nothing goes")

        store.trim(toMaxImageBytes: total - old.byteSize)
        var ids = Set(store.items(limit: 10).map(\.id))
        XCTAssertFalse(ids.contains(old.id))
        XCTAssertTrue(ids.contains(middle.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(old.imagePath)))

        store.trim(toMaxImageBytes: 0)
        ids = Set(store.items(limit: 10).map(\.id))
        XCTAssertEqual(ids.count, 2, "Only the pinned image and the text stay")
        XCTAssertTrue(ids.contains(oldestPinned.id))
    }

    func testPanelPositions() {
        let screen = NSRect(x: 0, y: 40, width: 1512, height: 900)
        let size = NSSize(width: 640, height: 560)
        let mouse = NSPoint(x: 700, y: 500)
        XCTAssertEqual(
            ClipboardPanelPlacement.frame(size: size, screen: screen, position: .launcher, mouse: mouse),
            ClipboardPanelPlacement.frame(size: size, screen: screen)
        )
        let center = ClipboardPanelPlacement.frame(size: size, screen: screen, position: .screenCenter, mouse: mouse)
        XCTAssertEqual(center.midX, screen.midX)
        XCTAssertEqual(center.midY, screen.midY)
        let atMouse = ClipboardPanelPlacement.frame(size: size, screen: screen, position: .mouse, mouse: mouse)
        XCTAssertEqual(atMouse.midX, mouse.x)
        XCTAssertEqual(atMouse.midY, mouse.y)
        let nearEdge = ClipboardPanelPlacement.frame(
            size: size, screen: screen, position: .mouse, mouse: NSPoint(x: 5, y: 45)
        )
        XCTAssertTrue(screen.contains(nearEdge), "Kept on screen")
    }
}
