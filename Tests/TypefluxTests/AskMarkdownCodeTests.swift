import AppKit
import Testing
@testable import Typeflux

@Suite("Ask Markdown code blocks", .serialized, .exclusiveUIState)
@MainActor struct AskMarkdownCodeTests {
    private let sample = """
    **方式 A：注释掉失效引用**（推荐）

    ```bash
    sed -i 's|source /missing/env|# source /missing/env|' ~/.bashrc
    ```

    **方式 B：加存在性判断**（防止以后再出现类似问题）

    把```bash
    source /home/ubuntu/workdir/.tools/env
    ```
    改成
    ```bash
    [ -f /home/ubuntu/workdir/.tools/env ] && source /home/ubuntu/workdir/.tools/env
    ```

    后续说明：需要保留原文件做备份吗？
    """

    @Test func `joined fence is repaired without swallowing prose or the next block`() throws {
        let value = AskMarkdownText.render(sample)
        #expect(!value.string.contains("```"))
        for code in ["sed -i", "source /home", "[ -f"] {
            let range = (value.string as NSString).range(of: code)
            let style = try #require(value.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.textBlocks.first is AskCodeBlock)
        }
        for text in ["把", "改成", "后续说明"] {
            let range = (value.string as NSString).range(of: text)
            let style = try #require(value.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.textBlocks.isEmpty)
        }
    }

    @Test func `valid fences literal code and inline backticks are preserved`() {
        for source in [
            "Use ```bash``` inline", "    literal```bash\n    code",
            "```text\nliteral```bash\n```", "~~~~text\nliteral```bash\n~~~~",
            "> ```text\n> literal```bash\n> ```",
            "````text\n```bash\nliteral```bash\n```\n````",
            "```bash\necho ok\n```\n\nAfter"
        ] {
            #expect(AskMarkdownFences.normalize(source) == source)
        }
        #expect(AskMarkdownFences.normalize("改成~~~sh\necho ok\n~~~") == "改成\n~~~sh\necho ok\n~~~")
        #expect(AskMarkdownText.render(sample, markdown: false).string == sample)
    }

    @Test func `code panels wrap and keep following text clear`() throws {
        _ = NSApplication.shared
        for width: CGFloat in [320, 700] {
            let editor = AskTranscriptText.Editor(frame: NSRect(x: 0, y: 0, width: width, height: 900))
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.textContainer?.replaceLayoutManager(AskRoundedBackgroundLayoutManager())
            editor.setContent(sample, markdown: true, dark: false)
            let container = try #require(editor.textContainer)
            let layout = try #require(editor.layoutManager)
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            #expect(layout.usedRect(for: container).width <= width + 1)
            func bounds(_ text: String) -> NSRect {
                let range = (editor.string as NSString).range(of: text)
                return layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            }
            let code = bounds("[ -f /home/ubuntu/workdir/.tools/env ] && source /home/ubuntu/workdir/.tools/env")
            let after = bounds("后续说明")
            let range = (editor.string as NSString).range(of: "[ -f")
            let style = try #require(editor.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            let block = try #require(style.textBlocks.first as? AskCodeBlock)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let panel = block.panelRect(in: layout.boundsRect(for: block, at: glyphs.location, effectiveRange: nil))
            #expect(panel.minY < code.minY)
            #expect(panel.maxY > code.maxY)
            #expect(after.minY - panel.maxY >= 10)
            if let root = ProcessInfo.processInfo.environment["TYPEFLUX_CODE_SNAPSHOTS"] {
                editor.frame.size.height = ceil(layout.usedRect(for: container).height) + 20
                editor.drawsBackground = true
                editor.backgroundColor = .textBackgroundColor
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    editor.appearance = NSAppearance(named: appearance)
                    var snapshot: Result<Void, Error>?
                    editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                        snapshot = Result {
                            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
                            editor.cacheDisplay(in: editor.bounds, to: bitmap)
                            let png = try #require(bitmap.representation(using: .png, properties: [:]))
                            try png.write(to: URL(fileURLWithPath: root).appendingPathComponent("code-\(Int(width))-\(name).png"))
                        }
                    }
                    try snapshot?.get()
                }
            }
        }
    }
}
