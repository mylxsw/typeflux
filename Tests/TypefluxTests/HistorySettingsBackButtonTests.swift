import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct HistorySettingsBackButtonTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport

    @Test func `wired Back actions follow detail selection and toolbar scope`() async throws {
        try await withModels { model, _ in
            try await withWindow(model) { window, host, navigation in
                #expect(backButton(in: window) == nil)
                for _ in 0 ..< 2 {
                    try await openDetail(in: host, model: model, navigation: navigation)
                    try await RenderedUI.wait { backButton(in: window)?.isEnabled == true }
                    let back = try requireBackButton(in: window)
                    try sendBackAction(back)
                    try await RenderedUI.wait { !RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
                    try await RenderedUI.wait { backButton(in: window) == nil }
                    #expect(RenderedUI.contains("Back fixture", in: host))
                }
                model.navigate(to: .vocabulary)
                try await RenderedUI.wait { backButton(in: window) == nil }
                model.navigate(to: .history)
                try await RenderedUI.wait { backButton(in: window) == nil }
                try await openDetail(in: host, model: model, navigation: navigation)
                model.deleteHistoryRecord(id: try #require(model.displayedHistory.first?.id))
                try await RenderedUI.wait { !RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
                try await RenderedUI.wait { backButton(in: window) == nil }
            }
        }
    }

    @Test func `Back in one settings window leaves another window detail selected`() async throws {
        try await withModels { first, second in
            let recordID = try #require(first.displayedHistory.first?.id)
            #expect(second.displayedHistory.first?.id == recordID)
            // Each root owns its selection; model navigation avoids AX press on SwiftUI controls.
            let views = [first, second].map {
                AnyView(StudioView(viewModel: $0, initialHistoryID: recordID).frame(width: 1680, height: 820))
            }
            try await TypefluxNavigationTestSupport.withWindows(
                views, size: NSSize(width: 1680, height: 820)
            ) { windows in
                _ = try #require(windows.count == 2)
                let firstWindow = windows[0].window
                let firstHost = windows[0].host
                let secondWindow = windows[1].window
                let secondHost = windows[1].host
                try await waitForDetail(in: firstWindow, host: firstHost)
                try await waitForDetail(in: secondWindow, host: secondHost)
                let firstBack = try requireBackButton(in: firstWindow)
                let secondBack = try requireBackButton(in: secondWindow)
                #expect(firstBack !== secondBack)
                try sendBackAction(firstBack)
                try await RenderedUI.wait("First window returning to its history list") {
                    backButton(in: firstWindow) == nil
                        && !RenderedUI.contains(L("history.detail.rawTranscript"), in: firstHost)
                }
                #expect(!RenderedUI.contains(L("history.detail.rawTranscript"), in: firstHost))
                windows[0].close()
                #expect(!firstWindow.isVisible && secondWindow.isVisible)
                #expect(backButton(in: secondWindow)?.isEnabled == true)
                try await waitForDetail(in: secondWindow, host: secondHost)
                let currentSecondBack = try requireBackButton(in: secondWindow)
                #expect(currentSecondBack.isEnabled)
                try sendBackAction(currentSecondBack)
                try await RenderedUI.wait("Second window returning to its history list") {
                    backButton(in: secondWindow) == nil
                        && !RenderedUI.contains(L("history.detail.rawTranscript"), in: secondHost)
                }
                #expect(!RenderedUI.contains(L("history.detail.rawTranscript"), in: secondHost))
            }
        }
    }

    private func waitForDetail(in window: NSWindow, host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        do {
            try await RenderedUI.wait("History detail and Back in owned window \(window.windowNumber)") {
                backButton(in: window)?.isEnabled == true
                    && RenderedUI.contains(L("history.detail.rawTranscript"), in: host)
            }
        } catch {
            let back = backButton(in: window)
            Issue.record("Detail timeout: window \(window.windowNumber), Back present \(back != nil), enabled \(back?.isEnabled == true), host attached \(host.window === window)")
            throw error
        }
    }

    private func backButton(in window: NSWindow) -> NSButton? {
        guard let view = window.toolbar?.items.first(where: {
            $0.itemIdentifier.rawValue == HistorySettingsBackButton.toolbarIdentifier
        })?.view else { return nil }
        // Inspect the hosted control, never an AppKit-created toolbar proxy or a button retained across updates.
        var pending = [view]
        while let current = pending.popLast() {
            if let hosted = current as? HistorySettingsBackButton.ToolbarView, hosted.window === window {
                return hosted.button
            }
            pending.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func requireBackButton(in window: NSWindow) throws -> NSButton {
        let button = try #require(backButton(in: window))
        #expect(button.window === window)
        #expect(button.title.isEmpty && button.image != nil)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.toolTip == L("history.action.back"))
        #expect(button.accessibilityIdentifier() == HistorySettingsBackButton.accessibilityIdentifier)
        #expect(button.target is HistorySettingsBackButton.Coordinator)
        #expect(button.action == #selector(HistorySettingsBackButton.Coordinator.goBack(_:)))
        return button
    }

    private func sendBackAction(_ button: NSButton) throws {
        let action = try #require(button.action)
        #expect(NSApp.sendAction(action, to: button.target, from: button))
    }

    private func openDetail(in host: NSView, model: StudioViewModel,
                            navigation: HistorySettingsNavigation) async throws {
        try await RenderedUI.wait { RenderedUI.contains("Back fixture", in: host) }
        navigation.open(try #require(model.displayedHistory.first?.id))
        try await RenderedUI.wait { RenderedUI.contains(L("history.detail.rawTranscript"), in: host) }
    }

    private func withWindow(_ model: StudioViewModel,
                            _ check: (NSWindow, NSView, HistorySettingsNavigation) async throws -> Void) async throws {
        let navigation = HistorySettingsNavigation()
        try await TypefluxNavigationTestSupport.withWindow(
            StudioView(viewModel: model, historyNavigation: navigation).frame(width: 1680, height: 820),
            size: NSSize(width: 1680, height: 820)
        ) { window, host in try await check(window, host, navigation) }
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
