import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("TypefluxUI compatibility snapshots", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUICompatibilityVisualTests {
    @Test func `existing pages`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_UI_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previous) }
        let fixture = try AskTestFixture()
        defer {
            fixture.model.resetSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.model.launcherDraft = AskDraft(text: "Summarize this document", includeScreenshot: false)
        try await TypefluxUISnapshot.renderMatrix(AskLauncherView(model: fixture.model, onDismiss: {}),
                                                  size: NSSize(width: 700, height: 210), directory: root,
                                                  name: "launcher")
        try await TypefluxUISnapshot.renderMatrix(AskConversationView(model: fixture.model),
                                                  size: NSSize(width: 1100, height: 740), directory: root,
                                                  name: "conversation")
        let settings = StudioSettingRow(
            title: L("settings.interfaceStyle.title"),
            subtitle: L("settings.interfaceStyle.subtitle")
        ) {
            StudioSegmentedPicker(options: InterfaceStyle.allCases.map { (label: $0.displayName, value: $0) },
                                  selection: .constant(InterfaceStyle.classic))
                .frame(width: StudioTheme.Layout.appearancePickerWidth)
        }.padding(24).background(StudioTheme.surface)
        try await TypefluxUISnapshot.renderMatrix(settings, size: NSSize(width: 900, height: 120),
                                                  directory: root, name: "settings")
    }
}
