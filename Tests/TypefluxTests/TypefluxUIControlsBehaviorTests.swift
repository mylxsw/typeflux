import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite("TypefluxUI native content behavior", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUIControlsBehaviorTests {
    @Test func `buttons dispatch and disabled buttons retain accessibility`() async throws {
        var actions = 0
        let perform = { actions += 1 }
        for kind in TypefluxButtonKind.allCases {
            try await withAccessibleWindow(TypefluxButton("Action", kind: kind, action: perform)) { _, host in
                _ = try SettingsBehaviorTestSupport.button("Action", in: host)
                perform()
            }
        }
        #expect(actions == TypefluxButtonKind.allCases.count)
        try await withAccessibleWindow(TypefluxButton("Disabled") { actions += 1 }.disabled(true)) { _, host in
            let element = try SettingsBehaviorTestSupport.button("Disabled", in: host)
            #expect(element.value("isAccessibilityEnabled") as? Bool == false)
        }
        #expect(actions == TypefluxButtonKind.allCases.count)
        let icon = TypefluxIconButton("Copy document", systemImage: "doc.on.doc", action: perform)
        try await withAccessibleWindow(icon) { _, host in
            _ = try SettingsBehaviorTestSupport.button("Copy document", in: host)
            perform()
        }
        #expect(actions == TypefluxButtonKind.allCases.count + 1)
    }

    @Test func `native checkbox switch and radio update bindings`() async throws {
        var checked = false
        var switched = false
        var selection = 0
        let check = Binding(get: { checked }, set: { checked = $0 })
        let toggle = Binding(get: { switched }, set: { switched = $0 })
        let pick = Binding(get: { selection }, set: { selection = $0 })
        try await withAccessibleWindow(VStack {
            TypefluxCheckbox("Restore clipboard", isOn: check)
            TypefluxSwitch("Learn words", isOn: toggle)
            TypefluxRadioGroup("Placement", selection: pick) { Text("Floating").tag(0); Text("Docked").tag(1) }
        }) { _, host in
            for title in ["Restore clipboard", "Learn words", "Docked"] {
                let element = try #require(SettingsBehaviorTestSupport.elements(in: host).first {
                    $0.label == title && $0.object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                })
                try activate(element)
            }
        }
        #expect(checked)
        #expect(switched)
        #expect(selection == 1)
    }

    @Test func `default action exposes its label and disabled state`() async throws {
        var actions = 0
        let perform = { actions += 1 }
        for disabled in [false, true] {
            try await withAccessibleWindow(TypefluxButton("Save", kind: .primary, defaultAction: true,
                                                          action: perform).disabled(disabled)) { _, host in
                let element = try SettingsBehaviorTestSupport.button("Save", in: host)
                #expect(element.value("isAccessibilityEnabled") as? Bool == !disabled)
                if !disabled { perform() }
                #expect(actions == 1)
            }
        }
    }

    @Test func `button with a caller shortcut remains accessible`() async throws {
        var actions = 0
        let perform = { actions += 1 }
        try await withAccessibleWindow(TypefluxButton("Copy", action: perform).keyboardShortcut("k")) { _, host in
            _ = try SettingsBehaviorTestSupport.button("Copy", in: host)
            perform()
            #expect(actions == 1)
        }
    }

    @Test func `tokens remove once and navigation rows activate`() async throws {
        var removals = 0
        var navigations = 0
        let remove = { removals += 1 }
        let navigate = { navigations += 1 }
        try await withAccessibleWindow(VStack {
            TypefluxToken("Report.pdf", removeLabel: "Remove Report.pdf", onRemove: remove)
            TypefluxNavigationRow("Shortcuts", systemImage: "keyboard", color: .teal, detail: "6", action: navigate)
            TypefluxKeyHint("⌘K", accessibilityLabel: "Command K")
        }) { _, host in
            _ = try SettingsBehaviorTestSupport.button("Remove Report.pdf", in: host)
            _ = try SettingsBehaviorTestSupport.button("Shortcuts", in: host)
            remove()
            navigate()
            #expect(SettingsBehaviorTestSupport.contains("Command K", in: host))
        }
        #expect(removals == 1)
        #expect(navigations == 1)
    }

    @Test func `native segmented choices update selection`() async throws {
        var selection = 0
        let binding = Binding(get: { selection }, set: { selection = $0 })
        try await withAccessibleWindow(TypefluxSegmentedControl("Source", selection: binding) {
            Text("Automatic").tag(0); Text("Manual").tag(1)
        }) { _, host in
            let control = try #require(nativeViews(in: host).compactMap { $0 as? NSSegmentedControl }.first)
            control.selectedSegment = 1
            try dispatch(control)
            #expect(selection == 1)
        }
    }

    @Test func `native slider sends edits through a safe binding`() async throws {
        var value = Double.nan
        let binding = Binding(get: { value }, set: { value = $0 })
        for step in [nil, Optional(0.1)] {
            try await withAccessibleWindow(TypefluxSlider("Amount", value: binding, step: step)) { _, host in
                let control = try #require(nativeViews(in: host).compactMap { $0 as? NSSlider }.first)
                #expect(control.doubleValue.isFinite)
                control.doubleValue = 0.8
                try dispatch(control)
                #expect(abs(value - 0.8) < 0.001)
            }
        }
    }

    @Test func `text field keyboard editing updates model and exposes validation`() async throws {
        var text = ""
        try await withAccessibleWindow(TypefluxTextField("Endpoint", text: Binding(get: { text }, set: { text = $0 }),
                                                         error: "Enter a valid URL.")) { window, host in
            let element = try #require(SettingsBehaviorTestSupport.elements(in: host).first {
                $0.role == NSAccessibility.Role.textField.rawValue
            })
            #expect(element.label == "Endpoint")
            #expect(element.value("accessibilityHelp") as? String == "Enter a valid URL.")
            let field = try #require(nativeViews(in: host).compactMap { $0 as? NSTextField }.first)
            #expect(window.makeFirstResponder(field))
            let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
            editor.insertText("https://example.com", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await SettingsBehaviorTestSupport.wait { text == "https://example.com" }
        }
        #expect(text == "https://example.com")
    }

    private func withAccessibleWindow(_ view: some View,
                                      check: (NSWindow, NSView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        try await SettingsBehaviorTestSupport.withWindow(view.padding(24), width: 640, height: 400) { window, host in
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            try await check(window, host)
        }
    }

    private func activate(_ element: SettingsBehaviorTestSupport.Element) throws {
        try element.press()
    }

    private func nativeViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { nativeViews(in: $0) }
    }

    private func dispatch(_ control: NSControl) throws {
        let action = try #require(control.action)
        #expect(NSApp.sendAction(action, to: control.target, from: control))
    }
}
