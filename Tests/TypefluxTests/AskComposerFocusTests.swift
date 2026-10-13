import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskComposerFocusTests {
    @Test func focusRequestWaitsForEnablementAndDoesNotStealLaterInput() async throws {
        let presentation = AskWorkspaceState()
        let enablement = ComposerEnablement()
        let content = RequestedComposer(presentation: presentation, enablement: enablement)
        try await SettingsBehaviorTestSupport.withWindow(content, width: 440, height: 240) { window, host in
            try await SettingsBehaviorTestSupport.wait("Disabled composer") {
                SettingsBehaviorTestSupport.nativeViews(in: host).contains {
                    ($0 as? AskComposerTextView.Editor)?.isEditable == false
                }
            }
            let editor = try #require(SettingsBehaviorTestSupport.nativeViews(in: host)
                .compactMap { $0 as? AskComposerTextView.Editor }.first)
            window.makeFirstResponder(nil)
            presentation.focusComposer()
            try await Task.sleep(for: .milliseconds(30))
            #expect(window.firstResponder !== editor)
            enablement.enabled = true
            try await SettingsBehaviorTestSupport.wait("Enabled composer focus") { window.firstResponder === editor }
            let otherField = try #require(SettingsBehaviorTestSupport.nativeViews(in: host)
                .compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Other input" })
            #expect(window.makeFirstResponder(otherField))
            enablement.objectWillChange.send()
            try await Task.sleep(for: .milliseconds(30))
            #expect(window.firstResponder === otherField.currentEditor())
            presentation.focusComposer()
            try await SettingsBehaviorTestSupport.wait("A new composer focus request") {
                window.firstResponder === editor
            }
        }
    }
}

@MainActor
private final class ComposerEnablement: ObservableObject {
    @Published var enabled = false
}

private struct RequestedComposer: View {
    @ObservedObject var presentation: AskWorkspaceState
    @ObservedObject var enablement: ComposerEnablement

    var body: some View {
        VStack {
            TextField("Other input", text: .constant(""))
            AskComposerTextView(text: .constant(""), placeholder: "Compose",
                                focusRequestID: presentation.composerFocusRequestID, onSubmit: {})
                .disabled(!enablement.enabled)
        }
    }
}
