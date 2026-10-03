import AppKit
import Testing
@testable import Typeflux

@Suite("Ask Markdown tables", .serialized)
@MainActor struct AskMarkdownTableTests {
    private let sample = """
    ## 方案成本

    | 步骤 | 时间 | 大致成本 |
    | :--- | :---: | ---: |
    | **ICP 经营许可证** | 1–2 个月 | 几千到几万元（看地区） |
    | 文网文（网络文化经营许可证） | 1–3 个月 | 几千到几万 |
    | 软件登记 | 1–2 个月 | 几百到几千 |
    | 游戏内容自审、出具合规报告 | 视情况 | 几千 |
    | 提交版号申请 | 排队 1–3 年 | 几乎免费，但时间成本巨大 |
    | 服务器租赁、备案等 | 持续 | 月费 |

    整体下来 **5–15 万 + 1–3 年等待**。
    """

    private func block(_ value: NSAttributedString, at text: String) throws -> NSTextTableBlock {
        let range = (value.string as NSString).range(of: text)
        try #require(range.location != NSNotFound)
        let style = try #require(value.attribute(
            .paragraphStyle,
            at: range.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        return try #require(style.textBlocks.first as? NSTextTableBlock)
    }

    @Test func `cells have shared table borders header and column alignment`() throws {
        let value = AskMarkdownText.render(sample)
        let header = try block(value, at: "步骤")
        let body = try block(value, at: "ICP")
        let time = try block(value, at: "1–2 个月")
        let cost = try block(value, at: "几千到几万元")
        #expect(header.table === body.table)
        #expect(header.table.numberOfColumns == 3)
        #expect(header.startingRow == 0 && body.startingRow == 1)
        #expect(time.startingColumn == 1 && cost.startingColumn == 2)
        #expect(header.backgroundColor != nil && body.backgroundColor == nil)
        // The rounded frame and row rules are drawn by the cells, not as block borders.
        #expect(body.width(for: .border, edge: .minX) == 0)
        #expect(body.width(for: .padding, edge: .minX) == AskMarkdownTable.horizontalPadding)
        let edges = try #require(header as? AskTableCellBlock).edges
        #expect(edges == .init(top: true, bottom: false, left: true, right: false))
        let lastCost = try #require(block(value, at: "月费") as? AskTableCellBlock).edges
        #expect(lastCost == .init(top: false, bottom: true, left: false, right: true))
        for (text, alignment) in [("步骤", NSTextAlignment.left), ("时间", .center), ("大致成本", .right)] {
            let range = (value.string as NSString).range(of: text)
            let style = try #require(value.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle)
            #expect(style.alignment == alignment)
        }
        let after = (value.string as NSString).range(of: "整体下来")
        let style = try #require(value.attribute(
            .paragraphStyle,
            at: after.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(style.textBlocks.isEmpty)
    }

    @Test func `inline formatting empty cells and trailing table remain intact`() throws {
        let value = AskMarkdownText
            .render("| Name | Value |\n| --- | --- |\n| **bold** | [link](https://example.com) |\n| | `a\\|b` |")
        #expect(value.string == "Name\nValue\nbold\nlink\n\na|b\n")
        let bold = (value.string as NSString).range(of: "bold")
        let font = try #require(value.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let link = (value.string as NSString).range(of: "link")
        #expect(value
            .attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        let empty = (value.string as NSString).range(of: "\n\na|b").location + 1
        let style = try #require(value.attribute(.paragraphStyle, at: empty, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try #require(style.textBlocks.first as? NSTextTableBlock)
        #expect(cell.startingRow == 2 && cell.startingColumn == 0)
        #expect(try block(value, at: "a|b").startingColumn == 1)
    }

    @Test func `independent tables header only and plain text`() throws {
        let value = AskMarkdownText.render("| First |\n| --- |\n\nBetween\n\n| Second |\n| --- |\n| Row |")
        let first = try block(value, at: "First")
        let second = try block(value, at: "Second")
        #expect(first.table !== second.table)
        #expect(try second.table === block(value, at: "Row").table)
        #expect(first.table.numberOfColumns == 1)
        let plain = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        #expect(AskMarkdownText.render(plain, markdown: false).string == plain)
        #expect(AskMarkdownText.render("").length == 0)
        #expect(AskMarkdownText.render("partial | table").string == "partial | table")
    }

    @Test func `streamed partial and uneven rows become complete table cells`() throws {
        let editor = AskTranscriptText.Editor()
        editor.setContent("| A | B |\n| ---", markdown: true, dark: false)
        editor.setContent(
            "| A | B |\n| --- | --- |\n| short |\n| left | right | ignored |",
            markdown: true,
            dark: false
        )
        let value = try #require(editor.textStorage)
        #expect(value.string == "A\nB\nshort\n\nleft\nright\n")
        let right = try block(value, at: "right")
        #expect(right.startingRow == 2 && right.startingColumn == 1)
    }

    @Test func `layout wraps at narrow widths and selection survives streaming`() throws {
        _ = NSApplication.shared
        for width: CGFloat in [320, 700] {
            let editor = AskTranscriptText.Editor(frame: NSRect(x: 0, y: 0, width: width, height: 900))
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.setContent(sample, markdown: true, dark: false)
            let container = try #require(editor.textContainer)
            let layout = try #require(editor.layoutManager)
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            #expect(used.width <= width + 1)
            #expect(used.height > 200)
            var cells: [NSRect] = []
            for text in ["软件登记", "1–2 个月", "几百到几千"] {
                // Use the same row when checking horizontal column separation.
                let rowStart = (editor.string as NSString).range(of: "软件登记").location
                let range = (editor.string as NSString).range(
                    of: text,
                    range: NSRange(location: rowStart, length: (editor.string as NSString).length - rowStart)
                )
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                cells.append(layout.boundingRect(forGlyphRange: glyphs, in: container))
            }
            #expect(cells[0].maxX < cells[1].minX)
            #expect(cells[1].maxX < cells[2].minX)
            let selection = (editor.string as NSString).range(of: "ICP 经营许可证\n1–2 个月\n几千到几万元（看地区）")
            editor.setSelectedRange(selection)
            editor.setContent(sample + "\n\n更多建议", markdown: true, dark: false)
            #expect(editor.selectedRange() == selection)
            #expect(editor.selectedExcerpt?.contains("ICP 经营许可证") == true)
            if let root = ProcessInfo.processInfo.environment["TYPEFLUX_TABLE_SNAPSHOTS"] {
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                layout.ensureLayout(for: container)
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
                            try png.write(to: URL(fileURLWithPath: root)
                                .appendingPathComponent("table-\(Int(width))-\(name).png"))
                        }
                    }
                    try snapshot?.get()
                }
            }
        }
    }
}
