import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Production windows captured through the window server so Liquid Glass is
/// included. Fixtures are synthetic and never contact accounts or providers.
@Suite("Ask light v4 screenshots", .serialized, .exclusiveUIState)
@MainActor
struct AskLightV4SnapshotTests {
    @Test func `review screenshots`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_LIGHT_V4_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let sidebar = UserDefaults.standard.object(forKey: "ask.sidebarCollapsed")
        UserDefaults.standard.set(false, forKey: "ask.sidebarCollapsed")
        defer {
            if let sidebar {
                UserDefaults.standard.set(sidebar, forKey: "ask.sidebarCollapsed")
            } else {
                UserDefaults.standard.removeObject(forKey: "ask.sidebarCollapsed")
            }
        }

        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let time = Date(timeIntervalSince1970: 1_791_720_000)
        let conversation = makeConversation(time: time)
        await fixture.api.seed(conversation)
        try await fixture.cache.save(conversation, owner: fixture.sessionState.owner)
        await fixture.model.loadCachedHistoryIfNeeded()
        try await capture(AskConversationView(model: fixture.model), size: NSSize(width: 1200, height: 780),
                          file: root.appendingPathComponent("conversation-empty-glass-light.png"))
        await fixture.model.select(conversation.id)
        for (style, dark, name) in [(InterfaceStyle.liquidGlass, false, "glass-light"),
                                    (.classic, false, "classic-light"), (.liquidGlass, true, "glass-dark")] {
            try await capture(AskConversationView(model: fixture.model), size: NSSize(width: 1200, height: 780),
                              style: style, dark: dark,
                              file: root.appendingPathComponent("conversation-messages-\(name).png"))
        }

        try await captureNotebook(conversation: conversation, time: time, root: root)
        try await captureWordbook(time: time, root: root)

        try await captureFloating(fixture: fixture, root: root)
    }

    private func makeConversation(time: Date) -> AskConversation {
        AskConversation(id: "light-v4", title: "帮我取一组适合管姓小朋友的名字", revision: 1,
                        updatedAt: time, messages: [
                            AskMessage(
                                id: "question",
                                role: "user",
                                text: "帮我取一组适合管姓小朋友的名字，包括大名和小名。",
                                createdAt: time
                            ),
                            AskMessage(id: "answer", role: "assistant", text: """
                            可以从平安、成长和温柔这几个方向来选择：

                            - **管知远**，小名「知知」：知书达理，志向高远。
                            - **管安禾**，小名「安安」：平安顺遂，如禾苗茁壮。
                            - **管予棠**，小名「糖糖」：温柔明亮。

                            如果希望更贴近家庭的寓意，可以继续告诉我喜欢的字或风格。
                            """, createdAt: time)
                        ])
    }

    private func captureFloating(fixture: AskTestFixture, root: URL) async throws {
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.includeScreenshot = true
        fixture.model.launcherDraft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        fixture.model.launcherDraft.memoryOff = false
        fixture.model.launcherDraft.source = nil
        fixture.model.launcherDraft.selection = nil
        let home = AskLauncherSuggestions.height(for: fixture.model.launcherHome())
        let launcherSize = NSSize(width: AskMetrics.launcherWidth,
                                  height: AskMetrics.launcherHeight(editor: 32, banners: 0, suggestions: home))
        for backdrop in [Color.black, .white] {
            let name = backdrop == .black ? "desktop" : "window"
            try await capture(AskLauncherView(model: fixture.model, onDismiss: {}), size: launcherSize,
                              backdrop: backdrop, file: root.appendingPathComponent("launcher-glass-light-\(name).png"))
        }
        let clipboard = ClipboardPanelModel()
        clipboard.reset(entries: [ClipboardTestSupport.entry(.text, text: "会议记录：本周优化浅色模式，内容区使用白底，侧栏弱化。",
                                                             sourceAppName: "Notes"),
                                  ClipboardTestSupport.entry(.link, text: "https://example.com/design"),
                                  ClipboardTestSupport.entry(.text, text: "Keep the interface calm and readable.")])
        for backdrop in [Color.black, .white] {
            let name = backdrop == .black ? "desktop" : "window"
            let file = root.appendingPathComponent("clipboard-glass-light-\(name).png")
            try await capture(ClipboardPanelView(model: clipboard, focusRequest: 0),
                              size: NSSize(width: ClipboardPanelView.width, height: ClipboardPanelView.height),
                              backdrop: backdrop, file: file)
            try expectFloatingSurface(file: file, onBlack: backdrop == .black)
        }
    }

    /// Sample an empty patch of the actual compositor output, not an offscreen
    /// bitmap (which omits native glass). The white-window colour stays intact.
    private func expectFloatingSurface(file: URL, onBlack: Bool) throws {
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: file)))
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4,
                                                y: bitmap.pixelsHigh * 7 / 10))
        // The PNG channels are already sRGB. Compare their encoded values
        // without applying AppKit calibrated-colour conversion a second time.
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let expected: [CGFloat] = onBlack ? [240, 241, 243] : [246, 247, 250]
        for (channel, target) in zip(channels, expected) {
            if onBlack {
                #expect(channel * 255 >= target - 0.5)
            } else {
                #expect(abs(channel * 255 - target) < 1)
            }
        }
    }

    private func captureNotebook(conversation: AskConversation, time: Date, root: URL) async throws {
        let notes = makeTestNotes()
        let note = AskNote(title: "帮我取一组适合管姓小朋友的名字，包括大名和小名。", body: conversation.messages[1].text,
                           command: "", keyword: "", input: conversation.messages[0].text,
                           tags: ["家庭", "备忘"], createdAt: time, updatedAt: time, source: .chat)
        notes.save(note)
        notes.save(makeTestNote("解释 · hell cat", body: "Hellcat 可以指凶猛的猫，也可以指 F6F 战斗机。",
                                input: "hell cat", at: time.addingTimeInterval(-3600).timeIntervalSince1970))
        let notebook = AskNotesViewModel(store: notes, notificationCenter: NotificationCenter())
        notebook.reveal(note.id)
        try await capture(AskNotesView(model: notebook) {}, size: NSSize(width: 1120, height: 720),
                          file: root.appendingPathComponent("notebook-glass-light.png"))
    }

    private func captureWordbook(time: Date, root: URL) async throws {
        let settingsSuite = "light-v4-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: settingsSuite))
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        let settings = SettingsStore(defaults: defaults)
        let words = makeTestWordBook()
        let card = AskWordCard(headword: "Shipping Velocity",
                               senses: [.init(pos: "n.", meanings: ["交付速度；软件功能从开发到上线的效率和速度", "发货速度"])],
                               examples: [.init(
                                   source: "The team improved its **shipping velocity** "
                                       + "by automating the release pipeline.",
                                   target: "该团队通过自动化发布流程提高了交付速度。"
                               )],
                               synonyms: ["delivery speed", "release cadence", "deployment frequency"])
        let lookup = AskWordBookLookup(
            headword: card.headword,
            source: "en",
            target: "zh-Hans",
            card: card,
            model: "AI"
        )
        words.record(lookup, at: time, counts: true)
        for (word, meaning) in [("狗粮", "dog food; public display of affection"), ("简洁", "concise; succinct")] {
            words.record(AskWordBookLookup(headword: word, source: "zh-Hans", target: "en", translation: meaning),
                         at: time.addingTimeInterval(-3600), counts: true)
        }
        let wordbook = AskWordBookViewModel(store: words, settings: settings)
        wordbook.reload()
        wordbook.reveal(lookup.key)
        try await capture(AskWordBookView(model: wordbook) {}, size: NSSize(width: 1120, height: 720),
                          file: root.appendingPathComponent("wordbook-glass-light.png"))
    }

    private func capture(_ view: some View, size: NSSize, style: InterfaceStyle = .liquidGlass,
                         dark: Bool = false, backdrop: Color = .black, file: URL) async throws {
        let screen = try #require(NSScreen.main)
        let inset: CGFloat = 20
        let area = NSRect(x: screen.visibleFrame.minX + 4,
                          y: screen.visibleFrame.maxY - size.height - inset * 2 - 4,
                          width: size.width + inset * 2, height: size.height + inset * 2)
        let back = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        back.isReleasedWhenClosed = false
        back.level = .floating
        back.contentView = NSHostingView(rootView: backdrop.frame(width: area.width, height: area.height))
        let panel = NSPanel(contentRect: area.insetBy(dx: inset, dy: inset),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.interfaceStyle, style).environment(\.colorScheme, dark ? .dark : .light))
        back.orderFrontRegardless()
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil); panel.close()
            back.orderOut(nil); back.close()
        }
        try await Task.sleep(for: .milliseconds(900))
        panel.displayIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = [
            "-x",
            "-R\(Int(area.minX)),\(Int(screen.frame.maxY - area.maxY)),\(Int(area.width)),\(Int(area.height))",
            file.path
        ]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
