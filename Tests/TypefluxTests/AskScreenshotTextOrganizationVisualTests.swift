import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in snapshots of the production screenshot result card, using synthetic OCR and AI responses.
@Suite("Screenshot organization snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskScreenshotTextOrganizationVisualTests {
    @Test func renderOrganizationStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let lines = ["3.设计稿", "给出可视化的界面设计稿，覆盖主要状态：", "• 技术架构：Swift / SwiftUI",
                     "• 关键流程：截图 → 识别 → 整理 → 输出", "• 活跃用户：128,430"]
        let recognized = RecognizedText(lines: lines.map {
            RecognizedText.Line(text: $0, confidence: 1, boundingBox: .zero)
        })
        let source = AskScreenshotTextSource(pixelSize: CGSize(width: 2008, height: 1134), fitsQuestion: true,
                                            recognition: Task { recognized })
        let generator = AskTestTextGenerator()
        generator.pieces = ["""
        ## 3. 设计稿

        给出可视化的界面设计稿，覆盖主要状态：

        - **技术架构**：Swift / SwiftUI
        - **关键流程**：截图 → 识别 → 整理 → 输出
        - **活跃用户**：128,430
        """]
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLocalization.shared.setLanguage(language)
            let plugin = AskScreenshotTextPlugin(screenshot: { source }, generator: generator,
                                                modelName: { "test-model" }, savesNotes: true)
            let input = AskPluginRequest(text: "", origin: .argument, keyword: AskScreenshotTextPlugin.keywords[0],
                                         options: [:], interfaceLanguage: language)
            let localPlan = await plugin.plan(input)
            let original = try await plugin.run(input, plan: localPlan) { _ in }
            var organizing = input
            organizing.options = [AskScreenshotTextPlugin.organizeOption: source.id.uuidString]
            let aiPlan = await plugin.plan(organizing)
            let organized = try await plugin.run(organizing, plan: aiPlan) { _ in }
            let failure = AskPluginFailure(message: L("screenshot.text.organize.empty"),
                                          actions: [AskScreenshotTextPlugin.originalAction,
                                                    AskScreenshotTextPlugin.recaptureAction(.commandR)])
            let states: [(String, AskPluginDisplay)] = [
                ("original", .init(title: plugin.title, symbol: plugin.symbol, phase: .done(localPlan, original))),
                ("organizing", .init(title: plugin.title, symbol: plugin.symbol, phase: .running(aiPlan),
                                    previous: original)),
                ("organized", .init(title: plugin.title, symbol: plugin.symbol, phase: .done(aiPlan, organized))),
                ("failure", .init(title: plugin.title, symbol: plugin.symbol, phase: .failed(aiPlan, failure)))
            ]
            for (name, display) in states {
                try await renderState(display, name: name, language: language, root: root)
            }
        }
    }

    private func renderState(_ display: AskPluginDisplay, name: String, language: AppLanguage,
                             root: URL) async throws {
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = VStack(alignment: .leading, spacing: 16) {
                AskKeywordChip(title: display.title, symbol: display.symbol)
                AskPluginResultsView(display: display, question: "", onMain: {}, onAction: { _ in },
                                     onAskAI: {}, onHighlight: { _ in })
            }
            .padding(20)
            .background(StudioTheme.background)
            .environment(\.colorScheme, theme == "dark" ? .dark : .light)
            let file = root.appendingPathComponent("ocr-\(language.rawValue)-\(name)-\(theme).png")
            try await render(view, appearance: appearance, file: file)
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, file: URL) async throws {
        let size = NSSize(width: AskMetrics.launcherWidth, height: 360)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 4000)
        try png.write(to: file)
    }
}
