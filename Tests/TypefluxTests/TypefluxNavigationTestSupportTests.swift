import AppKit
import SwiftUI
import Testing

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct TypefluxNavigationTestSupportTests {
    private struct FixtureFailure: Error {}

    @Test func `successive single and multiwindow fixtures keep the test process configured`() async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let previousDelegate = NSApp.delegate
        var firstWindow: NSWindow?
        try await SettingsBehaviorTestSupport.withFixture { _ in
            try await TypefluxNavigationTestSupport.withWindow(Text("First scope")) { window, _ in
                firstWindow = window
                expectApplicationState(delegate: previousDelegate)
            }
        }
        let closedWindow = try #require(firstWindow)
        #expect(!closedWindow.isVisible && closedWindow.contentView == nil)
        expectApplicationState(delegate: previousDelegate)
        try await SettingsBehaviorTestSupport.withFixture { _ in
            try await TypefluxNavigationTestSupport.withWindows([
                AnyView(Text("Second scope")), AnyView(Text("Third scope"))
            ]) { windows in
                #expect(windows.count == 2 && windows.allSatisfy { $0.window.isVisible })
                expectApplicationState(delegate: previousDelegate)
            }
        }
        expectApplicationState(delegate: previousDelegate)
    }

    @Test func `closing a hosted window keeps the other window and application state usable`() async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let previousDelegate = NSApp.delegate
        var hostedWindows: [TypefluxNavigationTestSupport.HostedWindow] = []
        try await TypefluxNavigationTestSupport.withWindows([
            AnyView(Text("First")), AnyView(Text("Second"))
        ]) { windows in
            hostedWindows = windows
            expectApplicationState(delegate: previousDelegate)
            _ = try #require(windows.count == 2)
            windows[0].close()
            #expect(!windows[0].window.isVisible)
            #expect(windows[1].window.isVisible)
            windows[0].close()
            #expect(windows[1].window.isVisible)
            expectApplicationState(delegate: previousDelegate)
        }
        #expect(hostedWindows.allSatisfy { !$0.window.isVisible && $0.window.contentView == nil })
        expectApplicationState(delegate: previousDelegate)
    }

    @Test func `a throwing multiwindow body closes windows without changing application state`() async throws {
        TypefluxTestApplicationEnvironment.prepare()
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
        expectApplicationState(delegate: previousDelegate)
    }

    private func expectApplicationState(delegate previousDelegate: NSApplicationDelegate?) {
        #expect(NSApp.activationPolicy() == .regular)
        #expect(NSApp.delegate === previousDelegate)
        let enhancedUI = NSApp.accessibilityAttributeValue(TypefluxTestApplicationEnvironment.enhancedUIAttribute) as? Bool
        #expect(enhancedUI == true)
    }
}
