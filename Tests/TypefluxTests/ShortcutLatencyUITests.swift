import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Shortcut diagnostics UI", .serialized, .exclusiveUIState)
@MainActor
struct ShortcutLatencyUITests {
    @Test func rendersDashboardAndAllStageLabels() {
        let view = NSHostingView(rootView: ShortcutLatencyDashboard())
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
