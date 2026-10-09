import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders every state on the GUL-161 design board with the board's own
/// content, in Chinese, for a side-by-side comparison. Opt-in through
/// TYPEFLUX_REFERENCE_SNAPSHOTS. Glass is drawn as its opaque Reduce
/// Transparency fill: an offscreen render has no desktop for the material to
/// blend with and would come out flat grey.
@Suite("Ask reference design renders", .serialized, .exclusiveUIState)
@MainActor
struct AskReferenceDesignRenderTests {
    private static let answer = """
    这一屏看起来是 Grok 网页版（grok.com），你正在和 Grok 进行一个关于"Harvard course on happiness"（哈佛幸福课）的对话。

    主要内容包括：

    1. **左侧栏**：Apple Podcasts 风格的侧边导航。
    2. **中间窗口**：看起来是一个文件选择/输入对话框。
    3. **右侧主对话区**：是你和 Grok 的对话，内容是你问 Grok 帮你找 Harvard 幸福课的英文原稿（因为只能找到中文版），Grok 回答了"It Thought for 9s"，并给出了一段中文回复，大意是：
        - 哈佛幸福课的英文原稿确实不太好找。
        - 课程官网（哈佛公开课页面）可以获取课程大纲、阅读材料和练习，但没有逐字稿。
        - 提供了一些可能的获取途径和建议。
    """

    private func quote(_ text: String, _ question: String = "", source: String) -> AskReference {
        AskReference(messageId: source, text: text, question: question)
    }

    private func designQuotes(source: String) -> [AskReference] {
        [
            quote("，内容是你问 Grok 帮你找 Harvard 幸福课的英文原稿（因为只能找到中文版）",
                  AskSelectionAction.explain.question, source: source),
            quote("课程大纲、阅读材料和练习，但没有逐字稿。\n• 提供了一些可能的获取途径和建议。", source: source),
            quote("\n3.\t右侧主对话区：是你和 Grok 的对话", source: source)
        ]
    }

    @Test func renderDesignBoardStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_REFERENCE_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }

        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let conversationID = UUID().uuidString
        let sourceID = UUID().uuidString
        let sent = designQuotes(source: sourceID)
        await fixture.api.seed(AskConversation(id: conversationID, title: "讲讲这一屏在做什么", revision: 1, updatedAt: Date(),
                                         messages: [
            AskMessage(id: UUID().uuidString, role: "user", text: "讲讲这一屏在做什么", createdAt: Date()),
            AskMessage(id: sourceID, role: "assistant", text: Self.answer, createdAt: Date()),
            AskMessage(id: UUID().uuidString, role: "user", text: "这几个途径里，哪个最可能拿到英文原稿？",
                       createdAt: Date(), references: sent),
            AskMessage(id: UUID().uuidString, role: "assistant",
                       text: "最可能的是课程官网的阅读材料和公开课录像的字幕。", createdAt: Date())
        ]))
        await fixture.model.select(conversationID)

        // 1 / 3.2: the board's "After" — three quotes, dark and light.
        fixture.model.draft.references = designQuotes(source: sourceID)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            try await write(workspace(fixture.model), size: CGSize(width: 1200, height: 820), appearance: appearance,
                            to: root.appendingPathComponent("design-1-three-\(appearance.rawValue).png"))
        }

        // 2.1: a single quote stretches across the row; typed text replaces the prompt.
        fixture.model.draft.references = [quote("课程官网（哈佛公开课页面）可以获取课程大纲、阅读材料和练习，但没有逐字稿。提供了一些可能的获取途径和建议。",
                                          source: sourceID)]
        fixture.model.draft.text = "这些途径里哪个最靠谱？"
        try await write(workspace(fixture.model), size: CGSize(width: 1200, height: 820), appearance: .darkAqua,
                        to: root.appendingPathComponent("design-2-1-single.png"))
        fixture.model.draft.text = ""

        // 2.3: eight quotes fold into two rows with "+N" and "Clear".
        let board = designQuotes(source: sourceID)
        fixture.model.draft.references = [
            board[0], board[1],
            quote("但没有逐字稿", "为什么没有逐字稿？", source: sourceID),
            board[2],
            quote("It Thought for 9s", AskSelectionAction.translate.question, source: sourceID),
            quote("哈佛幸福课的英文原稿确实不太好找", source: sourceID),
            quote("Apple Podcasts 风格的侧边导航", source: sourceID),
            quote("看起来是一个文件选择/输入对话框", source: sourceID)
        ]
        try await write(workspace(fixture.model), size: CGSize(width: 1200, height: 820), appearance: .darkAqua,
                        to: root.appendingPathComponent("design-2-3-many.png"))

        // 2.2 and 2.4: hover and the selected pill with its popover. Popovers
        // and hover only exist on screen, so these pieces render directly.
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            try await write(pillStates(source: sourceID), size: CGSize(width: 640, height: 420), appearance: appearance,
                            to: root.appendingPathComponent("design-2-2-4-states-\(appearance.rawValue).png"))
        }
    }

    private func pillStates(source sourceID: String) -> some View {
        let mixed = [
            designQuotes(source: sourceID)[0],
            quote("课程官网（哈佛公开课页面）可以获取课程大纲、阅读材料和练习，但没有逐字稿。\n提供了一些可能的获取途径和建议。",
                  "为什么没有逐字稿？", source: sourceID),
            designQuotes(source: sourceID)[2]
        ]
        return VStack(alignment: .leading, spacing: 18) {
            // 2.2: the second pill is hovered.
            AskFlowLayout(spacing: AskReferenceStrip.spacing, itemMaxWidth: AskReferenceChip.maxWidth) {
                AskReferenceChip(reference: mixed[0], action: {}, onRemove: {})
                AskReferenceChip(reference: quote("课程大纲、阅读材料和练习", AskSelectionAction.translate.question,
                                                  source: sourceID),
                                 action: {}, onRemove: {}, hovering: true)
            }
            // 2.4: the selected pill and the popover it opens.
            AskFlowLayout(spacing: AskReferenceStrip.spacing, itemMaxWidth: AskReferenceChip.maxWidth) {
                AskReferenceChip(reference: mixed[0], action: {}, onRemove: {})
                AskReferenceChip(reference: mixed[1], selected: true, action: {}, onRemove: {})
                AskReferenceChip(reference: mixed[2], action: {}, onRemove: {})
            }
            AskReferenceEditor(reference: mixed[1], save: { _ in }, cancel: {},
                               position: L("ask.references.position", 2, 3), locate: {}, remove: {})
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AskTheme.border))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AskTheme.composerSurface)
    }

    private func workspace(_ model: AskConversationModel) -> some View {
        AskConversationView(model: model).environment(\.askGlassMaterialOverride, .opaque)
    }

    private func write(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
