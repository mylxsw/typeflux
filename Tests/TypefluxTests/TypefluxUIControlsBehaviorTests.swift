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
        for kind in TypefluxButtonKind.allCases {
            try await withAccessibleWindow(TypefluxButton("Action", kind: kind) { actions += 1 }) { _, host in
                try activate("Action", in: host)
            }
        }
        #expect(actions == TypefluxButtonKind.allCases.count)
        try await withAccessibleWindow(TypefluxButton("Disabled") { actions += 1 }.disabled(true)) { _, host in
            let element = try SettingsBehaviorTestSupport.button("Disabled", in: host)
            #expect(element.value("isAccessibilityEnabled") as? Bool == false)
            try activate(element)
        }
        #expect(actions == TypefluxButtonKind.allCases.count)
        let icon = TypefluxIconButton("Copy document", systemImage: "doc.on.doc") { actions += 1 }
        try await withAccessibleWindow(icon) { _, host in
            try activate("Copy document", in: host)
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

    @Test func `default Return action respects disabled state`() async throws {
        var actions = 0
        for disabled in [false, true] {
            try await withAccessibleWindow(TypefluxButton("Save", kind: .primary, defaultAction: true) {
                actions += 1
            }.disabled(disabled)) { window, _ in
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
                ))
                _ = window.performKeyEquivalent(with: event)
                #expect(actions == 1)
            }
        }
    }

    @Test func `caller supplied keyboard shortcut remains active`() async throws {
        var actions = 0
        try await withAccessibleWindow(TypefluxButton("Copy") { actions += 1 }.keyboardShortcut("k")) { window, _ in
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "k",
                charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40
            ))
            #expect(window.performKeyEquivalent(with: event))
            #expect(actions == 1)
        }
    }

    @Test func `tokens remove once and navigation rows activate`() async throws {
        var removals = 0
        var navigations = 0
        try await withAccessibleWindow(VStack {
            TypefluxToken("Report.pdf", removeLabel: "Remove Report.pdf") { removals += 1 }
            TypefluxNavigationRow("Shortcuts", systemImage: "keyboard", color: .teal, detail: "6") { navigations += 1 }
            TypefluxKeyHint("⌘K", accessibilityLabel: "Command K")
        }) { _, host in
            try activate("Remove Report.pdf", in: host)
            try activate("Shortcuts", in: host)
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

    private func activate(_ title: String, in host: NSView) throws {
        let elements = SettingsBehaviorTestSupport.elements(in: host)
        let element = try #require(elements.first {
            $0.label == title && $0.object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }, "Missing \(title): \(elements.map { ($0.role, $0.label, $0.text) })")
        try activate(element)
    }

    private func activate(_ element: SettingsBehaviorTestSupport.Element) throws {
        if let button = element.object as? NSButton {
            button.performClick(nil)
        } else {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            _ = try #require(element.object.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let action = unsafeBitCast(element.object.method(for: selector), to: Press.self)
            // SwiftUI's PlatformSwitch can change its binding while returning false.
            // Assertions check the resulting model rather than this transport value.
            _ = action(element.object, selector)
        }
    }

    private func nativeViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { nativeViews(in: $0) }
    }

    private func dispatch(_ control: NSControl) throws {
        let action = try #require(control.action)
        #expect(NSApp.sendAction(action, to: control.target, from: control))
    }
}
