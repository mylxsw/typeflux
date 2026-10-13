import AppKit
import Testing

/// Keep an unexpected AppKit quit request observable instead of losing the Swift Testing host and its summary.
@MainActor
final class TypefluxTestApplicationLifetime: NSObject, NSApplicationDelegate {
    private let application: NSApplication
    private let previousDelegate: NSApplicationDelegate?
    private var terminationStacks: [[String]] = []

    init(application: NSApplication) {
        self.application = application
        previousDelegate = application.delegate
        super.init()
        application.delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        terminationStacks.append(Array(Thread.callStackSymbols.prefix(20)))
        return .terminateCancel
    }

    func restore(reportingTo report: ([String]) -> Void = { stack in
        Issue.record("AppKit requested termination during a window test:\n\(stack.joined(separator: "\n"))")
    }) {
        application.delegate = previousDelegate
        for stack in terminationStacks {
            report(stack)
        }
        terminationStacks.removeAll()
    }
}
