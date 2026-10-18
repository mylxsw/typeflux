import AppKit
import ImageIO
import PDFKit
import TypefluxMediaProtocol
@testable import Typeflux
import XCTest

/// Opt-in on-screen run of the clipboard panel for visual QA. Window-server glass, app icons,
/// the slide-in, the preview window and drags into other apps only exist on a real desktop, so
/// this presents the production `ClipboardPanelController` with fixture entries and keeps the
/// process alive for `TYPEFLUX_CLIPBOARD_LIVE_PREVIEW` seconds while it is captured.
///
/// `TYPEFLUX_CLIPBOARD_LIVE_CONTROL` names a file the harness polls; each line is a command:
/// `open`, `close`, `appearance light|dark|system`, `style shelf|list`, `preview on|off`,
/// `category all|voice|snippet`, `select N`, `query TEXT`, `edit`, `quit`.
/// Actions are logged with a `[clipboard-live]` prefix. It never reads or writes the real
/// clipboard history or settings; pasting writes the text to the general pasteboard only.
final class ClipboardShelfLivePreviewHarness: XCTestCase {
    private struct FixtureError: Error {}

    @MainActor
    func testShowShelfOnScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["TYPEFLUX_CLIPBOARD_LIVE_PREVIEW"], let seconds = Double(value) else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }

        let suite = "clipboard-live-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardPanelStyle = .shelf
        let directory = ClipboardTestSupport.temporaryDirectory("ClipboardShelfLive")
        defer { try? FileManager.default.removeItem(at: directory) }

        // The app decodes thumbnails in its bundled media helper, which a test process does not
        // start; ImageIO and PDFKit stand in so the cards show their real content.
        let controller = ClipboardPanelController(settingsStore: settings, thumbnailDecoder: Self.thumbnail)
        let model = ClipboardPanelModel()
        let entries = try Self.entries(in: directory)
        model.onDismiss = {
            Self.log("dismiss")
            controller.dismiss()
        }
        model.onAction = { action, entry in
            Self.log("action \(action) \(entry.kind) \(String(entry.title.prefix(40)))")
            if action == .paste || action == .pastePlainText, let text = entry.text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                controller.dismiss()
            }
        }
        model.onCommand = { Self.log("command \($0)") }
        model.onPreviewVisibilityChange = { settings.clipboardShowsPreview = $0 }
        let present = {
            model.showsPreview = settings.clipboardShowsPreview
            model.reset(entries: entries, selectFirstUnpinned: true)
            controller.present(model)
            Self.log("open \(settings.clipboardPanelStyle) frame \(controller.presentedWindow?.frame ?? .zero)")
        }
        present()

        let control = environment["TYPEFLUX_CLIPBOARD_LIVE_CONTROL"].map(URL.init(fileURLWithPath:))
        let deadline = Date().addingTimeInterval(seconds)
        var nextPoll = Date()
        commands: while Date() < deadline {
            // A test process has no `NSApp.run()`; dispatch mouse and keyboard events here so the
            // panel is driven exactly as in the app. Waiting for events also drains the main queue.
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            guard Date() >= nextPoll else { continue }
            nextPoll = Date().addingTimeInterval(0.25)
            guard let control, let text = try? String(contentsOf: control, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: control)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                switch (words.first, words.dropFirst().first) {
                case ("open", _): present()
                case ("close", _): controller.dismiss()
                case ("appearance", let mode?): settings.appearanceMode = AppearanceMode(rawValue: mode) ?? .system
                case ("style", let style?): settings.clipboardPanelStyle = ClipboardPanelStyle(rawValue: style) ?? .shelf
                case ("preview", let state?): settings.clipboardShowsPreview = state == "on"
                case ("category", let name?): model.category = ClipboardCategory(rawValue: name) ?? .all
                case ("select", let index?): model.select(index: Int(index) ?? 0)
                case ("query", _): model.query = words.dropFirst().joined(separator: " ")
                case ("edit", _): model.perform(.editBeforePaste)
                case ("quit", _): break commands
                default: Self.log("unknown command \(line)")
                }
            }
        }
        controller.dismiss()
        Self.log("done")
    }

    @Sendable private static func thumbnail(_ url: URL, edge: CGFloat) async throws -> AskFilePreviewPDF.Result {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0),
                  let image = page.thumbnail(of: CGSize(width: edge, height: edge), for: .mediaBox)
                      .cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw MediaFailure.unavailable }
            return .init(images: [image], numbers: [1], pages: document.pageCount)
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw MediaFailure.unavailable }
        return .init(images: [image], numbers: [], pages: 1)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clipboard-live] \(message)\n".utf8))
    }

    // MARK: - Fixtures

    private static func entries(in directory: URL) throws -> [ClipboardEntry] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let screenshot = directory.appendingPathComponent("screenshot.png")
        try artwork(title: "Typeflux", subtitle: "Voice input for macOS", colors: [.systemIndigo, .systemPink],
                    size: NSSize(width: 1400, height: 800)).write(to: screenshot)
        let photos = try (1 ... 5).map { index -> String in
            let url = directory.appendingPathComponent("photo-\(index).png")
            let palettes: [[NSColor]] = [[.systemOrange, .systemYellow], [.systemTeal, .systemBlue],
                                         [.systemPurple, .systemPink], [.systemGreen, .systemMint],
                                         [.systemRed, .systemOrange]]
            try artwork(title: "IMG_\(4210 + index)", subtitle: nil, colors: palettes[index - 1],
                        size: NSSize(width: 800, height: 600)).write(to: url)
            return url.path
        }
        let report = directory.appendingPathComponent("产品规划-Q4.pdf")
        try reportPDF(at: report)
        let audio = try ClipboardTestSupport.makeAudioFile(named: "语音备忘 1018.wav", in: directory, seconds: 3)
        let deck = ClipboardTestSupport.makeFile(named: "剪贴板改版评审.key", in: directory, bytes: 2_400_000)
        let sheet = ClipboardTestSupport.makeFile(named: "用户访谈记录.xlsx", in: directory, bytes: 380_000)

        var signature = ClipboardTestSupport.entry(.text, date: ago(60 * 24 * 3),
                                                   text: "Best regards,\n\nMylxsw\nArchitect · Typeflux\nhttps://typeflux.app")
        signature.snippet = ClipboardSnippet(name: "邮件签名", alias: "签名")
        return [
            ClipboardTestSupport.entry(.text, date: ago(180), text: "收货地址：上海市徐汇区漕溪北路 88 号 圣爱大厦 12 楼 1203 室，张先生 138 0000 0000",
                                       sourceBundleID: "com.apple.Notes", sourceAppName: "备忘录", isPinned: true),
            ClipboardTestSupport.entry(.link, date: ago(1), text: "https://github.com/mylxsw/typeflux/pull/658",
                                       sourceBundleID: "com.apple.Safari", sourceAppName: "Safari 浏览器"),
            ClipboardTestSupport.entry(.code, date: ago(4), text: """
            static func shelfFrame(height: CGFloat, screen: NSRect) -> NSRect {
                NSRect(x: screen.minX + shelfMargin,
                       y: screen.minY + shelfMargin,
                       width: screen.width - shelfMargin * 2,
                       height: height)
            }
            """, sourceBundleID: "com.apple.TextEdit", sourceAppName: "文本编辑"),
            ClipboardTestSupport.entry(.image, date: ago(9), imagePath: screenshot.path,
                                       imagePixelSize: CGSize(width: 1400, height: 800), byteSize: 412_000,
                                       sourceBundleID: "com.apple.Preview", sourceAppName: "预览"),
            ClipboardTestSupport.entry(.text, date: ago(15), text: "明天下午 3 点评审剪贴板改版，设计稿和 PR 链接都在频道置顶里。记得把深色和浅色两个版本都带上，另外看一下减少动态效果时的表现。",
                                       sourceBundleID: "com.apple.mail", sourceAppName: "邮件"),
            ClipboardTestSupport.entry(.images, date: ago(22), filePaths: photos, byteSize: 5_800_000,
                                       sourceBundleID: "com.apple.finder", sourceAppName: "访达"),
            ClipboardTestSupport.entry(.pdf, date: ago(35), filePaths: [report.path], byteSize: 96_000,
                                       sourceBundleID: "com.apple.finder", sourceAppName: "访达"),
            ClipboardTestSupport.entry(.audio, date: ago(48), filePaths: [audio.path], byteSize: 48_000,
                                       sourceBundleID: "com.apple.finder", sourceAppName: "访达"),
            ClipboardTestSupport.entry(.files, date: ago(70), filePaths: [report.path, deck.path, sheet.path],
                                       byteSize: 2_876_000, sourceBundleID: "com.apple.finder", sourceAppName: "访达"),
            ClipboardTestSupport.entry(.text, date: ago(60 * 26), text: "make test SUITE=\"ClipboardShelfLogicTests\"",
                                       sourceBundleID: "com.apple.Terminal", sourceAppName: "终端"),
            ClipboardTestSupport.entry(.text, date: ago(60 * 27), text: "验证码 482913，5 分钟内有效。",
                                       sourceBundleID: "com.apple.MobileSMS", sourceAppName: "信息"),
            ClipboardTestSupport.entry(.voice, date: ago(2), text: "把剪贴板改成从屏幕底部滑出的卡片形式，左右键选择，回车直接粘贴到当前光标的位置。"),
            ClipboardTestSupport.entry(.voice, date: ago(95), text: "提醒我周五之前把剪贴板设计稿发给团队确认。"),
            signature
        ]
    }

    /// A gradient picture with a title, standing in for a screenshot or photo.
    private static func artwork(title: String, subtitle: String?, colors: [NSColor], size: NSSize) throws -> Data {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 35)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size.height / 7, weight: .bold), .foregroundColor: NSColor.white
            ]
            (title as NSString).draw(at: NSPoint(x: size.width * 0.08, y: size.height * 0.45), withAttributes: attributes)
            if let subtitle {
                (subtitle as NSString).draw(at: NSPoint(x: size.width * 0.08, y: size.height * 0.32), withAttributes: [
                    .font: NSFont.systemFont(ofSize: size.height / 16, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.85)
                ])
            }
            return true
        }
        guard let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let png = rep.representation(using: .png, properties: [:]) else { throw FixtureError() }
        return png
    }

    /// Three A4 pages with a heading and body lines.
    private static func reportPDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FixtureError() }
        for page in 1 ... 3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.systemIndigo.setFill()
            NSRect(x: 0, y: 742, width: 595, height: 100).fill()
            ("Typeflux 产品规划 · 第 \(page) 页" as NSString).draw(at: NSPoint(x: 48, y: 780), withAttributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.white
            ])
            NSColor(white: 0.82, alpha: 1).setFill()
            for line in 0 ..< 18 {
                NSRect(x: 48, y: 690 - CGFloat(line) * 32, width: line % 4 == 3 ? 300 : 499, height: 10).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}
