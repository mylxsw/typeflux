import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Permission mode composer", .serialized, .exclusiveUIState)
@MainActor
struct AskPermissionModeUITests {
    private func editor(_ view: NSView) -> AskComposerTextView.Editor? {
        if let field = view as? AskComposerTextView.Editor { return field }
        return view.subviews.lazy.compactMap(editor).first
    }

    @Test func returnChangesModeDuringApprovalWithoutSendingChat() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.setPermissionMode(.strict, launcher: true)
        await f.api.setTool(.init(id: "read", function: .init(name: "files", arguments: #"{"action":"read","path":"/project/README.md"}"#)))
        f.model.launcherDraft = AskDraft(text: "Read the project documentation", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        let size = NSSize(width: 950, height: 680)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: AskConversationView(model: f.model).environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let field = try #require(editor(hosting))
        window.makeFirstResponder(field)
        field.insertText("/mode yolo", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        try await Task.sleep(for: .milliseconds(100))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        field.keyDown(with: enter)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.permissionMode(launcher: false) == .yolo)
        #expect(f.tools.executions == 1)
        #expect(await f.api.sends.count == 1)
        #expect(f.model.draft.text.isEmpty)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_PERMISSION_SNAPSHOT"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("permission-mode.png"))
        }
    }
}
