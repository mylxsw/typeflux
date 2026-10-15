import AppKit
import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif
import Testing
@testable import Typeflux

@Suite("Translation engine injection", .exclusiveUIState)
struct AskTranslationEngineFactoryTests {
    @Test func independentAIModelsKeepTheirReferencesAndReuseTheirOwnCaches() async throws {
        let defaults = UserDefaults(suiteName: "TranslationFactory-" + UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        let llm = AskTestLLMService()
        llm.answer = "Bonjour"
        let factory = AskTranslationEngineFactory(settings: settings, textProcessing: llm,
                                                  credentials: AskTestTranslationCredentials())
        let follows = try #require(factory.engine(for: .ai()) as? AskAITranslationEngine)
        #expect(try follows === #require(factory.engine(for: .ai(id: "another")) as? AskAITranslationEngine))
        let removed = try #require(factory.engine(for: .ai(
            id: "removed",
            modelReference: "custom:removed"
        )) as? AskAITranslationEngine)
        #expect(removed !== follows)
        await #expect(throws: AskPluginFailure.self) { try await removed.translate("hello", from: "en", to: "fr") }
        #expect(try await follows.translate("hello", from: "en", to: "fr") == "Bonjour")
        var streamed = ""
        for try await part in follows.streamTranslation("hello", from: "en", to: "fr") {
            streamed += part
        }
        #expect(streamed == "Bonjour")
        #expect(factory.name(for: .ai(id: "removed", modelReference: "custom:removed")) == AskPluginRegistry
            .sourceLabel(L("ask.models.unavailable")))
        #expect(factory.name(for: .device) == L("ask.translation.stack.deviceTitle"))
        for provider in AskTranslationProvider.allCases {
            #expect(factory.name(for: .provider(provider)) == provider.title)
            let engine = try #require(factory.engine(for: .provider(provider)) as? AskServiceTranslationEngine)
            #expect(!engine.isConfigured && engine.provider == provider)
        }
        #expect(await factory.engine(for: .device).canTranslate(from: nil, to: "en") == false)
        for index in 0 ..< 34 {
            _ = factory.engine(for: .ai(id: "\(index)", modelReference: "missing:\(index)"))
        }
        #expect(factory.name(for: .ai()).hasPrefix("AI"))
        let session = await factory.makeSession()
        let result = try await session.run(.init(text: "A sentence.", source: "en", target: "fr", interface: .english,
                                                 services: [.ai()], submitted: true),
                                           engine: { factory.engine(for: $0) },
                                           name: { factory.name(for: $0) })
        #expect(result.first?.completedText == "Bonjour")
    }

    @Test func emptyStreamingAITranslationFailsOnlyItsItem() async throws {
        let llm = AskTestLLMService()
        llm.answer = "   "
        let engine = AskAITranslationEngine(service: llm) { "test" }
        let coordinator = await MainActor.run { AskTranslationFanout() }
        let results = try await coordinator.run(
            .init(text: "A sentence.", source: "en", target: "fr", interface: .english,
                  services: [.ai()], submitted: true),
            engine: { _ in engine },
            name: { _ in "test" }
        )
        if case let .failed(failure) = results.first?.state {
            #expect(failure.recovery == .retry)
        } else {
            Issue.record("Empty stream succeeded")
        }
    }
}

extension AskTranslationEngineFactoryTests {
    @Test @MainActor func `download preparation retries only the current request and falls back on failure`(
    ) async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model.configuration
        var ready = 0
        var opened: [URL] = []
        model.downloadLanguages(source: "en", target: "zh-Hans")
        let first = try #require(model.languageDownload)
        fixture.model.lostFocus()
        #expect(model.languageDownload?.id == first.id)
        await model.prepareLanguages(first, prepare: {}, onReady: { ready += 1 }, openSettings: { opened.append($0) })
        #expect(ready == 1 && opened.isEmpty && model.languageDownload == nil)
        model.downloadLanguages(source: "ja", target: "en")
        let second = try #require(model.languageDownload)
        await model.prepareLanguages(second, prepare: { throw URLError(.notConnectedToInternet) },
                                     onReady: { ready += 1 }, openSettings: { opened.append($0) })
        #expect(ready == 1 && opened == [AskTranslationSettingsModel.languagePackagesURL])
        #expect(model.languageDownload == nil)
        model.downloadLanguages(source: "ko", target: "en")
        let cancelled = try #require(model.languageDownload)
        await model.prepareLanguages(cancelled, prepare: { throw CancellationError() },
                                     onReady: { ready += 1 }, openSettings: { opened.append($0) })
        #expect(model.languageDownload == nil && ready == 1 && opened.count == 1)
        model.downloadLanguages(source: "en", target: "fr")
        let previous = try #require(model.languageDownload)
        await model.prepareLanguages(previous, prepare: { model.downloadLanguages(source: "en", target: "de") },
                                     onReady: { ready += 1 }, openSettings: { opened.append($0) })
        #expect(model.languageDownload?.target == "de" && ready == 1)
        await model.prepareLanguages(previous, prepare: { throw URLError(.timedOut) },
                                     onReady: { ready += 1 }, openSettings: { opened.append($0) })
        #expect(model.languageDownload?.target == "de" && opened.count == 1)
        let ask = try AskTestFixture()
        defer { ask.model.resetSession() }
        #expect(ask.model.performPluginAction(.init(kind: .downloadTranslationLanguages(source: "en", target: "fr"),
                                                    title: "", symbol: "")) == .stay)
        #expect(ask.model.translationSettingsModel.languageDownload?.target == "fr")
    }
}


extension AskTranslationEngineFactoryTests {
    @Test func `Apple availability maps installed supported and unsupported separately`() {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            #expect(AskOnDeviceTranslationEngine.mappedAvailability(.installed) == .installed)
            #expect(AskOnDeviceTranslationEngine.mappedAvailability(.supported) == .supported)
            #expect(AskOnDeviceTranslationEngine.mappedAvailability(.unsupported) == .unsupported)
        }
        #endif
    }

    @Test @MainActor func `unavailable system download UI opens language settings once and clears the request`() async throws {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model.configuration
        model.downloadLanguages(source: "en", target: "zh-Hans")
        var ready = 0
        var opened: [URL] = []
        let host = NSHostingView(rootView: AskTranslationLanguageDownloadPresenter(
            model: model, onReady: { ready += 1 }, supportsSystemDownloads: false,
            openSettings: { opened.append($0) }
        ))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        for _ in 0 ..< 100 where model.languageDownload != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.languageDownload == nil)
        #expect(opened == [AskTranslationSettingsModel.languagePackagesURL] && ready == 0)
        host.layoutSubtreeIfNeeded()
        #expect(opened.count == 1)
    }
}
