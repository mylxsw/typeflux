import AppKit
import SwiftUI
import Testing

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct TypefluxNavigationTestSupportTests {
    private struct FixtureFailure: Error {}

    @Test func `termination requests are cancelled and reported after restoring the delegate`() {
        _ = NSApplication.shared
        let previousDelegate = NSApp.delegate
        let lifetime = TypefluxTestApplicationLifetime(application: NSApp)
        // Invoke the delegate callback directly; never request a real process exit in a test.
        let reply = lifetime.applicationShouldTerminate(NSApp)
        var stacks: [[String]] = []
        lifetime.restore(reportingTo: { stacks.append($0) })
        #expect(reply == .terminateCancel)
        #expect(stacks.count == 1 && stacks.allSatisfy { !$0.isEmpty })
        #expect(NSApp.delegate === previousDelegate)
    }

    @Test func `closing a hosted window keeps the other window and restores the application scope`() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        let previousDelegate = NSApp.delegate
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (NSApp.accessibilityAttributeValue(attribute) as? Bool) ?? false
        var hostedWindows: [TypefluxNavigationTestSupport.HostedWindow] = []
        try await TypefluxNavigationTestSupport.withWindows([
            AnyView(Text("First")), AnyView(Text("Second"))
        ]) { windows in
            hostedWindows = windows
            #expect(NSApp.delegate is TypefluxTestApplicationLifetime)
            _ = try #require(windows.count == 2)
            windows[0].close()
            #expect(!windows[0].window.isVisible)
            #expect(windows[1].window.isVisible)
        }
        #expect(hostedWindows.allSatisfy { !$0.window.isVisible && $0.window.contentView == nil })
        #expect(NSApp.activationPolicy() == previousPolicy)
        #expect(NSApp.delegate === previousDelegate)
        #expect(((NSApp.accessibilityAttributeValue(attribute) as? Bool) ?? false) == previousAccessibility)
    }

    @Test func `a throwing multiwindow body still closes windows and restores its delegate`() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        let previousDelegate = NSApp.delegate
        var hostedWindows: [TypefluxNavigationTestSupport.HostedWindow] = []
        do {
            try await TypefluxNavigationTestSupport.withWindows([
                AnyView(Text("First")), AnyView(Text("Second"))
            ]) { windows in
                hostedWindows = windows
                throw FixtureFailure()
            }
            Issue.record("The window fixture must preserve its body error")
        } catch is FixtureFailure {
            #expect(hostedWindows.count == 2)
        }
        #expect(hostedWindows.allSatisfy { !$0.window.isVisible && $0.window.contentView == nil })
        #expect(NSApp.activationPolicy() == previousPolicy)
        #expect(NSApp.delegate === previousDelegate)
    }
}
