import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@MainActor
@Suite("Native secure field behavior", .serialized, .exclusiveUIState)
struct TypefluxSecureFieldBehaviorTests {
    @Test func secureInputRetainsItsRoleNameAndProtectedEditing() async throws {
        let model = Model()
        try await SettingsBehaviorTestSupport.withWindow(SecureInput(model: model)) { window, host in
            let field = try #require(SettingsBehaviorTestSupport.nativeViews(in: host)
                .compactMap { $0 as? NSSecureTextField }.first)
            #expect(field.isAccessibilityElement())
            #expect(field.accessibilityRole() == .textField)
            #expect(field.accessibilitySubrole() == .secureTextField)
            #expect(field.accessibilityLabel() == "Private value")
            #expect(SettingsBehaviorTestSupport.elements(in: host).contains {
                $0.role == NSAccessibility.Role.textField.rawValue && $0.label == "Private value"
            })
            #expect(window.makeFirstResponder(field))
            let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
            editor.insertText("FixtureSecret1", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await SettingsBehaviorTestSupport.wait("Secure input updates its binding") {
                model.text == "FixtureSecret1"
            }
            #expect(field.accessibilityValue() as? String != model.text,
                    "Accessibility must not expose the private value")
            window.makeFirstResponder(nil)
            #expect(model.text == "FixtureSecret1")
        }
    }

    @Test func externalChangesAndDisabledStateReachTheNativeInput() async throws {
        let model = Model()
        try await SettingsBehaviorTestSupport.withWindow(SecureInput(model: model)) { window, host in
            let field = try #require(SettingsBehaviorTestSupport.nativeViews(in: host)
                .compactMap { $0 as? NSSecureTextField }.first)
            #expect(window.makeFirstResponder(field))
            let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
            model.text = "Replacement1"
            try await SettingsBehaviorTestSupport.wait("External secure value reaches the active editor") {
                field.stringValue == model.text && editor.string == model.text
            }
            model.text = ""
            try await SettingsBehaviorTestSupport.wait("Clearing a secure value clears its active editor") {
                field.stringValue.isEmpty && editor.string.isEmpty
            }
            window.makeFirstResponder(nil)
            model.enabled = false
            try await SettingsBehaviorTestSupport.wait("Secure input becomes disabled") { !field.isEnabled }
            #expect(field.accessibilityRole() == .textField)
            #expect(field.accessibilitySubrole() == .secureTextField)
            model.enabled = true
            try await SettingsBehaviorTestSupport.wait("Secure input becomes enabled") { field.isEnabled }
        }
    }

    private final class Model: ObservableObject {
        @Published var text = ""
        @Published var enabled = true
    }

    private struct SecureInput: View {
        @ObservedObject var model: Model
        var body: some View {
            TypefluxForm {
                TypefluxSettingsRow("Private value") {
                    TypefluxSecureField("Private value", text: $model.text).disabled(!model.enabled)
                }
            }
        }
    }
}
