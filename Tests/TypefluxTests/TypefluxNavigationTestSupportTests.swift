import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct TypefluxNavigationTestSupportTests {
    private struct FixtureFailure: Error {}

    @Test func `search commands use the supplied window without global key dispatch`() async throws {
        let states = [TypefluxSearchState(), TypefluxSearchState()]
        let views = states.map { state in
            AnyView(TypefluxWindow(title: "Search scope", search: state, searchPrompt: "Owned search") {
                Text("Sidebar")
            } detail: {
                Text("Content")
            })
        }
        try await TypefluxNavigationTestSupport.withWindows(views) { windows in
            let first = windows[0].window
            try await SettingsBehaviorTestSupport.wait("First window's native search") {
                first.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true
            }
            try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: first)
            let item = try #require(first.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first)
            #expect(states[0].isFocused && states[0].isExpanded)
            #expect(item.searchField.currentEditor() != nil)
            #expect(!states[1].isFocused && !states[1].isExpanded)
            states[0].query = "Owned query"
            try TypefluxNavigationTestSupport.sendKey(53, to: first)
            #expect(states[0].query.isEmpty && states[0].isExpanded)
            try TypefluxNavigationTestSupport.sendKey(53, to: first)
            #expect(!states[0].isFocused && !states[0].isExpanded)
            #expect(item.searchField.currentEditor() == nil)
            #expect(states[1].query.isEmpty && !states[1].isExpanded)
        }
    }

    @Test func `shared Dock window closures keep the UI test host present`() async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let previousDelegate = NSApp.delegate
        let dock = DockVisibilityController.shared
        for index in 0 ..< 8 {
            try await TypefluxNavigationTestSupport.withWindow(Text("Shared Dock window \(index)")) { window, _ in
                dock.windowDidShow(window)
                defer { dock.windowDidHide(window) }
                expectApplicationState(delegate: previousDelegate)
            }
            expectApplicationState(delegate: previousDelegate)
        }
        // A different window can still render after the last production-tracked window closes.
        try await TypefluxNavigationTestSupport.withWindow(Text("Following window")) { window, host in
            #expect(window.isVisible)
            try await SettingsBehaviorTestSupport.wait("Window following shared Dock closures") {
                SettingsBehaviorTestSupport.contains("Following window", in: host)
            }
        }
        expectApplicationState(delegate: previousDelegate)
    }

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
