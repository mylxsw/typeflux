import AppKit
import Testing

/// Keep a failed window test from ending the test host before Swift Testing prints its result.
@MainActor
final class UITestApplicationLifetime: NSObject, NSApplicationDelegate {
    static func protecting(_ operation: @Sendable () async throws -> Void) async throws {
        let app = NSApplication.shared
        let previous = app.delegate
        let lifetime = UITestApplicationLifetime()
        app.delegate = lifetime
        defer { app.delegate = previous }
        try await operation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        Issue.record("An AppKit UI test requested application termination; the test host must stay alive")
        return .terminateCancel
    }
}
