import SwiftUI
import Testing
@testable import Typeflux

extension ProductMotionTests {
    func translation(_ capture: ProductMotionCapture, directory: URL) async throws {
        capture.clear()
        let f = TranslationPanelFixture()
        defer { f.clean() }
        let original = "Make room for what matters. Turn an idea into something worth sharing."
        let answer = "给重要的事留一点空间。把一个想法，变成值得分享的作品。"
        f.model.open(source: .input, text: original)
        let id = UUID()
        f.model.adoptHandoff(.init(plugin: f.model.plugin, plan: .init(mode: .onSubmit, title: ""),
            request: .init(text: original, origin: .argument, keyword: AskTranslatePlugin.keywords[0], options: [:], interfaceLanguage: .simplifiedChinese), output: nil, running: true, cancel: {}), id: id)
        capture.mount(AskTranslationPanelView(model: f.model, history: f.model.history, height: 420), size: CGSize(width: 680, height: 420))
        var previous = -1
        try await capture.record("translation", duration: 5, directory: directory) { t in
            let count = min(answer.count,max(0,Int((t-0.6)*12)))
            if count != previous {
                previous = count
                let text = String(answer.prefix(count))
                let rows: [AskTranslationResult] = [.init(service: .ai(), name: "AI · Typeflux Cloud", state: .done(text))]
                let output = AskPluginOutput(body: text, original: original, meta: [], source: "AI · Typeflux Cloud",
                    actions: [AskTranslatePlugin.copyAction(text, shortcut: .enter)],
                    translation: .init(results: rows, source: "en", target: "zh-Hans", interface: .simplifiedChinese, submitted: true, isLookup: false))
                f.model.receiveHandoff(count == answer.count ? .done(output) : .progress(output), id: id)
            }
        }
    }
}
