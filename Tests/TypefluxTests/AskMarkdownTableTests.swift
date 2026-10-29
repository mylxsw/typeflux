import AppKit
import Testing
@testable import Typeflux

@Suite("Ask Markdown tables", .serialized, .exclusiveUIState)
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
        #expect(body.verticalAlignment.rawValue == 0)
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

    @Test func `table separates following paragraphs headings and lists in actual layout`() throws {
        let table = "| Name | Value |\n| --- | --- |\n| A | B |"
        for following in ["**Following** text", "## Following", "- Following\n- Another"] {
            let value = AskMarkdownText.render(table + "\n\n" + following)
            let range = (value.string as NSString).range(of: "Following")
            let style = try #require(value.attribute(.paragraphStyle, at: range.location,
                                                    effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.paragraphSpacingBefore == 16)
            #expect(style.textBlocks.isEmpty)
            let withoutGap = NSMutableAttributedString(attributedString: value)
            let compact = AskMarkdownText.mutable(style)
            compact.paragraphSpacingBefore = 0
            withoutGap.addAttribute(.paragraphStyle, value: compact,
                                   range: (value.string as NSString).paragraphRange(for: range))
            for width: CGFloat in [320, 700] {
                func position(_ content: NSAttributedString) throws -> CGFloat {
                    let editor = AskTranscriptText.Editor(frame: NSRect(x: 0, y: 0, width: width, height: 900))
                    editor.textStorage?.setAttributedString(content)
                    let container = try #require(editor.textContainer)
                    let layout = try #require(editor.layoutManager)
                    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                    layout.ensureLayout(for: container)
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    return layout.boundingRect(forGlyphRange: glyphs, in: container).minY
                }
                #expect(try position(value) - position(withoutGap) >= 15.5)
            }
        }
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

    @Test func `table actions distinguish tables preserve cells and follow resized layout`() throws {
        let editor = AskTranscriptText.makeEditor()
        editor.setContent("Before\n\n| A | B |\n| --- | --- |\n| **bold** | |\n\nBetween\n\n| C |\n| --- |\n| D |",
                          markdown: true, dark: false)
        let interaction = editor.tableInteraction
        #expect(interaction.tables.count == 2)
        let first = try #require(interaction.tables.first)
        #expect(AskTranscriptTableInteraction.tabSeparated(first, in: try #require(editor.textStorage)) == "A\tB\nbold\t")
        for width: CGFloat in [320, 700] {
            let size = try #require(editor.measuredSize(width: width))
            editor.frame = NSRect(origin: .zero, size: size)
            let rect = first.frame(in: editor)
            // TextKit reserves a few points for the table's outer frame.
            #expect(rect.width > width * 0.95 && rect.maxX <= width + 1)
            #expect(rect.height > 50)
            interaction.updateHover(at: NSPoint(x: rect.midX, y: rect.midY))
            #expect(interaction.hoveredIndex == 0)
            let second = interaction.tables[1].frame(in: editor)
            interaction.updateHover(at: NSPoint(x: second.midX, y: second.midY))
            #expect(interaction.hoveredIndex == 1)
            interaction.updateHover(at: NSPoint(x: rect.midX, y: (rect.maxY + second.minY) / 2))
            #expect(interaction.hoveredIndex == nil)
        }
        editor.setContent("Plain", markdown: false, dark: false)
        #expect(interaction.tables.isEmpty)
        #expect(interaction.hoveredIndex == nil)
    }

    @Test func `expanded table zoom scroll dismissal and streaming preserve transcript selection`() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = AskTranscriptText.makeEditor()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        parent.addSubview(editor)
        window.contentView = parent
        defer { editor.tableInteraction.dismiss(); window.contentView = nil; window.close() }
        editor.setContent(sample, markdown: true, dark: false)
        editor.frame = NSRect(origin: NSPoint(x: 80, y: 80), size: try #require(editor.measuredSize(width: 700)))
        let selected = (editor.string as NSString).range(of: "ICP 经营许可证")
        editor.setSelectedRange(selected)
        window.makeFirstResponder(editor)
        let rect = try #require(editor.tableInteraction.tables.first).frame(in: editor)
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved,
            location: editor.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0))
        editor.mouseMoved(with: moved)
        // Exercise the actual toolbar target/action used by the hover button.
        let toolbar = try #require(editor.subviews.compactMap { $0 as? NSStackView }.first)
        let expand = try #require(toolbar.arrangedSubviews.last as? NSButton)
        #expect(!toolbar.isHidden)
        if let root = ProcessInfo.processInfo.environment["TYPEFLUX_TABLE_SNAPSHOTS"] {
            parent.layoutSubtreeIfNeeded()
            let bitmap = try #require(parent.bitmapImageRepForCachingDisplay(in: parent.bounds))
            parent.cacheDisplay(in: parent.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: root).appendingPathComponent("table-hover.png"))
        }
        expand.performClick(nil)
        let preview = try #require(editor.tableInteraction.preview)
        #expect(preview.superview === parent)
        #expect(!preview.textView.string.contains("整体下来"))
        #expect(preview.textView.string.contains("ICP 经营许可证"))
        #expect(preview.scrollView.hasHorizontalScroller && preview.scrollView.hasVerticalScroller)
        let sourceFont = try #require(preview.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        preview.setZoom(2.5)
        preview.layoutSubtreeIfNeeded()
        #expect(preview.zoom == 2)
        let largeFont = try #require(preview.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(largeFont.pointSize > sourceFont.pointSize)
        #expect(preview.textView.frame.width > preview.scrollView.contentSize.width)
        preview.setZoom(0.1)
        #expect(preview.zoom == 0.8)
        preview.setZoom(1.2)
        preview.layoutSubtreeIfNeeded()
        if let root = ProcessInfo.processInfo.environment["TYPEFLUX_TABLE_SNAPSHOTS"] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                parent.appearance = NSAppearance(named: appearance)
                preview.needsLayout = true
                preview.layoutSubtreeIfNeeded()
                let bitmap = try #require(parent.bitmapImageRepForCachingDisplay(in: parent.bounds))
                parent.cacheDisplay(in: parent.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: root).appendingPathComponent("expanded-table-\(name).png"))
            }
        }
        editor.setContent(sample + "\n\nStreaming continues", markdown: true, dark: false)
        #expect(editor.selectedRange() == selected)
        #expect(preview.textView.string.contains("ICP 经营许可证"))
        window.makeFirstResponder(preview.textView)
        preview.textView.cancelOperation(nil)
        #expect(editor.tableInteraction.preview == nil)
        #expect(preview.superview == nil)
        #expect(window.firstResponder === editor)
        editor.tableInteraction.updateHover(at: NSPoint(x: rect.midX, y: rect.midY))
        editor.tableInteraction.expandTable()
        let reopened = try #require(editor.tableInteraction.preview)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: reopened.convert(NSPoint(x: 5, y: 5), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
        reopened.mouseDown(with: click)
        #expect(editor.tableInteraction.preview == nil)
        editor.tableInteraction.expandTable()
        #expect(editor.tableInteraction.preview != nil)
        AskTranscriptText.dismantleNSView(editor, coordinator: ())
        #expect(editor.tableInteraction.preview == nil)
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
