import AppKit
@testable import Typeflux
import SwiftUI
import XCTest

/// Ignored apps and data usage in Launcher → Clipboard.
final class ClipboardDataSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suite = "ClipboardDataSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults)
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardDataSettingsTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeApp(_ name: String, bundleID: String?, displayName: String? = nil) throws -> URL {
        let app = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": name, "CFBundlePackageType": "APPL"]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testIgnoredAppsDefaultToPasswordAppsAndFeedThePolicy() {
        XCTAssertEqual(settings.clipboardIgnoredApps, ClipboardIgnoredApp.defaults)
        XCTAssertEqual(
            settings.clipboardCapturePolicy().ignoredBundleIDs, ["com.apple.keychainaccess", "com.apple.Passwords"]
        )
        settings.clipboardIgnoredApps = []
        XCTAssertEqual(settings.clipboardIgnoredApps, [], "Removing every app is remembered")
        XCTAssertTrue(settings.clipboardCapturePolicy().ignoredBundleIDs.isEmpty)
        defaults.set(Data("not json".utf8), forKey: "clipboard.ignoredApps")
        XCTAssertEqual(settings.clipboardIgnoredApps, ClipboardIgnoredApp.defaults)
    }

    func testIgnoredAppsAreAddedFromAppBundles() throws {
        let model = ClipboardSettingsModel(store: settings)
        let wechat = try makeApp("WeChat", bundleID: "com.tencent.xinWeChat", displayName: "微信")
        XCTAssertTrue(model.addIgnoredApp(at: wechat))
        XCTAssertTrue(model.addIgnoredApp(at: wechat), "Adding twice keeps one entry")
        XCTAssertEqual(model.ignoredApps.last, ClipboardIgnoredApp(bundleID: "com.tencent.xinWeChat", name: "微信"))
        XCTAssertEqual(settings.clipboardIgnoredApps.count, 3)

        let plain = try makeApp("Notes", bundleID: "com.apple.Notes")
        model.addIgnoredApp(at: plain)
        XCTAssertEqual(model.ignoredApps.last?.name, "Notes")
        XCTAssertFalse(model.addIgnoredApp(at: try makeApp("Broken", bundleID: nil)))
        XCTAssertFalse(model.addIgnoredApp(at: directory.appendingPathComponent("Missing.app")))

        model.removeIgnoredApp("com.apple.keychainaccess")
        XCTAssertEqual(settings.clipboardIgnoredApps.map(\.bundleID), [
            "com.apple.Passwords", "com.tencent.xinWeChat", "com.apple.Notes"
        ])
        XCTAssertEqual(ClipboardSettingsModel(store: settings).ignoredApps, model.ignoredApps)
    }

    func testMonitorNeverReadsCopiesFromIgnoredApps() {
        final class Pasteboard: PasteboardReading {
            var changeCount = 0
            var reads = 0
            func readContents() -> PasteboardContents {
                reads += 1
                return PasteboardContents(string: "secret")
            }
        }
        let pasteboard = Pasteboard()
        let store = InMemoryClipboardHistoryStore()
        var source = ClipboardSource(bundleID: "com.apple.keychainaccess", appName: "Keychain Access")
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, store: store, isEnabled: { true },
            policy: { ClipboardCapturePolicy(ignoredBundleIDs: ["com.apple.keychainaccess"]) },
            sourceProvider: { source }, suppression: ClipboardCaptureSuppression(gracePeriod: 0, uptime: { 0 })
        )
        monitor.start()
        defer { monitor.stop() }
        pasteboard.changeCount += 1
        XCTAssertFalse(monitor.poll())
        XCTAssertEqual(pasteboard.reads, 0)

        source = ClipboardSource(bundleID: "com.apple.Notes", appName: "Notes")
        pasteboard.changeCount += 1
        XCTAssertTrue(monitor.poll())
        monitor.drain()
        XCTAssertEqual(store.storedItems.compactMap(\.text), ["secret"])
    }

    func testUsageGroupsByAppAndSkipsReferencedFiles() {
        func item(_ payload: ClipboardItem.Payload, bytes: Int64, app: String?, name: String? = nil) -> ClipboardItem {
            ClipboardItem(
                id: UUID(), payload: payload, date: Date(), text: nil, filePaths: [], imagePath: nil,
                imagePixelWidth: nil, imagePixelHeight: nil, byteSize: bytes, contentHash: UUID().uuidString,
                sourceBundleID: app, sourceAppName: name, isPinned: false
            )
        }
        let usage = ClipboardUsage(items: [
            item(.text, bytes: 10, app: "com.apple.Notes", name: "Notes"),
            item(.image, bytes: 5000, app: "com.apple.Safari", name: "Safari"),
            item(.files, bytes: 9_000_000, app: "com.apple.finder", name: "Finder"),
            item(.text, bytes: 20, app: "com.apple.Notes", name: nil),
            item(.text, bytes: 7, app: nil),
            item(.text, bytes: 1, app: "")
        ])
        XCTAssertEqual(usage.apps.map(\.bundleID), ["com.apple.Safari", "com.apple.Notes", nil, "com.apple.finder"])
        XCTAssertEqual(usage.apps[1], ClipboardUsage.App(bundleID: "com.apple.Notes", name: "Notes", itemCount: 2, bytes: 30))
        XCTAssertEqual(usage.apps[2].itemCount, 2, "Missing and empty sources group together")
        XCTAssertEqual(usage.apps.last?.bytes, 0, "Copied files are referenced, not stored")
        XCTAssertEqual(usage.totalBytes, 5038)
        XCTAssertEqual(usage.totalCount, 6)
        XCTAssertEqual(usage.apps[2].id, "")
        XCTAssertEqual(ClipboardUsage(items: []).totalCount, 0)
    }

    func testModelShowsAndDeletesUsage() {
        let store = InMemoryClipboardHistoryStore()
        store.record(.text("a"), source: ClipboardSource(bundleID: "com.apple.Notes", appName: "Notes"), at: Date())
        store.record(.text("bb"), source: ClipboardSource(bundleID: "com.apple.Safari", appName: "Safari"), at: Date())
        let model = ClipboardSettingsModel(store: settings, history: store)
        XCTAssertNil(model.usage, "Loaded when the pane appears")
        model.reloadUsage()
        XCTAssertEqual(model.usage?.totalCount, 2)

        model.deleteUnpinned(bundleID: "com.apple.Safari")
        XCTAssertEqual(model.usage?.apps.map(\.bundleID), ["com.apple.Notes"])
        model.deleteUnpinned(bundleID: nil)
        XCTAssertEqual(model.usage?.totalCount, 0)

        store.record(.text("later"), source: nil, at: Date())
        NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
        let reloaded = expectation(description: "usage follows the store")
        DispatchQueue.main.async {
            XCTAssertEqual(model.usage?.totalCount, 1)
            reloaded.fulfill()
        }
        wait(for: [reloaded], timeout: 2)

        let withoutHistory = ClipboardSettingsModel(store: settings)
        withoutHistory.reloadUsage()
        withoutHistory.deleteUnpinned(bundleID: nil)
        XCTAssertNil(withoutHistory.usage)
    }

    @MainActor
    func testPaneDrawsIgnoredAppsAndUsage() throws {
        let store = InMemoryClipboardHistoryStore()
        store.record(.text("hello"), source: ClipboardSource(bundleID: "com.apple.Safari", appName: "Safari"), at: Date())
        store.record(.text("note"), source: nil, at: Date())
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: ScrollView {
                LauncherSettingsView(settings: settings, pane: .clipboard, clipboardHistory: store).padding(24)
            }.frame(width: 760, height: 1700))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 1700)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR"] {
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output)
                    .appendingPathComponent("clipboard-data-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
}
