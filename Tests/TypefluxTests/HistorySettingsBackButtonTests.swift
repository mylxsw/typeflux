import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct HistorySettingsBackButtonTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport

    @Test func `native and accessibility Back presses follow detail selection and toolbar scope`() async throws {
        try await withModels { model, _ in
            try await withWindow(model) { window, host in
                try await RenderedUI.wait { backButton(in: window) != nil }
                let back = try #require(backButton(in: window))
                #expect(!back.isEnabled)
                for accessibilityPress in [false, true] {
                    try await openDetail(in: host)
                    try await RenderedUI.wait { back.isEnabled }
                    if accessibilityPress {
                        #expect(back.accessibilityPerformPress())
                    } else {
                        back.performClick(nil)
                    }
                    try await RenderedUI.wait { !RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
                    try await RenderedUI.wait { !back.isEnabled }
                    #expect(RenderedUI.contains("Back fixture", in: host))
                }
                model.navigate(to: .vocabulary)
                try await RenderedUI.wait { backButton(in: window) == nil }
                model.navigate(to: .history)
                try await RenderedUI.wait { backButton(in: window)?.isEnabled == false }
            }
        }
    }

    @Test func `Back in one settings window leaves another window detail selected`() async throws {
        try await withModels { first, second in
            try await withWindow(first) { firstWindow, firstHost in
                try await withWindow(second) { secondWindow, secondHost in
                    try await openDetail(in: firstHost)
                    try await openDetail(in: secondHost)
                    try await RenderedUI.wait {
                        backButton(in: firstWindow)?.isEnabled == true && backButton(in: secondWindow)?.isEnabled == true
                    }
                    let firstBack = try #require(backButton(in: firstWindow))
                    let secondBack = try #require(backButton(in: secondWindow))
                    #expect(firstBack !== secondBack)
                    #expect(firstBack.accessibilityPerformPress())
                    try await RenderedUI.wait { !firstBack.isEnabled }
                    #expect(RenderedUI.contains(L("history.detail.rawTranscript"), in: secondHost))
                    #expect(secondBack.isEnabled)
                    secondBack.performClick(nil)
                    try await RenderedUI.wait { !secondBack.isEnabled }
                    #expect(!RenderedUI.contains(L("history.detail.rawTranscript"), in: secondHost))
                }
            }
        }
    }

    private func backButton(in window: NSWindow) -> NSButton? {
        guard let view = window.toolbar?.items.first(where: {
            $0.itemIdentifier.rawValue == HistorySettingsBackButton.toolbarIdentifier
        })?.view else { return nil }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        return descendants(view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == HistorySettingsBackButton.accessibilityIdentifier
        }
    }

    private func openDetail(in host: NSView) async throws {
        try await RenderedUI.wait { RenderedUI.contains("Back fixture", in: host) }
        try RenderedUI.button("Back fixture", in: host).press()
        try await RenderedUI.wait { RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
    }

    private func withWindow(_ model: StudioViewModel,
                            _ check: (NSWindow, NSView) async throws -> Void) async throws {
        try await TypefluxNavigationTestSupport.withWindow(
            StudioView(viewModel: model).frame(width: 1680, height: 820),
            size: NSSize(width: 1680, height: 820), run: check
        )
    }

    private func withModels(_ check: (StudioViewModel, StudioViewModel) async throws -> Void) async throws {
        try await RenderedUI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            settings.historyRetentionPolicy = .forever
            let store = SQLiteHistoryStore(baseDir: root)
            store.save(record: HistoryRecord(date: Date(), transcriptText: "Back fixture"))
            @MainActor func model() -> StudioViewModel {
                StudioViewModel(settingsStore: settings, historyStore: store, initialSection: .history,
                                modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                              automaticallyLoadsCatalog: false))
            }
            let first = model()
            let second = model()
            try await RenderedUI.wait { first.displayedHistory.count == 1 && second.displayedHistory.count == 1 }
            try await check(first, second)
        }
    }
}
