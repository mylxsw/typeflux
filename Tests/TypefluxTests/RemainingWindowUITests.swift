import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct RemainingWindowUITests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: [InterfaceStyle.classic, .liquidGlass])
    func workflowChoicesAndSegmentsChangeTheirBindings(style: InterfaceStyle) async throws {
        try await UI.withFixture { _ in
            var selected = 0
            let content = AskWorkflowRadioList(choices: [
                AskWorkflowChoice(value: 0, title: "First", detail: "First choice"),
                AskWorkflowChoice(value: 1, title: "Second", detail: "Second choice")
            ], selection: selected, select: { selected = $0 }).environment(\.interfaceStyle, style)
            try await UI.withWindow(content) { _, host in
                let choice = try #require(UI.elements(in: host).first {
                    $0.role == NSAccessibility.Role.radioButton.rawValue && $0.label.contains("Second")
                })
                try choice.press()
                #expect(selected == 1)
            }
            let segments = AskWorkflowTabs(items: [.init(tab: 0, title: "Preview"), .init(tab: 1, title: "Output")],
                                           selection: Binding(get: { selected }, set: { selected = $0 }))
                .environment(\.interfaceStyle, style)
            try await UI.withWindow(segments) { _, host in
                try UI.button("Preview", in: host).press()
                #expect(selected == 0)
            }
        }
    }

    @Test func monitorSortUsesNativeSegments() async throws {
        try await UI.withFixture { _ in
            var sort = SystemMonitorSort.cpu
            let content = SystemMonitorSortPicker(sort: Binding(get: { sort }, set: { sort = $0 }),
                                                  options: [.cpu, .memory])
            try await UI.withWindow(content) { _, host in
                try UI.button(SystemMonitorMetricDisplay.sortTitle(.memory), in: host).press()
                #expect(sort == .memory)
            }
        }
    }

    @Test(arguments: [InterfaceStyle.classic, .liquidGlass])
    func aboutShowsAllMetadataAndLinks(style: InterfaceStyle) async throws {
        try await UI.withFixture { _ in
            for scheme in [ColorScheme.light, .dark] {
                let content = AboutView(appearanceMode: scheme == .dark ? .dark : .light)
                    .environment(\.interfaceStyle, style)
                try await UI.withWindow(content, width: 560, height: 640) { _, host in
                    try await UI.wait { UI.contains(L("about.build"), in: host) }
                    for title in ["about.developer", "about.website", "about.privacy", "about.project"] {
                        _ = try UI.button(L(title), in: host)
                    }
                }
            }
        }
    }

    @Test func updateActionsKeepBothChoicesReachable() async throws {
        try await UI.withFixture { _ in
            var updates = 0, skips = 0
            let content = UpdateAlertContentView(version: "1.2.3", releaseNotes: "# Changes", releaseURL: nil,
                                                 appearanceMode: .light,
                                                 onUpdate: { updates += 1 }, onSkip: { skips += 1 })
            try await UI.withWindow(content, width: 540, height: 440) { _, host in
                try UI.button(L("updater.action.skip"), in: host).press()
                try UI.button(L("updater.action.installAndRelaunch"), in: host).press()
                #expect(updates == 1 && skips == 1)
            }
        }
    }

    @Test func loginUsesNamedNativeSecureAndPlainFields() async throws {
        try await UI.withFixture { _ in
            let content = VStack {
                LoginTextField(placeholder: "Email", text: .constant("someone@example.test"), icon: "envelope")
                LoginTextField(placeholder: "Password", text: .constant("fixture-password"), icon: "lock",
                               isSecure: true)
            }
            try await UI.withWindow(content) { _, host in
                let views = UI.nativeViews(in: host).compactMap { $0 as? NSTextField }
                #expect(views.contains { $0.stringValue == "someone@example.test" })
                #expect(views.contains { $0 is NSSecureTextField })
                #expect(UI.elements(in: host).contains { $0.label == "Email" })
                #expect(UI.elements(in: host).contains { $0.label == "Password" })
            }
        }
    }

    @Test func feedbackActionsKeepSubmissionAndCancellation() async throws {
        try await UI.withFixture { _ in
            var submissions = 0, cancellations = 0
            let content = DirectFeedbackSheet(content: .constant("Useful feedback"), contact: .constant(""),
                                              images: .constant([]),
                                              isSubmitting: false, errorMessage: "Fixture failure", onAddImages: {},
                                              onRemoveImage: { _ in }, onCancel: { cancellations += 1 },
                                              onSubmit: { submissions += 1 })
            try await UI.withWindow(content, width: 480, height: 640) { _, host in
                #expect(UI.contains("Fixture failure", in: host))
                try UI.button(L("feedback.direct.submit"), in: host).press()
                try UI.button(L("common.cancel"), in: host).press()
                #expect(submissions == 1 && cancellations == 1)
            }
        }
    }

    @Test func clipboardContextTokensRetainClearAndResume() async throws {
        try await UI.withFixture { _ in
            var resumed = false
            try await UI.withWindow(ClipboardPausedChip(onResume: { resumed = true })) { _, host in
                try UI.button(L("clipboard.footer.paused"), in: host).press()
                #expect(resumed)
            }
            var cleared = false
            let filter = ClipboardAppFilter(bundleID: "example.editor", name: "Editor")
            try await UI.withWindow(ClipboardAppFilterChip(app: filter, onClear: { cleared = true })) { _, host in
                #expect(UI.contains("Editor", in: host))
                try UI.button(L("clipboard.filter.clear"), in: host).press()
                #expect(cleared)
            }
        }
    }
}
