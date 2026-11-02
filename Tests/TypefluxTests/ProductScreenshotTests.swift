import AppKit
import OpieMenu
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in product photography. Production views, synthetic content, isolated preferences.
/// No full desktop capture, live microphone, account, clipboard or personal file indexing.
@Suite(.serialized, .exclusiveUIState,
       .enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_PRODUCT_SCREENSHOTS"] != nil))
@MainActor
struct ProductScreenshotTests {
    private let canvas = CGSize(width: 1120, height: 740)

    /// Freeze only the fixture's monitors; a held or stale hardware modifier must
    /// never leak shortcut badges into product photography.
    private func releaseCommand(in view: NSView) -> [AskLauncherCommandMonitor.MonitorView] {
        var monitors: [AskLauncherCommandMonitor.MonitorView] = []
        if let monitor = view as? AskLauncherCommandMonitor.MonitorView {
            monitor.readModifiers = { _ in [] }
            monitor.refresh(isKeyWindow: false)
            monitors.append(monitor)
        }
        for child in view.subviews { monitors += releaseCommand(in: child) }
        return monitors
    }

    private func bitmap(_ view: some View, size: CGSize, dark: Bool, native: Bool = false) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.interfaceStyle, .frosted)
            .environment(\.askGlassMaterialOverride, .opaque)
            .environment(\.overlayAnimationsActive, false)
            .frame(width: size.width, height: size.height))
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(650))
        _ = releaseCommand(in: host)
        try await Task.sleep(for: .milliseconds(150))
        #expect(releaseCommand(in: host).allSatisfy { !$0.showing })
        host.layoutSubtreeIfNeeded()
        if native {
            // Window Server composites native glass; cacheDisplay cannot capture its material.
            window.orderFrontRegardless()
            window.displayIfNeeded()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: file) }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
            return try #require(NSBitmapImageRep(data: Data(contentsOf: file)))
        }
        let result = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: result)
        return result
    }

    private func translation(dark: Bool, directory: URL) async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let original = "Make room for what matters. Capture an idea, share it with your team, and turn it into something worth making."
        let rows: [AskTranslationResult] = [
            .init(service: .ai(), name: "AI · Typeflux Cloud", state: .done(
                "给重要的事留一点空间。记下灵感，与伙伴分享，把它变成值得创作的作品。")),
            .init(service: .device, name: L("ask.translation.stack.deviceTitle"), state: .done(
                "为重要的事情腾出空间。捕捉一个想法，与团队分享，并将其变成值得创造的东西。")),
            .init(service: .provider(.deepl), name: "DeepL", state: .done(
                "为真正重要的事留出空间。记录灵感，与团队分享，将它变成值得付诸实践的作品。"))
        ]
        fixture.model.open(source: .input, text: original)
        let output = AskPluginOutput(body: rows[0].text ?? "", original: original,
            meta: [], source: rows[0].name,
            actions: [AskTranslatePlugin.copyAction(rows[0].text ?? "", shortcut: .enter)],
            translation: .init(results: rows, source: "en", target: "zh-Hans",
                               interface: .simplifiedChinese, submitted: true, isLookup: false))
        let id = UUID()
        fixture.model.adoptHandoff(.init(plugin: fixture.model.plugin, plan: .init(mode: .onSubmit, title: ""),
            request: .init(text: original, origin: .argument, keyword: AskTranslatePlugin.keywords[0],
                           options: [:], interfaceLanguage: .simplifiedChinese),
            output: output, running: false, cancel: {}), id: id)
        fixture.model.receiveHandoff(.done(output), id: id)
        #expect(fixture.model.stack.results.count == 3)
        #expect(!fixture.model.isDirty)
        try await save(AskTranslationPanelView(model: fixture.model, history: fixture.model.history, height: 420)
            .frame(width: 680, height: 420), name: "translation", dark: dark, directory: directory, native: true)
    }

    private func chat(_ fixture: AskTestFixture, dark: Bool, directory: URL, defaults: UserDefaults) async throws {
        let now = Date()
        var conversation = AskConversation(id: "product-chat", title: "把灵感变成一份行动计划", revision: 1,
            updatedAt: now, messages: [
                .init(id: "question", role: "user", text: "我想和伙伴一起做一个秋日灵感计划。帮我把这周的想法整理成一份轻松、可执行的安排。",
                      createdAt: now.addingTimeInterval(-60)),
                .init(id: "answer", role: "assistant", text: """
                可以。这周先完成一个能分享的小作品，给尝试留出空间。

                ### 从一个小想法开始
                周一收集灵感，挑出最想做的一件事。用一句话写清楚：想做什么，为什么值得做。

                ### 留出一段专注时间
                周二和周三完成第一份草稿。每天留出半小时，先把想法做出来，再慢慢打磨。

                ### 和伙伴交换反馈
                周四一起看草稿，每个人提一条具体建议。周五完成修改，分享这个小作品。

                可以把这句话放在计划开头：**少一点来回切换，多一点心流。**
                """, createdAt: now)
            ])
        conversation.kind = "chat"
        await fixture.api.seed(conversation)
        for (index, title) in ["周末散步的灵感", "给伙伴写一封邀请信", "整理读书笔记"].enumerated() {
            var previous = AskConversation(id: "product-history-\(index)", title: title, revision: 1,
                updatedAt: now.addingTimeInterval(Double(-3600 * (index + 1))), messages: [])
            previous.kind = "chat"
            await fixture.api.seed(previous)
        }
        await fixture.model.refreshHistory()
        await fixture.model.select(conversation.id)
        #expect(fixture.model.selected?.messages.count == 2)
        let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil },
                             saveStoredToken: { _, _ in }, saveStoredUserProfile: { _ in }, clearStoredSession: {})
        defaults.set(false, forKey: "ask.sidebarCollapsed")
        try await save(AskConversationView(model: fixture.model, auth: auth).defaultAppStorage(defaults)
            .frame(width: 1024, height: 640).clipShape(RoundedRectangle(cornerRadius: 16)),
            name: "chat", dark: dark, directory: directory)
    }

    private func backdrop(dark: Bool) -> some View {
        ZStack {
            LinearGradient(colors: dark
                ? [Color(red: 0.09, green: 0.11, blue: 0.19), Color(red: 0.19, green: 0.15, blue: 0.28)]
                : [Color(red: 0.87, green: 0.91, blue: 0.98), Color(red: 0.95, green: 0.88, blue: 0.93)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(Color.purple.opacity(dark ? 0.16 : 0.08))
                .frame(width: 760, height: 480).blur(radius: 95).offset(x: 340, y: 220)
        }
    }

    private func save(_ view: some View, name: String, dark: Bool, directory: URL, native: Bool = false) async throws {
        let image = try await bitmap(ZStack {
            backdrop(dark: dark)
            view.shadow(color: .black.opacity(dark ? 0.32 : 0.16), radius: 28, y: 16)
        }, size: canvas, dark: dark, native: native)
        let data = try #require(image.representation(using: .png, properties: [:]))
        #expect(image.pixelsWide >= 1120 && data.count > 12000)
        try data.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    /// A fictional project brief serves only as the subject of captures and clipboard thumbnails.
    private func brief(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { $0.opacity(0.8).frame(width: 10, height: 10).clipShape(Circle()) }
                Spacer()
                Text("拾光工作室 / 产品计划").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text("让好想法，更快发生。 ").font(.system(size: 27, weight: .semibold))
                    Text("秋日灵感计划 · 设计、写作与每一天的专注").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sun.max").font(.system(size: 35, weight: .light)).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 19) {
                    Text("这周，做一点喜欢的事").font(.system(size: 15, weight: .semibold))
                    ForEach(["整理桌面，留一点空间", "把灵感写成第一份草稿", "和伙伴一起打磨新方案", "周五之前，分享一个小作品"], id: \.self) { title in
                        Label(title, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    Text("留给创作的时间").font(.system(size: 15, weight: .semibold))
                    HStack(alignment: .bottom, spacing: 13) {
                        ForEach(Array([42.0, 69, 55, 94, 116].enumerated()), id: \.offset) { index, height in
                            VStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 6).fill(Color.indigo.opacity(0.35 + Double(index) * 0.12))
                                    .frame(width: 28, height: height)
                                Text(["一", "二", "三", "四", "五"][index]).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(height: 144)
                }
            }
            Divider()
            HStack {
                Text("少一点来回切换，多一点心流。").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("分享计划  ↗").font(.system(size: 12, weight: .medium)).foregroundStyle(.indigo)
            }
        }
        .padding(30).frame(width: 760, height: 420)
        .foregroundStyle(dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85))
        .background(dark ? Color(red: 0.12, green: 0.13, blue: 0.17) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @Test func exportProductScenes() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TYPEFLUX_PRODUCT_SCREENSHOTS"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        let previousKeychain = KeychainTokenStore.useInMemoryStoreForTesting
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        defer {
            AppLocalization.shared.setLanguage(previousLanguage)
            KeychainTokenStore.useInMemoryStoreForTesting = previousKeychain
        }
        let suite = "product-screenshots-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let temporary = ClipboardTestSupport.temporaryDirectory("product-screenshots")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        let entries: [ClipboardEntry] = [
            .init(origin: .clipboard(UUID()), kind: .text, date: Date(),
                  text: "秋日灵感计划\n\n这周，做一点喜欢的事。\n整理灵感、写下草稿，和伙伴一起打磨新方案。\n\n少一点来回切换，多一点心流。", filePaths: [],
                  imagePath: nil, imagePixelSize: nil, byteSize: 168,
                  sourceBundleID: "com.apple.Notes", sourceAppName: "备忘录", isPinned: true),
            ClipboardTestSupport.entry(.link, date: Date().addingTimeInterval(-120), text: "https://typeflux.app", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"),
            ClipboardTestSupport.entry(.text, date: Date().addingTimeInterval(-300), text: "周五下午一起看看新方案，记得带上你的灵感。", sourceBundleID: "com.apple.MobileSMS", sourceAppName: "信息"),
            ClipboardTestSupport.entry(.text, date: Date().addingTimeInterval(-600), text: "Design is how it works.", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"),
            ClipboardTestSupport.entry(.text, date: Date().addingTimeInterval(-900), text: "主色 Indigo · #6366F1\n背景 Paper · #FAFAF9", sourceBundleID: "com.apple.Notes", sourceAppName: "备忘录"),
            ClipboardTestSupport.entry(.text, date: Date().addingTimeInterval(-1200), text: "明天下午三点，讨论秋日灵感计划。", sourceBundleID: "com.apple.Notes", sourceAppName: "备忘录")
        ]
        for dark in [false, true] {
            let fixture = try AskTestFixture(modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false),
                                             defaults: defaults)
            defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
            let applications = [("Notes", "备忘录"), ("Calendar", "日历"), ("Reminders", "提醒事项"),
                                ("Preview", "预览"), ("Mail", "邮件"), ("Maps", "地图"),
                                ("Music", "音乐"), ("Photos", "照片"), ("TextEdit", "文本编辑"),
                                ("Books", "图书"), ("FaceTime", "FaceTime"), ("Podcasts", "播客"),
                                ("App Store", "App Store"), ("System Settings", "系统设置")]
            let apps = applications.map { file, title in
                AskAppEntry(name: title, url: URL(fileURLWithPath: "/System/Applications/\(file).app"),
                            bundleID: "com.apple." + file.lowercased(), names: [file])
            }
            fixture.model.appIndex = AskTestAppIndex(apps)
            // The production window prewarms these before showing its home grid.
            for app in apps {
                #expect(FileManager.default.fileExists(atPath: app.url.path))
                _ = try #require(fixture.model.launcherIconCache.immediate(.init(kind: .file, value: app.url.path)))
            }
            fixture.model.owner = fixture.model.session()?.owner ?? ""
            fixture.model.setLauncherImagesVisible(true, prepareIcons: false)
            defer { fixture.model.setLauncherImagesVisible(false) }
            fixture.model.clipboardEntries = { entries }
            for (name, text, height) in [("launcher", "", 600.0), ("calculator", "(128 + 256) × 0.85", 350.0),
                                         ("keyword", "clip 灵感", 410.0)] {
                fixture.model.launcherDraft = AskDraft(text: text, includeScreenshot: false)
                try await save(AskLauncherView(model: fixture.model, onDismiss: {})
                    .frame(width: 700, height: height), name: name, dark: dark, directory: directory)
            }
            let clipboard = ClipboardPanelModel()
            clipboard.reset(entries: entries)
            clipboard.showsPreview = true
            try await save(ClipboardPanelView(model: clipboard, focusRequest: 0)
                .frame(width: ClipboardPanelView.size(showsPreview: true).width, height: ClipboardPanelView.height),
                name: "clipboard", dark: dark, directory: directory)
            try await save(ProductRingPreview().frame(width: 460, height: 400), name: "ring", dark: dark,
                           directory: directory, native: true)

            let subject = try await bitmap(brief(dark: dark), size: CGSize(width: 760, height: 420), dark: dark)
            let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 760, height: 420),
                                                 scale: subject.size.width == 760 ? CGFloat(subject.pixelsWide) / 760 : 2,
                                                 image: try #require(subject.cgImage))
            let marked = try ScreenshotRenderer.render(display, crop: display.frame, annotations: [
                ScreenshotAnnotation(kind: .rect(CGRect(x: 455, y: 150, width: 280, height: 200)),
                                     style: ScreenshotAnnotationStyle(color: .blue, size: 3, cornerRadius: 12)),
                ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 360, y: 245), to: CGPoint(x: 430, y: 245)),
                                     style: ScreenshotAnnotationStyle(color: .blue, size: 3))
            ])
            var toolbarState = ScreenshotEditorToolbarModel.State()
            toolbarState.tool = .arrow
            toolbarState.style = ScreenshotAnnotationStyle(color: .blue, size: 3)
            try await save(VStack(spacing: 12) {
                Image(nsImage: NSImage(cgImage: marked, size: CGSize(width: 760, height: 420)))
                    .overlay(Rectangle().stroke(Color.blue.opacity(0.8), lineWidth: 1.5))
                ScreenshotEditorToolbar(state: toolbarState) { _ in }
            }, name: "screenshot", dark: dark, directory: directory)

            let recording = ScreenRecordingCoordinatorTests.Fixture()
            await recording.setup()
            recording.model.options.systemAudio = true
            recording.model.options.microphone = true
            try await save(VStack(spacing: 22) {
                brief(dark: dark).overlay(RoundedRectangle(cornerRadius: 16).stroke(.red.opacity(0.7), lineWidth: 2))
                ScreenRecordingToolbar(model: recording.model, levelProvider: { 0.5 }, close: {}, chooseDirectory: {})
            }, name: "recording", dark: dark, directory: directory)
            await recording.clean()

            let settings = SettingsStore(defaults: defaults)
            settings.appearanceMode = dark ? .dark : .light
            settings.interfaceStyle = .frosted
            var preferences = VoiceCapsulePreferences()
            preferences.style = .bottomCapsule
            settings.voiceCapsule = preferences
            let overlay = OverlayController(appState: AppStateStore(), settingsStore: settings)
            overlay.show()
            overlay.updateLevel(0.58)
            overlay.updateRecordingPreviewText("明天下午三点，一起讨论秋日灵感计划。")
            try await Task.sleep(for: .milliseconds(700))
            let bottom = try #require(overlay.presentedWindow?.contentView)
            bottom.layoutSubtreeIfNeeded()
            let bottomBitmap = try #require(bottom.bitmapImageRepForCachingDisplay(in: bottom.bounds))
            bottom.cacheDisplay(in: bottom.bounds, to: bottomBitmap)
            let bottomImage = NSImage(cgImage: try #require(bottomBitmap.cgImage), size: bottom.bounds.size)
            overlay.dismissImmediately()
            let snapshot = VoiceCapsuleSnapshot(phase: .listening(handsFree: false),
                text: "明天下午三点，一起讨论秋日灵感计划。", level: 0.58,
                targetAppName: "备忘录", recordingStartedAt: Date().addingTimeInterval(-8), expanded: true)
            for name in ["voice-bottom", "voice-corner", "voice-island"] {
                try await save(ZStack {
                    brief(dark: dark).scaleEffect(0.9).offset(y: 30)
                    if name == "voice-bottom" {
                        Image(nsImage: bottomImage).offset(y: 260)
                    } else if name == "voice-corner" {
                        CornerCardCapsule(snapshot: snapshot, actions: .init()).offset(x: 292, y: -230)
                    } else {
                        NotchIslandCapsule(snapshot: snapshot,
                            notch: .init(midX: 560, width: 200, height: 37, isHardware: true), actions: .init())
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }.frame(width: canvas.width, height: canvas.height), name: name, dark: dark, directory: directory)
            }
            try await translation(dark: dark, directory: directory)
            try await chat(fixture, dark: dark, directory: directory, defaults: defaults)
        }
    }
}

private struct ProductRingPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> OpieMenuPreviewView {
        let features: [RingFeature] = [.dictation, .ask, .translate, .screenshot, .screenshotText, .clipboard]
        return OpieMenuPreviewView(items: features.map {
            OpieMenuItem(id: $0.rawValue, title: $0.title, icon: .systemSymbol($0.symbol))
        }, centerTitle: "Typeflux", style: .frosted)
    }
    func updateNSView(_ nsView: OpieMenuPreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: OpieMenuPreviewView, coordinator: ()) { nsView.stop() }
}
