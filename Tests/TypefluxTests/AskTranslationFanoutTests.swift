import Foundation
import Testing
@testable import Typeflux

private final class ControlledTranslation: AskTranslationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var inputs: [String] = []
    var requests: [String] {
        lock.withLock { inputs }
    }

    func canTranslate(from _: String?, to _: String) async -> Bool {
        true
    }

    func translate(_ text: String, from _: String?, to _: String) async throws -> String {
        // Deliberately ignore cancellation to exercise generation protection.
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[text] = continuation; inputs.append(text) }
        }
    }

    func finish(_ text: String, answer: String) {
        lock.withLock { pending.removeValue(forKey: text) }?.resume(returning: answer)
    }
}

private final class ControlledStreamingTranslation: AskTranslationStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AsyncThrowingStream<String, Error>.Continuation?
    var started: Bool {
        lock.withLock { current != nil }
    }

    func canTranslate(from _: String?, to _: String) async -> Bool {
        true
    }

    func translate(_: String, from _: String?, to _: String) async throws -> String {
        "unused"
    }

    func streamTranslation(_: String, from _: String?, to _: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in lock.withLock { current = continuation } }
    }

    func emit(_ text: String) {
        lock.withLock { current }?.yield(text)
    }

    func finish() {
        lock.withLock { current }?.finish()
    }
}

@Suite("Concurrent translation services", .exclusiveUIState)
@MainActor
struct AskTranslationFanoutTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Timed out waiting for an engine")
    }

    @Test func servicesStartTogetherAndPublishInSettingsOrder() async throws {
        let device = ControlledTranslation()
        let ai = ControlledTranslation()
        let coordinator = AskTranslationFanout()
        var updates: [[AskTranslationResult]] = []
        let work = Task {
            try await coordinator.run(
                .init(text: "A complete sentence.", source: "en", target: "fr", interface: .english,
                      services: [.device, .ai()], submitted: true),
                engine: { $0.isAI ? ai : device },
                name: { $0.id }
            ) { updates.append($0) }
        }
        try await wait { device.requests.count == 1 && ai.requests.count == 1 }
        #expect(updates.first?.map(\.state) == [.loading, .loading])
        ai.finish("A complete sentence.", answer: "AI")
        try await wait { updates.last?.last?.completedText == "AI" }
        #expect(updates.last?.first?.state == .loading)
        device.finish("A complete sentence.", answer: "Device")
        let result = try await work.value
        #expect(result.map(\.id) == ["device", "ai.primary"])
        #expect(result.map(\.completedText) == ["Device", "AI"])
    }

    @Test func newInputCancelsOldWorkAndDropsLateResults() async throws {
        let engine = ControlledTranslation()
        let coordinator = AskTranslationFanout()
        var oldUpdates: [String] = []
        let old = Task {
            try await coordinator.run(.init(text: "Old sentence.", source: "en", target: "fr", interface: .english,
                                            services: [.ai()], submitted: true), engine: { _ in engine },
                                      name: { $0.id }) {
                oldUpdates += $0.compactMap(\.completedText)
            }
        }
        try await wait { engine.requests.count == 1 }
        let new = Task {
            try await coordinator.run(.init(text: "New sentence.", source: "en", target: "fr", interface: .english,
                                            services: [.ai()], submitted: true), engine: { _ in engine },
                                      name: { $0.id })
        }
        try await wait { engine.requests.count == 2 }
        engine.finish("New sentence.", answer: "fresh")
        #expect(try await new.value.first?.completedText == "fresh")
        engine.finish("Old sentence.", answer: "stale")
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(oldUpdates.isEmpty)
    }

    @Test func callerCancellationNeverBecomesAFailureRow() async throws {
        let engine = ControlledTranslation()
        let coordinator = AskTranslationFanout()
        var updates: [[AskTranslationResult]] = []
        let work = Task {
            try await coordinator.run(
                .init(text: "Sentence.", source: "en", target: "fr", interface: .english,
                      services: [.ai()], submitted: true),
                engine: { _ in engine },
                name: { $0.id }
            ) { updates.append($0) }
        }
        try await wait { engine.requests.count == 1 }
        work.cancel()
        engine.finish("Sentence.", answer: "ignored")
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(updates.allSatisfy { $0.first?.state == .loading })
    }

    @Test func streamingPublishesPiecesAndTrimsTheFinalTranslation() async throws {
        let streaming = ControlledStreamingTranslation()
        let coordinator = AskTranslationFanout()
        var updates: [AskTranslationResult.State] = []
        let work = Task {
            try await coordinator.run(.init(text: "Sentence.", source: nil, target: "fr", interface: .english,
                                            services: [.ai()], submitted: true), engine: { _ in streaming },
                                      name: { $0.id }) {
                if let state = $0.first?.state {
                    updates.append(state)
                }
            }
        }
        try await wait { streaming.started }
        streaming.emit(" Bon")
        try await wait { updates.contains(.streaming(" Bon")) }
        streaming.emit("jour ")
        streaming.finish()
        #expect(try await work.value.first?.completedText == "Bonjour")
        #expect(updates.contains(.streaming(" Bonjour ")))
    }

    @Test func onlyFirstCheckedAIWritesCardsAndSavedCardsSkipEveryAI() async throws {
        let device = AskTestTranslationEngine()
        let first = AskTestTranslationEngine()
        let second = AskTestTranslationEngine()
        let card = AskWordCard(headword: "apple", translation: "苹果", senses: [.init(pos: "n.", meanings: ["苹果"])])
        let dictionary = AskTestWordLookup(answer: .card(card))
        let coordinator = AskTranslationFanout()
        let services: [AskTranslationService] = [.device, .ai(), .ai(id: "second")]
        let engines: AskTranslationFanout.Engine = { $0.id == "device" ? device : $0.id == "second" ? second : first }
        let rows = try await coordinator.run(.init(text: "apple", source: "en", target: "zh-Hans", interface: .english,
                                                   services: services, submitted: true), engine: engines,
                                             name: { $0.id },
                                             dictionary: { _ in dictionary })
        #expect(rows.map(\.id) == ["ai.primary", "device", "second"])
        #expect(rows.first?.card == card && dictionary.requests.count == 1)
        #expect(first.requests.isEmpty && second.requests.count == 1 && device.requests.count == 1)
        let saved = try await coordinator.run(.init(text: "apple", source: "en", target: "zh-Hans", interface: .english,
                                                    services: services, submitted: true, kept: card),
                                              engine: engines, name: { $0.id }, dictionary: { _ in dictionary })
        #expect(saved.first?.fromWordBook == true && saved.map(\.id) == ["ai.primary", "device"])
        #expect(dictionary.requests.count == 1 && second.requests.count == 1)
        let regenerated = try await coordinator.run(
            .init(text: "apple", source: "en", target: "zh-Hans", interface: .english,
                  services: services, submitted: true,
                  options: [
                      "regenerateService": "ai.primary",
                      "generation": "fresh"
                  ]),
            engine: engines,
            name: { $0.id },
            dictionary: { _ in dictionary }
        )
        #expect(regenerated.first?.fromWordBook == false && dictionary.requests.count == 2)
        #expect(dictionary.requests.last?.generation == "fresh" && second.requests.count == 1 && device.requests
            .count == 2)
        var disabled = services
        disabled[1].enabled = false
        let promoted = try await coordinator.run(.init(text: "pear", source: "en", target: "zh-Hans", interface: .english,
                                            services: disabled, submitted: true), engine: engines, name: { $0.id },
                                      dictionary: { _ in dictionary })
        #expect(promoted.first?.id == "second" && promoted.first?.card == card)
        #expect(dictionary.requests.count == 3 && first.requests.isEmpty && second.requests.count == 1)
        let cached = try await coordinator.run(.init(text: "pear", source: "en", target: "zh-Hans", interface: .english,
                                                    services: disabled, submitted: false, kept: card),
                                              engine: engines, name: { $0.id }, dictionary: { _ in dictionary })
        #expect(cached.first?.id == "second" && cached.first?.fromWordBook == true)
        #expect(dictionary.requests.count == 3)
        disabled[2].enabled = false
        let noAI = try await coordinator.run(.init(text: "pear", source: "en", target: "zh-Hans", interface: .english,
                                                  services: disabled, submitted: true, kept: card),
                                            engine: engines, name: { $0.id }, dictionary: { _ in dictionary })
        #expect(noAI.map(\.id) == ["device"] && noAI.allSatisfy { $0.card == nil })
        #expect(noAI.first?.completedText == "[zh-Hans] pear" && dictionary.requests.count == 3)
        let deviceOnly = try await coordinator.run(.init(text: "word", source: nil, target: "zh-Hans", interface: .english,
                                            services: [.device], submitted: false, kept: card), engine: engines,
                                      name: { $0.id })
        #expect(deviceOnly.allSatisfy { $0.card == nil })
    }

    @Test func previewNeverCallsRemoteEvenForLookupAndRetriesAreIsolated() async throws {
        let device = AskTestTranslationEngine()
        let ai = AskTestTranslationEngine()
        let provider = AskTestTranslationEngine(failure: AskTranslationServiceError.quota)
        let services: [AskTranslationService] = [.device, .ai(), .provider(.deepl, enabled: true)]
        let engines: AskTranslationFanout.Engine = { $0.kind == .device ? device : $0.isAI ? ai : provider }
        let coordinator = AskTranslationFanout()
        _ = try await coordinator.run(.init(text: "Sentence.", source: "en", target: "fr", interface: .english,
                                            services: services, submitted: false), engine: engines, name: { $0.id })
        #expect(ai.requests.isEmpty && provider.requests.isEmpty)
        let initial = try await coordinator.run(
            .init(text: "Sentence.", source: "en", target: "fr", interface: .english,
                  services: services, submitted: true),
            engine: engines,
            name: { $0.id }
        )
        if case let .failed(failure) = initial.last?.state {
            #expect(failure.recovery == .skip)
        } else {
            Issue.record("Missing quota failure")
        }
        provider.failure = nil
        let retried = try await coordinator.run(
            .init(text: "Sentence.", source: "en", target: "fr", interface: .english,
                  services: services, submitted: true,
                  options: ["retryService": "provider.deepl"]),
            engine: engines,
            name: { $0.id }
        )
        #expect(retried.last?.completedText != nil)
        #expect(ai.requests.count == 1 && device.requests.count == 2 && provider.requests.count == 2)
        let skipped = try await coordinator.run(
            .init(text: "Sentence.", source: "en", target: "fr", interface: .english,
                  services: services, submitted: true,
                  options: ["skipService": "provider.deepl"]),
            engine: engines,
            name: { $0.id }
        )
        #expect(skipped.map(\.id) == ["device", "ai.primary"] && ai.requests.count == 1)
        _ = try await coordinator.run(
            .init(text: "Different sentence.", source: "en", target: "fr", interface: .english,
                  services: services, submitted: true,
                  options: ["retryService": "provider.deepl"]),
            engine: engines,
            name: { $0.id }
        )
        #expect(provider.requests.count == 2 && ai.requests.count == 2, "quota skips last for the session")
        coordinator.reset()
        _ = try await coordinator.run(
            .init(text: "Different sentence.", source: "en", target: "fr", interface: .english,
                  services: services, submitted: true),
            engine: engines,
            name: { $0.id }
        )
        #expect(provider.requests.count == 3)
    }

    @Test func errorsOfferTheRightRecoveryWithoutExposingRemoteMessages() async throws {
        let service = AskTranslationService.provider(.deepl)
        let cases: [(Error, AskTranslationFailure.Recovery)] = [
            (AskTranslationServiceError.notConfigured, .configure), (
                AskTranslationServiceError.authentication,
                .configure
            ),
            (AskTranslationServiceError.quota, .skip), (AskTranslationServiceError.unsupportedLanguage, .none),
            (AskTranslationServiceError.tooLong, .none), (URLError(.timedOut), .retry),
            (AskPluginFailure(message: "missing", retry: false), .configure), (
                AskPluginFailure(message: "retry"),
                .retry
            ),
            (TypefluxCloudLLMError.notLoggedIn, .configure), (
                AskTranslationServiceError.service("sensitive-remote-body"),
                .retry
            )
        ]
        for (error, recovery) in cases {
            let failure = AskTranslationFailure.presenting(
                error,
                service: service,
                source: "ja",
                target: "ko",
                interface: .english
            )
            #expect(failure.recovery == recovery)
            #expect(!failure.message.contains("sensitive-remote-body"))
            #expect((failure.action(for: service) == nil) == (recovery == .none))
        }
        let local = AskTranslationFailure.presenting(
            URLError(.timedOut),
            service: .device,
            source: nil,
            target: "en",
            interface: .english
        )
        #expect(local.action(for: .device)?.kind == .manageTranslationLanguages)
        let ai = AskTranslationFailure(message: "", recovery: .configure)
        #expect(ai.action(for: .ai())?.kind == .openSettings)
        let coordinator = AskTranslationFanout()
        let missing = try await coordinator.run(.init(text: "Sentence.", source: nil, target: "en", interface: .english,
                                                      services: [.ai()], submitted: true), engine: { _ in nil },
                                                name: { $0.id })
        if case .failed = missing.first?.state {} else {
            Issue.record("Missing model failure")
        }
        let empty = try await coordinator.run(.init(text: "x", source: nil, target: "en", interface: .english,
                                                    services: [], submitted: true), engine: { _ in nil },
                                              name: { $0.id })
        #expect(empty.isEmpty)
    }
}

private struct AvailableDeviceTranslation: AskTranslationEngine {
    var status: AskTranslationAvailability
    func canTranslate(from _: String?, to _: String) async -> Bool {
        status == .installed
    }

    func availability(from _: String?, to _: String) async -> AskTranslationAvailability {
        status
    }

    func translate(_ text: String, from _: String?, to _: String) async throws -> String {
        "Translated: " + text
    }
}

extension AskTranslationFanoutTests {
    @Test func `on device availability distinguishes installed missing pack and unsupported`() async throws {
        let savedLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(savedLanguage) }
        AppLocalization.shared.setLanguage(.english)
        for status in [AskTranslationAvailability.installed, .supported, .unsupported] {
            let engine = AskOnDeviceTranslationEngine(checkAvailability: { source, target in
                #expect(source == "en" && target == "zh-Hans")
                return status
            })
            #expect(await engine.availability(from: "en", to: "zh-Hans") == status)
            #expect(await engine.canTranslate(from: "en", to: "zh-Hans") == (status == .installed))
            let rows = try await AskTranslationFanout().run(
                .init(text: "A source sentence.", source: "en", target: "zh-Hans", interface: .english,
                      services: [.device], submitted: true),
                engine: { _ in AvailableDeviceTranslation(status: status) }, name: { _ in "On-device" }
            )
            let row = try #require(rows.first)
            switch status {
            case .installed:
                #expect(row.completedText == "Translated: A source sentence.")
            case .supported:
                guard case let .failed(failure) = row.state else { Issue.record("Missing download recovery"); continue }
                #expect(failure.message == L("ask.translation.stack.downloadRequired",
                                             AskTranslationLanguages.name("en", in: .english),
                                             AskTranslationLanguages.name("zh-Hans", in: .english)))
                #expect(failure.action(for: .device)?.title == "Download")
                #expect(failure.action(for: .device)?.kind == .downloadTranslationLanguages(
                    source: "en",
                    target: "zh-Hans"
                ))
                let fixture = TranslationPanelFixture()
                defer { fixture.clean() }
                try fixture.model.perform(#require(failure.action(for: .device)))
                #expect(fixture.model.configuration.languageDownload?.source == "en")
                #expect(fixture.model.configuration.languageDownload?.target == "zh-Hans")
            case .unsupported:
                guard case let .failed(failure) = row.state else { Issue.record("Missing unsupported error"); continue }
                #expect(failure.message == L("ask.plugin.translate.unavailable"))
                #expect(failure.action(for: .device)?.kind == .manageTranslationLanguages)
            }
        }
    }
}
