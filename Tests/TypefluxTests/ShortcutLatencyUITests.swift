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
    @Test func `renders unified health and hang overview and shortcut details`() throws {
        var report = ShortcutLatencyReport(events: [])
        report.processes = [FeatureResourceSnapshot.capture(role: .host)]
        let health = ModuleHealth(state: .degraded, generation: UUID(), pendingStarts: 0,
                                  activeOperations: 1, hasLifecycleWork: false, failure: .quarantined)
        let bundle = DiagnosticsReport(generatedAt: Date(), rangeStart: nil, rangeEnd: nil,
                                       shortcuts: report, currentSnapshotAt: Date(),
                                       currentModules: ["conversations": health],
                                       hangs: [.init(date: Date(), bytes: 100, id: "fixture")], unreadableHangFiles: 1,
                                       collectionFailures: ["resources"])
        for section in ["overview", "shortcuts"] {
            let view = NSHostingView(rootView: ShortcutLatencyDashboard(report: report, bundle: bundle,
                                                                        automaticRefresh: false,
                                                                        initialSection: section)
                    .environment(\.colorScheme, .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: .aqua)
            view.frame = .init(x: 0, y: 0, width: 1080, height: 720)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0)
            if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_DIAGNOSTICS_SNAPSHOT_DIR"],
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: folder).appendingPathComponent("diagnostics-" + section + ".png")
                )
            }
        }
        for locale in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            let path = try #require(Bundle.module.path(forResource: locale, ofType: "lproj")
                ?? Bundle.module.path(forResource: locale.lowercased(), ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in ["diagnostics.export", "diagnostics.overview", "diagnostics.invalidRange",
                        "diagnostics.timeNote", "diagnostics.hangNote"] {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key)
            }
            for stage in ShortcutLatencyStage.allCases {
                let key = "shortcutDiagnostics.stage." + stage.rawValue
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key)
            }
        }
    }
}
