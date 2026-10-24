import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Shortcut diagnostics UI", .serialized, .exclusiveUIState)
@MainActor
struct ShortcutLatencyUITests {
    @Test func `renders dashboard and all stage labels`() {
        let view = NSHostingView(rootView: ShortcutLatencyDashboard(automaticRefresh: false))
        view.frame = .init(x: 0, y: 0, width: 1080, height: 720)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        for role in FeatureRole.allCases {
            let key = "shortcutDiagnostics.role." + role.rawValue
            #expect(L(key) != key)
        }
        for stage in ShortcutLatencyStage.allCases {
            let key = "shortcutDiagnostics.stage." + stage.rawValue
            #expect(L(key) != key)
        }
    }
}

extension ShortcutLatencyUITests {
    @Test func `renders resource snapshots without requesting app processes`() {
        var report = ShortcutLatencyReport(events: [])
        report.processes = [FeatureResourceSnapshot.capture(role: .host)]
        let view = NSHostingView(rootView: ShortcutLatencyDashboard(report: report, automaticRefresh: false))
        view.frame = .init(x: 0, y: 0, width: 1080, height: 720)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
    }
}

extension ShortcutLatencyUITests {
    @Test func `renders unified health and hang overview and shortcut details`() async throws {
        let trace = ShortcutLatencyTrace(id: UUID(), feature: .launcher, date: Date(), uptime: 100)
        var report = ShortcutLatencyReport(events: [
            ShortcutLatencyEvent(trace: trace, stage: .recognized, uptime: 100, pid: 1, role: .host, build: "fixture"),
            ShortcutLatencyEvent(trace: trace, stage: .targetWarm, uptime: 100.01, pid: 2, role: .launcher, build: "fixture"),
            ShortcutLatencyEvent(trace: trace, stage: .visibleNextTurn, uptime: 100.08, pid: 2, role: .launcher, build: "fixture")
        ])
        report.processes = [FeatureRole.host, .launcher, .clipboard, .screenshot, .translation].enumerated().map { index, role in
            FeatureResourceSnapshot(role: role, pid: Int32(index + 1), startedAt: 1, uptime: 100,
                                    footprintBytes: 150_000_000, cpuNanoseconds: 100,
                                    managedOperations: index, helperSlots: 0)
        }
        let health = ModuleHealth(state: .degraded, generation: UUID(), pendingStarts: 0,
                                  activeOperations: 1, hasLifecycleWork: false, failure: .quarantined)
        let bundle = DiagnosticsReport(generatedAt: Date(), rangeStart: nil, rangeEnd: nil,
                                       shortcuts: report, currentSnapshotAt: Date(),
                                       currentModules: ["conversations": health,
                                                        "wordBook": .init(state: .ready, generation: UUID(), pendingStarts: 0,
                                                                          activeOperations: 0, hasLifecycleWork: false, failure: nil),
                                                        "notebook": .init(state: .disabled, generation: UUID(), pendingStarts: 0,
                                                                          activeOperations: 0, hasLifecycleWork: false, failure: nil)],
                                       hangs: [.init(date: Date(), bytes: 100, id: "fixture")], unreadableHangFiles: 1,
                                       collectionFailures: ["resources"])
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }
        for (section, scheme, width, range) in [
            ("overview", ColorScheme.light, 1080.0, DiagnosticsTimeRange.minute5),
            ("overview", .dark, 900.0, .minute1),
            ("shortcuts", .light, 1080.0, .minute30),
            ("shortcuts", .dark, 900.0, .custom)
        ] {
            let view = NSHostingView(rootView: ShortcutLatencyDashboard(report: report, bundle: bundle,
                                                                        automaticRefresh: false,
                                                                        initialSection: section, initialRange: range,
                                                                        initialSelectedSample: trace.id)
                    .environment(\.colorScheme, scheme)
                    .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            view.frame = .init(x: 0, y: 0, width: width, height: width == 900 ? 580 : 720)
            // Native lists need an attached window and a render turn to populate their rows.
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0)
            if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_DIAGNOSTICS_SNAPSHOT_DIR"],
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: folder).appendingPathComponent("diagnostics-" + section + "-" + (scheme == .light ? "light" : "dark") + ".png")
                )
            }
        }
        for locale in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            let path = try #require(Bundle.module.path(forResource: locale, ofType: "lproj")
                ?? Bundle.module.path(forResource: locale.lowercased(), ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in ["diagnostics.export", "diagnostics.overview", "diagnostics.invalidRange",
                        "diagnostics.timeNote", "diagnostics.hangNote", "diagnostics.resources",
                        "diagnostics.health", "diagnostics.hangSamples", "diagnostics.module", "diagnostics.status"]
                + DiagnosticsTimeRange.allCases.map({ "diagnostics.range." + $0.rawValue }) {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key)
            }
            for stage in ShortcutLatencyStage.allCases {
                let key = "shortcutDiagnostics.stage." + stage.rawValue
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key)
            }
        }
    }
}
