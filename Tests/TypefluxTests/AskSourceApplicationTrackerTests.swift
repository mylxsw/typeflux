import AppKit
import Testing
@testable import Typeflux

@Suite("Ask source application filtering", .exclusiveUIState)
@MainActor
struct AskSourceApplicationTrackerTests {
    @Test func systemUIFallsBackToTheLastOrdinaryApplicationWithoutSelection() {
        let tracker = AskSourceApplicationTracker(observeWorkspace: false, ownProcessID: 1, isRunning: { _ in true })
        let safari = ReadOnlySelectionRequest(processID: 10, processName: "Safari", bundleIdentifier: "com.apple.Safari")
        tracker.record(safari, regular: true)
        tracker.record(.init(processID: 1, processName: "Typeflux"), regular: true)
        tracker.record(.init(processID: 20, processName: "Helper"), regular: false)
        for name in ["UserNotificationCenter", "universalAccessAuthWarn", "loginwindow", "ScreenSaver", "SecurityAgent"] {
            let system = ReadOnlySelectionRequest(processID: 30, processName: name)
            tracker.record(system, regular: true)
            let fallback = tracker.resolve(system)
            #expect(fallback.processID == 10 && fallback.bundleIdentifier == safari.bundleIdentifier)
            #expect(fallback.id == system.id && fallback.nativeSnapshot?.selectedText == nil)
            #expect(fallback.nativeSnapshot?.source == "system-ui-fallback")
        }
        #expect(tracker.resolve(safari).id == safari.id)
        #expect(!AskSourceApplicationTracker.isSystemUI(safari))
        #expect(AskSourceApplicationTracker.isSystemUI(.init(bundleIdentifier: "com.apple.UserNotificationCenter")))
        #expect(AskSourceApplicationTracker.isSystemUI(.init(bundleIdentifier: "com.apple.ScreenSaver.Engine")))
        tracker.record(.init(), regular: true)
        #expect(tracker.resolve(.init(processName: "loginwindow")).processID == 10)
    }

    @Test func missingOrTerminatedSourceDoesNotInventAnApplication() {
        let tracker = AskSourceApplicationTracker(observeWorkspace: false, isRunning: { _ in false })
        let system = ReadOnlySelectionRequest(processID: 20, processName: "UserNotificationCenter")
        #expect(tracker.resolve(system).processID == nil)
        tracker.record(.init(processID: 10, processName: "Editor"), regular: true)
        #expect(tracker.resolve(system).processID == nil)
        // Exercise observer installation and removal without changing the desktop.
        _ = AskSourceApplicationTracker()
    }
}
