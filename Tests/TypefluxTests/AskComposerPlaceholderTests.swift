import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask composer IME placeholder", .serialized, .exclusiveUIState)
@MainActor
struct AskComposerPlaceholderTests {
    init() {
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
    }

    private func editor(in view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(editor(in:)).first
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func snapshot(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func composingCommittingAndCancellingRenderWithoutAnOverlappingHint() async throws {
        _ = NSApplication.shared
        let oldLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(oldLanguage) }
        let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_IME_SNAPSHOTS"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }

        for launcher in [true, false] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let fixture = try AskTestFixture(authenticated: false)
                fixture.model.appIndex = AskTestAppIndex([])
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: VStack {
                    AskComposer(model: fixture.model, launcher: launcher)
                    Spacer(minLength: 0)
                }.padding(20))
                host.sizingOptions = []
                window.contentView = host
                window.orderFront(nil)
                defer { window.close(); fixture.model.resetSession() }
                try await settle(host)
                let editor = try #require(editor(in: host))
                let scroll = try #require(editor.enclosingScrollView)
                let hint = editor.placeholder
                #expect(!hint.isEmpty)
                #expect(editor.showsPlaceholder)
                let initial = try snapshot(scroll)
                func draft() -> String { launcher ? fixture.model.launcherDraft.text : fixture.model.draft.text }
                func save(_ state: String) throws {
                    guard let directory else { return }
                    let surface = launcher ? "launcher" : "workspace"
                    let mode = appearance == .darkAqua ? "dark" : "light"
                    try snapshot(host).write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(surface)-\(mode)-\(state).png"))
                }
                try save("empty")

                editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                try await settle(host)
                // This is the original failure: the draft is still empty while
                // the native editor is already drawing uncommitted pinyin.
                #expect(draft().isEmpty)
                #expect(editor.hasMarkedText())
                #expect(editor.string == "nihao")
                #expect(!editor.showsPlaceholder)
                let composing = try snapshot(scroll)
                #expect(composing != initial)
                editor.placeholder = ""
                #expect(try snapshot(scroll) == composing)
                editor.placeholder = hint
                try save("composing")

                editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await settle(host)
                #expect(draft() == "你好")
                #expect(!editor.hasMarkedText())
                #expect(!editor.showsPlaceholder)
                try save("committed")

                editor.selectAll(nil)
                editor.deleteBackward(nil)
                try await settle(host)
                #expect(draft().isEmpty)
                #expect(editor.showsPlaceholder)
                #expect(try snapshot(scroll) == initial)

                editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                editor.unmarkText()
                try await settle(host)
                #expect(draft().isEmpty)
                #expect(editor.string.isEmpty)
                #expect(!editor.hasMarkedText())
                #expect(editor.showsPlaceholder)
                #expect(try snapshot(scroll) == initial)
                try save("cancelled")
            }
        }
    }

    @Test func wrappedWorkspaceHintsContributeToHeightButLauncherHintsStayOnOneLine() async throws {
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 240, height: 148))
        editor.font = .systemFont(ofSize: 16)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = AskComposerTextView.lineFragmentPadding
        editor.maximumHeight = 148
        var height: CGFloat = 0
        editor.onHeightChange = { height = $0 }
        editor.placeholder = String(repeating: "A long placeholder for a narrow composer. ", count: 4)
        try await settle(editor)
        #expect(height > 32)
        #expect(height <= 148)
        editor.placeholderSingleLine = true
        try await settle(editor)
        #expect(height == 32)
    }
}
