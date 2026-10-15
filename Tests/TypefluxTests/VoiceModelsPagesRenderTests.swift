import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the Voice Input pages (overview, vocabulary, history, personas) and every Models tab,
/// including a speech and a language provider's detail, with the production `StudioView` in light
/// and dark. Set `TYPEFLUX_VOICE_MODELS_SNAPSHOTS=<dir>` to keep the PNGs.
@Suite("Voice input and models pages rendering", .serialized, .exclusiveUIState)
@MainActor
struct VoiceModelsPagesRenderTests {
    @Test func everyVoiceAndModelsPageRendersInLightAndDark() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            settings.interfaceStyle = .classic
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-render-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let history = FileHistoryStore(baseDir: root.appendingPathComponent("history"))
            let now = Date()
            for (offset, text) in ["把下周的发布计划整理成三点，发到群里。", "帮我回复：周四下午三点可以开会。",
                                   "Typeflux 的启动器支持关键词和工作流。"].enumerated() {
                history.save(record: HistoryRecord(date: now.addingTimeInterval(Double(-offset) * 600),
                                                   transcriptText: text))
            }
            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
                let model = StudioViewModel(settingsStore: settings, historyStore: history, initialSection: .home,
                                            localModelManager: FixtureLocalModels(), modelLibrary: library)
                model.vocabularyEntries = ["Typeflux", "PGVector", "SwiftUI", "Liquid Glass"].map {
                    VocabularyEntry(term: $0, source: .manual)
                }
                let suffix = dark ? "dark" : "light"
                for section in StudioSection.voiceInputCases {
                    model.navigate(to: section)
                    try await render(StudioView(viewModel: model), dark: dark, name: "voice-\(section.rawValue)-\(suffix)")
                }
                model.navigate(to: .models)
                for tab in ModelPageTab.allCases {
                    model.selectModelPageTab(tab)
                    try await render(StudioView(viewModel: model), dark: dark, name: "models-\(tab.rawValue)-\(suffix)")
                }
                model.selectModelPageTab(.speech)
                model.isShowingSpeechProviderDetail = true
                try await render(StudioView(viewModel: model), dark: dark, name: "models-speechDetail-\(suffix)")
                model.selectModelPageTab(.language)
                if let provider = library.providers.first {
                    model.selectedLanguageProviderID = provider.id
                    try await render(StudioView(viewModel: model), dark: dark, name: "models-languageDetail-\(suffix)")
                }
            }
        }
    }

    private func render(_ view: some View, dark: Bool, name: String) async throws {
        let size = NSSize(width: 1100, height: 1500)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -12000, y: -12000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(600))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 20000, "\(name) rendered blank")
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_VOICE_MODELS_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}
