import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in renders of the launcher and chat polish (GUL-280) with the production
/// views (set TYPEFLUX_ASK_SNAPSHOTS). Each launcher state is driven through the
/// real editor, then the window takes the height the launcher asked for, as the
/// panel does. Light and dark, at the 680 and 640 point launcher widths.
@Suite("Ask launcher polish snapshots", .serialized)
@MainActor
struct AskLauncherPolishVisualTests {
    @MainActor private final class Host {
        let window: AskTestVoiceWindow
        let hosting: NSView
        var height: CGFloat = 0

        init(_ fixture: AskTestFixture, width: CGFloat, appearance: NSAppearance.Name) {
            window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            var report: (CGFloat) -> Void = { _ in }
            let view = NSHostingView(rootView: AskLauncherView(model: fixture.model, onDismiss: {},
                                                               onHeightChange: { report($0) })
                .environment(\.askGlassMaterialOverride, .opaque))
            hosting = view
            window.contentView = view
            window.orderFront(nil)
            report = { [weak self] in self?.height = $0 }
        }

        var editor: AskComposerTextView.Editor? {
            func find(_ view: NSView) -> AskComposerTextView.Editor? {
                (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(hosting)
        }

        func type(_ text: String) async throws {
            let editor = try #require(editor)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(150))
        }

        func press(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) async throws {
            let editor = try #require(editor)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "",
                                                      charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
            editor.keyDown(with: event)
            try await Task.sleep(for: .milliseconds(150))
        }

        /// The panel takes the launcher's height, then the card is drawn.
        func snapshot(_ file: URL) async throws {
            try await Task.sleep(for: .milliseconds(300))
            if height > 0 {
                window.setContentSize(NSSize(width: window.frame.width, height: height))
                hosting.frame = NSRect(origin: .zero, size: window.frame.size)
            }
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: file)
            #expect(png.count > 4000)
        }

        func close() { window.orderOut(nil); window.close() }
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
    }

    private static let returnKey: UInt16 = 36

    /// The attach menu through the production glass presenter, over a window of chip
    /// text, captured from the screen so the real material (and what shows through it)
    /// is in the picture. Opt-in with TYPEFLUX_ASK_SCREEN_CAPTURE; nothing is clicked.
    @Test func captureMenuGlassOnScreen() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SCREEN_CAPTURE"] else { return }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let screen = try #require(NSScreen.main)
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let frame = NSRect(x: screen.frame.minX + 120, y: screen.frame.minY + 160, width: 420, height: 280)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.appearance = NSAppearance(named: appearance)
            let text = VStack(alignment: .leading, spacing: 6) {
                ForEach(0 ..< 10, id: \.self) { _ in
                    Text("prefix 关键词目录  history 聊天历史  gh GitHub").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                }
            }
            .padding(12)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(AskTheme.launcherSurface)
            let hosting = NSHostingView(rootView: text)
            window.contentView = hosting
            let anchor = NSView(frame: NSRect(x: 24, y: hosting.isFlipped ? frame.height - 30 : 10, width: 20, height: 20))
            hosting.addSubview(anchor)
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(300))
            AskGlassMenuPresenter.shared.show(AskAttachChoices(clipboardHasImage: false, choose: { _ in }),
                                              owner: UUID(), anchor: anchor) {}
            try await Task.sleep(for: .milliseconds(900))
            let menu = AskGlassMenuPresenter.shared.panel?.frame ?? .zero
            let area = frame.union(menu).insetBy(dx: -12, dy: -12)
            let top = screen.frame.maxY - area.maxY
            let file = URL(fileURLWithPath: directory).appendingPathComponent("06c-attach-menu-on-screen-\(theme).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-R\(Int(area.minX - screen.frame.minX)),\(Int(top)),\(Int(area.width)),\(Int(area.height))",
                                 file.path]
            try capture.run()
            capture.waitUntilExit()
            AskGlassMenuPresenter.shared.hide()
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func renderLauncherPolish() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }

        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for width in [CGFloat(680), 640] {
                let suffix = "\(theme)-\(Int(width)).png"
                func shot(_ name: String, text: String = "", selection: String? = nil,
                          prepare: (AskConversationModel) -> Void = { _ in },
                          drive: (Host) async throws -> Void) async throws {
                    let fixture = try AskTestFixture()
                    defer { fixture.model.resetSession() }
                    prepare(fixture.model)
                    fixture.model.launcherDraft = AskDraft(text: text, includeScreenshot: false, selection: selection)
                    let host = Host(fixture, width: width, appearance: appearance)
                    defer { host.close() }
                    try await Task.sleep(for: .milliseconds(300))
                    try await drive(host)
                    try await host.snapshot(output.appendingPathComponent("\(name)-\(suffix)"))
                }
                // 1. The keyword directory filtered down to one row, after typing pauses.
                try await shot("01-height-filtered", text: "prefix") { host in
                    try await host.press(Self.returnKey)
                    try await Task.sleep(for: .milliseconds(300))
                    try await host.type("gh")
                    try await Task.sleep(for: .milliseconds(900))
                }
                // 2. A plain question while the file index is still being built.
                try await shot("02-question-indexing", prepare: { model in
                    let index = AskTestFileIndex()
                    index.status = AskFileIndexStatus(phase: .building(found: 0, estimate: nil))
                    model.fileIndex = index
                }) { host in
                    try await host.type("用三句话介绍一下 Typeflux")
                }
                // 3. The keyword directory with nothing typed: no empty "Ask AI" row.
                try await shot("03-keyword-empty", text: "prefix") { host in
                    try await host.press(Self.returnKey)
                }
                // 4. A lone keyword: the highlighted row and the bar agree on Return.
                try await shot("04-history-hint", text: "history") { _ in }
                // 8. The home: "Open chat" keeps its label before anything is typed.
                try await shot("08-home-open-chat") { _ in }
                // 9. Chat history with nothing to list.
                try await shot("09-history-empty", text: "history") { host in
                    try await host.press(Self.returnKey)
                    try await Task.sleep(for: .milliseconds(300))
                }
                // 10. A kept draft whose screenshot was never taken.
                let fixture = try AskTestFixture()
                // The first opening takes the account; the next keeps the unfinished draft.
                await fixture.model.prepareLauncher()
                fixture.model.launcherDraft = AskDraft(text: "继续上次的问题", includeScreenshot: true)
                await fixture.model.prepareLauncher()
                let host = Host(fixture, width: width, appearance: appearance)
                try await host.snapshot(output.appendingPathComponent("10-screenshot-kept-draft-\(suffix)"))
                host.close()
                fixture.model.resetSession()
            }
        }
    }

    @Test func renderMenuAndSidebarPolish() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            // 6. The attach menu's glass over the launcher's keyword chips, drawn with the
            // translucent material so what is under the menu shows through as much as it would.
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            fixture.model.launcherDraft = AskDraft(text: "", includeScreenshot: false)
            let launcher = AskLauncherView(model: fixture.model, onDismiss: {})
                .environment(\.askGlassMaterialOverride, .opaque)
                .frame(width: 680, height: 240, alignment: .top)
            let menu = AskGlassCardSurface(corner: AskGlassCardSurface<EmptyView>.menuCorner) {
                AskAttachChoices(clipboardHasImage: false, choose: { _ in })
            }
            .environment(\.askGlassMaterialOverride, .visualEffect)
            .fixedSize()
            try await render(ZStack(alignment: .topLeading) {
                launcher
                menu.padding(.leading, 12).padding(.top, 70)
            }.frame(width: 680, height: 240, alignment: .topLeading).background(Color.gray.opacity(0.35)),
            size: NSSize(width: 680, height: 240), appearance: appearance,
            file: output.appendingPathComponent("06-attach-menu-\(theme).png"))

            // 6b. The same menu straight over chip text, where see-through glass hurts most.
            let chips = VStack(alignment: .leading, spacing: 6) {
                ForEach(0 ..< 8, id: \.self) { _ in
                    Text("prefix 关键词目录  history 聊天历史  gh GitHub").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                }
            }
            .padding(10)
            .frame(width: 340, height: 220, alignment: .topLeading)
            .background(AskTheme.launcherSurface)
            try await render(ZStack(alignment: .topLeading) {
                chips
                menu.padding(.leading, 20).padding(.top, 20)
            }.frame(width: 340, height: 220, alignment: .topLeading),
            size: NSSize(width: 340, height: 220), appearance: appearance,
            file: output.appendingPathComponent("06b-menu-over-text-\(theme).png"))

            // 7. The signed-out sidebar footer at the sidebar's 210 point width.
            let signedOut = try AskTestFixture(authenticated: false)
            defer { signedOut.model.resetSession() }
            let footer = HStack(spacing: 9) {
                AskLocalModeIdentity(model: signedOut.model).layoutPriority(1)
                Spacer(minLength: 4)
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(width: 210, height: 56)
            .background(AskTheme.popoverSurface)
            try await render(footer, size: NSSize(width: 210, height: 56), appearance: appearance,
                             file: output.appendingPathComponent("07-sidebar-footer-\(theme).png"))
        }
    }
}
