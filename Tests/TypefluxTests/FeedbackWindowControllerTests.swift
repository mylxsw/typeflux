import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackWindowControllerTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func makeController() -> (FeedbackWindowController, FeedbackServicesStub) {
        let services = FeedbackServicesStub()
        let model = FeedbackWindowModel(services: services, defaultContact: { "me@example.com" })
        return (FeedbackWindowController(model: model), services)
    }

    @Test func `the window is a normal titled window of the designed size`() async throws {
        try await UI.withFixture { settings in
            let (controller, _) = makeController()
            controller.window?.close()
            #expect(!controller.isPresented)
            controller.show(settingsStore: settings)
            defer { controller.window?.close() }

            let window = try #require(controller.window)
            #expect(window.isVisible && controller.isPresented)
            #expect(window.title == L("feedback.direct.title"))
            #expect(window.styleMask.contains(.titled) && window.styleMask.contains(.resizable))
            #expect(window.attachedSheet == nil && window.sheetParent == nil)
            #expect(window.level == .normal)
            #expect(window.contentMinSize == FeedbackWindowView.minimumSize)
            #expect(window.contentView != nil)
            try await UI.wait { UI.contains(L("feedback.direct.intro"), in: window.contentView!) }
            #expect(UI.contains(L("feedback.attachment.add"), in: window.contentView!))
            #expect(UI.contains(L("feedback.direct.submit"), in: window.contentView!))
            #expect(UI.contains("me@example.com", in: window.contentView!))
        }
    }

    @Test func `showing an open window brings the same window forward`() async throws {
        try await UI.withFixture { settings in
            let (controller, _) = makeController()
            controller.show(settingsStore: settings)
            defer { controller.window?.close() }
            let first = try #require(controller.window)
            controller.show()
            #expect(controller.window === first)
        }
    }

    @Test func `closing keeps the draft and reopening restores it`() async throws {
        try await UI.withFixture { settings in
            let (controller, _) = makeController()
            controller.show(settingsStore: settings)
            let window = try #require(controller.window)
            let textView = try #require(controller.model.editor.textView)
            textView.insertText("half written", replacementRange: textView.selectedRange())
            controller.model.editorDidChange()

            controller.close()
            #expect(!window.isVisible)
            #expect(controller.model.hasText)

            controller.show()
            defer { controller.window?.close() }
            #expect(window.isVisible)
            #expect(controller.model.isDraftRestored)
            #expect(controller.model.editor.textView?.string == "half written")
        }
    }

    @Test func `a submission in flight cannot be closed`() async throws {
        try await UI.withFixture { settings in
            let (controller, services) = makeController()
            controller.show(settingsStore: settings)
            defer { controller.window?.close() }
            let window = try #require(controller.window)
            #expect(controller.windowShouldClose(window))

            services.submitDelayNanoseconds = 500_000_000
            let textView = try #require(controller.model.editor.textView)
            textView.insertText("hello", replacementRange: textView.selectedRange())
            controller.model.editorDidChange()
            controller.model.submit()
            #expect(controller.model.isSubmitting)
            #expect(!controller.windowShouldClose(window))
            try await UI.wait { controller.model.phase == .submitted }
            #expect(controller.windowShouldClose(window))
        }
    }

    @Test(arguments: [AppearanceMode.light, .dark, .system])
    func `the window follows the app appearance`(mode: AppearanceMode) async throws {
        try await UI.withFixture { settings in
            settings.appearanceMode = mode
            let (controller, _) = makeController()
            controller.show(settingsStore: settings)
            defer { controller.window?.close() }
            let expected: NSAppearance.Name? = switch mode {
            case .light: .aqua
            case .dark: .darkAqua
            default: nil
            }
            #expect(controller.window?.appearance?.name == expected)
        }
    }

    @Test func `renders every state for visual review`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_FEEDBACK_SNAPSHOT_DIR"] else { return }
        try await UI.withFixture { settings in
            for mode in [AppearanceMode.light, .dark] {
                settings.appearanceMode = mode
                let (controller, services) = makeController()
                controller.show(settingsStore: settings)
                let window = try #require(controller.window)
                window.setContentSize(FeedbackWindowView.defaultSize)
                let model = controller.model
                let textView = try #require(model.editor.textView)

                try save(window, "\(mode)-empty", to: directory)

                textView.insertText(
                    "Dictation does not start after the shortcut.\n",
                    replacementRange: textView.selectedRange()
                )
                textView.toggleBlock(.numberedList)
                textView.insertText(
                    "Press the shortcut\nSpeak a sentence\n",
                    replacementRange: textView.selectedRange()
                )
                model.editorDidChange()
                let png = pngData(width: 800, height: 500)
                model.addImageData(png, filename: "screenshot.png")
                try model.addFiles([sampleFile("typeflux.log", bytes: 4096)])
                services.videoError = FeedbackMediaError.videoStillTooLarge(compressedBytes: 161 * 1024 * 1024)
                try model.addFiles([sampleFile("recording.mov", bytes: 64)])
                try await UI.wait { !model.attachments.contains { $0.state.isInProgress } }
                try save(window, "\(mode)-editing", to: directory)
                controller.close()
            }
        }
    }

    private func save(_ window: NSWindow, _ name: String, to directory: String) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func sampleFile(_ name: String, bytes: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func pngData(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
