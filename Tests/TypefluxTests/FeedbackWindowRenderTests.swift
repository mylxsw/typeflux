import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the production feedback window while editing (text, a file, a refused file and a
/// submit error) and after submitting, in light and dark. Set `TYPEFLUX_FEEDBACK_SNAPSHOTS=<dir>`
/// to keep the PNGs for visual review against `docs/design/feedback-window.html`.
@Suite("Feedback window rendering", .serialized, .exclusiveUIState)
@MainActor
struct FeedbackWindowRenderTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `the window renders every part in light and dark`() async throws {
        try await UI.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            // Classic draws an opaque backdrop, so the capture does not depend on the desktop.
            settings.interfaceStyle = .classic
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("feedback-render-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                let services = FeedbackServicesStub()
                let model = FeedbackWindowModel(services: services, defaultContact: { "me@example.com" })
                let controller = FeedbackWindowController(model: model)
                controller.show(settingsStore: settings)
                defer { controller.window?.close() }
                let window = try #require(controller.window)
                let textView = try #require(model.editor.textView)
                textView.insertText("按住 fn 说话后，松开没有插入文字。", replacementRange: textView.selectedRange())
                model.editorDidChange()

                let log = directory.appendingPathComponent("typeflux-\(dark).log")
                try Data(count: 860 * 1024).write(to: log)
                model.addFiles([log])
                try await UI.wait { model.attachments.first?.state.isReady == true }
                model.addFiles([directory.appendingPathComponent("logs.zip")])
                #expect(model.notice != nil, "an unsupported file is refused with a reason")
                model.errorMessage = L("feedback.error.server")

                try await UI.wait { shows(L("feedback.direct.contactField"), in: window) }
                #expect(UI.elements(in: window.contentView!).contains {
                    $0.value("accessibilityIdentifier") as? String == "feedback.footer.otherMenu"
                })
                #expect(shows(L("feedback.draft.clear"), in: window) == false)
                try capture(window, name: "feedback-editing-\(dark ? "dark" : "light")")

                model.errorMessage = nil
                model.submit()
                try await UI.wait { model.phase == .submitted }
                try await UI.wait { shows(L("feedback.success.title"), in: window) }
                #expect(shows(L("feedback.success.another"), in: window))
                try capture(window, name: "feedback-success-\(dark ? "dark" : "light")")
            }
        }
    }

    /// Combined containers (the pane header, the empty state) read several texts as one label.
    private func shows(_ text: String, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        return UI.elements(in: root).contains { $0.label.contains(text) || $0.text.contains(text) }
    }

    private func capture(_ window: NSWindow, name: String) throws {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 10000, "\(name) rendered blank")
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_FEEDBACK_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}
