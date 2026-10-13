import AppKit
import Testing

/// A UI fixture owns windows; the Swift Testing runner owns the process lifetime.
@MainActor
final class AppKitTestApplication: NSObject, NSApplicationDelegate {
    private let application: NSApplication
    private let previousDelegate: NSApplicationDelegate?
    private let recordTermination: () -> Void
    private var restored = false

    init(recordTermination: @escaping () -> Void = {
        let stack = Thread.callStackSymbols.joined(separator: "\n")
        Issue.record("Unexpected application termination during a UI test.\n\(stack)")
    }) {
        application = NSApplication.shared
        previousDelegate = application.delegate
        self.recordTermination = recordTermination
        super.init()
        application.delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        recordTermination()
        return .terminateCancel
    }

    func restore() {
        guard !restored else { return }
        restored = true
        application.delegate = previousDelegate
    }
}
