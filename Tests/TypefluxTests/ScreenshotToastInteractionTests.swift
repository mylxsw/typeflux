import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenshotToastInteractionTests {
    @Test func recordingRevealRespondsToFirstClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.mp4")
        try Data([1, 2, 3]).write(to: url)
        let model = ScreenRecordingToastModel(decode: { _ in throw CancellationError() })
        let controller = ScreenRecordingToastController(model: model)
        defer { controller.hide() }
        var revealed: [URL] = []
        controller.revealFile = { revealed.append($0) }
        controller.showSaved(url, thumbnail: nil, duration: 1)
        await model.task?.value
        #expect(model.ready)
        try await click(label: L("recording.reveal"), in: #require(controller.panel))
        await model.actionTask?.value
        #expect(revealed == [url])
    }

    @Test func screenshotRevealRespondsToFirstClick() async throws {
        let url = URL(fileURLWithPath: "/tmp/screenshot.png")
        var revealed: [URL] = []
        let controller = ScreenshotToastController { revealed.append($0) }
        defer { controller.hide() }
        controller.show(.saved(url))
        try await click(label: L("screenshot.toast.showInFinder"), in: #require(controller.panel))
        #expect(revealed == [url])
        #expect(controller.content == nil)
    }

    private func click(label: String, in panel: NSPanel) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let keyWindow = NSApp.keyWindow
        #expect(!panel.isKeyWindow)
        let host = try #require(panel.contentView)
        #expect(host.acceptsFirstMouse(for: nil))
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let button = try #require(SettingsBehaviorTestSupport.elements(in: panel).first {
            $0.label == label || $0.value("accessibilityTitle") as? String == label
        })
        let frame = try #require(button.value("accessibilityFrame") as? NSRect)
        let point = panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        #expect(NSApp.keyWindow === keyWindow)
    }
}
