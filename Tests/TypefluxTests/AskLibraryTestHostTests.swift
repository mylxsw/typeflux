import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Library test host residency", .serialized, .exclusiveUIState)
@MainActor
struct AskLibraryTestHostTests {
    private struct FixtureFailure: Error {}

    @Test func closingProductionLibrariesKeepsFollowingWindowFixturesUsable() async throws {
        let delegate = NSApp.delegate
        for _ in 0 ..< 2 {
            try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
                libraries.notes.window?.close()
                libraries.words.window?.close()
                expectHostState(delegate: delegate)
            }
            expectHostState(delegate: delegate)
            try await TypefluxNavigationTestSupport.withWindow(Text("Following fixture")) { window, host in
                #expect(window.isVisible)
                try await SettingsBehaviorTestSupport.wait("Window following production library closure") {
                    SettingsBehaviorTestSupport.contains("Following fixture", in: host)
                }
                expectHostState(delegate: delegate)
            }
            expectHostState(delegate: delegate)
        }
    }

    @Test func throwingWindowFixtureKeepsTheSharedDockPresentationAndRunnerDelegate() async throws {
        let delegate = NSApp.delegate
        var closed: NSWindow?
        var caught = false
        do {
            try await TypefluxNavigationTestSupport.withWindow(Text("Throwing fixture")) { window, _ in
                closed = window
                DockVisibilityController.shared.windowDidShow(window)
                defer { DockVisibilityController.shared.windowDidHide(window) }
                throw FixtureFailure()
            }
        } catch is FixtureFailure {
            caught = true
        }
        #expect(caught)
        #expect(closed?.isVisible == false && closed?.contentView == nil)
        TypefluxTestApplicationEnvironment.prepare()
        expectHostState(delegate: delegate)
        try await SettingsBehaviorTestSupport.withFixture { _ in
            try await TypefluxNavigationTestSupport.withWindow(Text("Recovered fixture")) { window, _ in
                #expect(window.isVisible)
                expectHostState(delegate: delegate)
            }
        }
        expectHostState(delegate: delegate)
    }

    @Test func cancelledReadinessPollingStopsWithoutLeavingAWaitingTask() async throws {
        let waiting = Task { @MainActor in
            try await SettingsBehaviorTestSupport.wait("Cancelled readiness polling") { false }
        }
        waiting.cancel()
        do {
            try await waiting.value
            Issue.record("A cancelled readiness wait must throw CancellationError")
        } catch is CancellationError {
            // The task is joined here; it cannot outlive the test case.
        }
    }

    private func expectHostState(delegate: (any NSApplicationDelegate)?) {
        #expect(NSApp.activationPolicy() == .regular)
        #expect(!NSApp.isHidden)
        #expect((NSApp.delegate as AnyObject?) === (delegate as AnyObject?))
        let attribute = TypefluxTestApplicationEnvironment.enhancedUIAttribute
        #expect(NSApp.accessibilityAttributeValue(attribute) as? Bool == true)
    }
}
