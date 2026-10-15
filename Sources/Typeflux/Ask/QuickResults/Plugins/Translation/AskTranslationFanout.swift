import Foundation

struct AskTranslationResult: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case loading
        case streaming(String)
        case done(String, AskWordCard? = nil)
        case failed(AskTranslationFailure)
    }

    var service: AskTranslationService
    var name: String
    var state: State = .loading
    var fromWordBook = false
    var usedDictionary = false
    var id: String {
        service.id
    }

    var text: String? {
        switch state {
        case let .streaming(text), let .done(text, _): text
        default: nil
        }
    }

    var card: AskWordCard? {
        if case let .done(_, card) = state {
            card
        } else {
            nil
        }
    }

    var completedText: String? {
        if case let .done(text, _) = state {
            text
        } else {
            nil
        }
    }

    var collapseKey: String {
        "ask.translation.collapsed." + id
    }

    /// Every enabled service starts expanded, lookups included; an explicit collapse (1) survives
    /// new inputs and window hosts. `lookup` is kept for callers that lay rows out per mode.
    func isCollapsed(preference: Int, lookup _: Bool) -> Bool {
        preference == 1
    }

    func copyBoth(original: String) -> AskPluginAction? {
        guard let completedText else { return nil }
        return AskTranslatePlugin.copyAction(original + "\n\n" + completedText)
    }
}

/// A failure belongs to one service, with an actionable and credential-safe message.
struct AskTranslationFailure: Equatable, Sendable {
    enum Recovery: Equatable, Sendable {
        case configure, skip, retry, languages, none
        case download(source: String, target: String)
    }
    var message: String
    var recovery: Recovery

    static func presenting(_ error: Error, service: AskTranslationService, source: String?, target: String,
                           interface: AppLanguage) -> Self {
        if service.kind == .device {
            return onDeviceFailure(error, source: source, target: target, interface: interface)
        }
        switch error {
        case AskTranslationServiceError.notConfigured: return Self(
                message: L("ask.translation.error.notConfigured"),
                recovery: .configure
            )
        case AskTranslationServiceError.authentication: return Self(
                message: L("ask.translation.error.authentication"),
                recovery: .configure
            )
        case AskTranslationServiceError.quota: return Self(message: L("ask.translation.error.quota"), recovery: .skip)
        case AskTranslationServiceError.unsupportedLanguage:
            return Self(
                message: L(
                    "ask.translation.stack.unsupported",
                    AskTranslationLanguages.name(source ?? "auto", in: interface),
                    AskTranslationLanguages.name(target, in: interface)
                ),
                recovery: .none
            )
        case AskTranslationServiceError.tooLong: return Self(
                message: L("ask.translation.error.tooLong"),
                recovery: .none
            )
        case is URLError: return Self(message: L("ask.translation.stack.network"), recovery: .retry)
        case let failure as AskPluginFailure: return Self(
                message: failure.message,
                recovery: failure.retry ? .retry : .configure
            )
        case TypefluxCloudLLMError.notLoggedIn: return Self(message: L("ask.submission.signIn"), recovery: .configure)
        default: return Self(message: L("ask.translation.stack.failed"), recovery: .retry)
        }
    }

    private static func onDeviceFailure(_ error: Error, source: String?, target: String,
                                        interface: AppLanguage) -> Self {
        guard error is AskOnDeviceTranslationError, let source else {
            return Self(message: L("ask.plugin.translate.unavailable"), recovery: .languages)
        }
        return Self(message: L("ask.translation.stack.downloadRequired",
                               AskTranslationLanguages.name(source, in: interface),
                               AskTranslationLanguages.name(target, in: interface)),
                    recovery: .download(source: source, target: target))
    }

    func action(for service: AskTranslationService) -> AskPluginAction? {
        switch recovery {
        case .configure:
            .init(kind: service.provider.map(AskPluginAction.Kind.configureTranslation) ?? .openSettings,
                  title: L("ask.translation.stack.configure"), symbol: "gearshape")
        case .skip: .init(
                kind: .rerun(["skipService": service.id]),
                title: L("ask.translation.stack.skip"),
                symbol: "arrow.right"
            )
        case .retry: .init(
                kind: .rerun(["retryService": service.id]),
                title: L("ask.plugin.action.retry"),
                symbol: "arrow.clockwise"
            )
        case .languages: .init(
                kind: .manageTranslationLanguages,
                title: L("ask.translation.stack.languages"),
                symbol: "globe"
            )
        case let .download(source, target): .init(
                kind: .downloadTranslationLanguages(source: source, target: target),
                title: L("ask.translation.stack.download"), symbol: "arrow.down.circle"
            )
        case .none: nil
        }
    }
}

struct AskTranslationStack: Equatable, Sendable {
    var results: [AskTranslationResult]
    var source: String?
    var target: String
    var interface: AppLanguage
    var submitted: Bool
    var isLookup: Bool
    var replacesSelection = false
    var sourceIsAutomatic = true
}

struct AskTranslationFanoutRequest: Sendable {
    var text: String
    var source: String?
    var target: String
    var interface: AppLanguage
    var services: [AskTranslationService]
    var submitted: Bool
    var kept: AskWordCard?
    var options: [String: String] = [:]
}

/// One session's concurrent requests. Task cancellation stops cooperative engines;
/// generation checks also reject results from engines that ignore cancellation.
@MainActor
final class AskTranslationFanout {
    typealias Engine = @Sendable (AskTranslationService) -> (any AskTranslationEngine)?
    typealias Name = @Sendable (AskTranslationService) -> String
    typealias Progress = @MainActor @Sendable ([AskTranslationResult]) -> Void

    private struct Identity: Equatable {
        var text: String
        var source: String?
        var target: String
        var services: [AskTranslationService]
    }

    private var generation = 0
    private var task: Task<[AskTranslationResult], Error>?
    private var identity: Identity?
    private var previous: [AskTranslationResult] = []
    private var skipped = Set<String>()
    private var previousSubmitted = false

    private struct Batch: Sendable {
        var results: [AskTranslationResult]
        var tasks: [AskTranslationResult]
        var firstAI: String?
    }

    func run(_ request: AskTranslationFanoutRequest, engine: @escaping Engine, name: @escaping Name,
             dictionary: (@Sendable (AskTranslationService) -> (any AskWordLookingUp)?)? = nil,
             progress: @escaping Progress = { _ in }) async throws -> [AskTranslationResult] {
        try Task.checkCancellation()
        task?.cancel()
        generation += 1
        let current = generation
        let batch = prepare(request, name: name)
        previous = batch.results
        previousSubmitted = request.submitted
        progress(previous)
        let worker = Task { [self] in
            try await execute(batch, request: request, generation: current, engine: engine,
                              dictionary: dictionary, progress: progress)
        }
        task = worker
        defer {
            if generation == current {
                task = nil
            }
        }
        return try await withTaskCancellationHandler(
            operation: { try await worker.value },
            onCancel: { worker.cancel() }
        )
    }

    private func prepare(_ request: AskTranslationFanoutRequest, name: Name) -> Batch {
        let next = Identity(
            text: request.text,
            source: request.source,
            target: request.target,
            services: request.services
        )
        let targeted = request.options["retryService"] != nil || request.options["regenerateService"] != nil
        let reuse = identity == next && request.submitted && (previousSubmitted || targeted)
        identity = next
        if let skip = request.options["skipService"], reuse {
            skipped.insert(skip)
        }
        let only = request.options["regenerateService"] ?? (reuse ? request.options["retryService"] : nil)
        let firstAI = request.services.first {
            $0.isAI && ($0.enabled || request.options["regenerateService"] == $0.id)
        }
        let active = activeServices(request, firstAI: firstAI, only: only, reuse: reuse)
        var results = active.map { service in
            var row = reuse && (only != nil || request.options["skipService"] != nil)
                ? previous.first(where: { $0.id == service.id }) ?? AskTranslationResult(
                    service: service,
                    name: name(service)
                )
                : AskTranslationResult(service: service, name: name(service))
            if service.id == only, request.options["regenerateService"] != nil {
                row.fromWordBook = false
            }
            return row
        }
        if let kept = request.kept, firstAI != nil, !results.isEmpty {
            results[0].state = .done(kept.translatedText ?? kept.summary, kept)
            results[0].fromWordBook = true
        }
        let tasks = results.filter { result in
            !result.fromWordBook && (only == nil || result.id == only)
                && !(reuse && request.options["skipService"] != nil && only == nil)
        }
        for result in tasks {
            if let index = results.firstIndex(where: { $0.id == result.id }) {
                results[index].state = .loading
            }
        }
        return Batch(results: results, tasks: tasks, firstAI: firstAI?.id)
    }

    private func activeServices(_ request: AskTranslationFanoutRequest, firstAI: AskTranslationService?,
                                only: String?, reuse: Bool) -> [AskTranslationService] {
        var active = request.services.filter { ($0.enabled || request.options["regenerateService"] == $0.id)
            && !skipped.contains($0.id) && (request.submitted || $0.kind == .device)
        }
        if let only {
            active.removeAll { service in
                service.id != only && (!reuse || !previous.contains(where: { $0.id == service.id }))
            }
        }
        if request.kept != nil, let firstAI {
            active.removeAll(where: \.isAI)
            active.insert(firstAI, at: 0)
        } else if AskWordCard.isLookup(request.text), let firstAI,
                  let index = active.firstIndex(where: { $0.id == firstAI.id }) {
            active.insert(active.remove(at: index), at: 0)
        }
        return active
    }

    private func execute(
        _ batch: Batch,
        request: AskTranslationFanoutRequest,
        generation current: Int,
        engine: @escaping Engine,
        dictionary: (@Sendable (AskTranslationService) -> (any AskWordLookingUp)?)? = nil,
        progress: @escaping Progress
    ) async throws -> [AskTranslationResult] {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for result in batch.tasks {
                group.addTask {
                    do {
                        let answer = try await Self.translate(result.service, request: request,
                                                              writesCard: AskWordCard.isLookup(request.text) && result
                                                                  .id == batch.firstAI,
                                                              engine: engine, dictionary: dictionary) { state in
                            self.publish(state, id: result.id, generation: current, progress: progress)
                        }
                        try Task.checkCancellation()
                        await self.publish(answer.state, id: result.id, generation: current,
                                           usedDictionary: answer.usedDictionary, progress: progress)
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            throw CancellationError()
                        }
                        let failure = AskTranslationFailure.presenting(
                            error,
                            service: result.service,
                            source: request.source,
                            target: request.target,
                            interface: request.interface
                        )
                        await self.publish(.failed(failure), id: result.id, generation: current, progress: progress)
                    }
                }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        return previous
    }

    private struct Translation: Sendable {
        var state: AskTranslationResult.State
        var usedDictionary = false
    }

    private nonisolated static func translate(
        _ service: AskTranslationService,
        request: AskTranslationFanoutRequest,
        writesCard: Bool,
        engine: Engine,
        dictionary: (@Sendable (AskTranslationService) -> (any AskWordLookingUp)?)? = nil,
        progress: @escaping @MainActor @Sendable (AskTranslationResult.State) -> Void
    ) async throws -> Translation {
        let text = request.text, source = request.source, target = request.target
        try Task.checkCancellation()
        let translator = engine(service)
        if writesCard, let dictionary = dictionary?(service) ?? translator.flatMap({ $0 as? any AskWordLookingUp }) {
            return try await lookUp(dictionary, request: request, translator: translator)
        }
        guard let translator else { throw AskPluginFailure(message: L("ask.plugin.translate.noModel"), retry: false) }
        if let streaming = translator as? any AskTranslationStreaming {
            var translated = ""
            for try await piece in streaming.streamTranslation(text, from: source, to: target) {
                try Task.checkCancellation()
                translated += piece
                await progress(.streaming(translated))
            }
            return try Translation(state: completed(translated.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if service.kind == .device {
            switch await translator.availability(from: source, to: target) {
            case .installed: break
            case .supported: throw AskOnDeviceTranslationError.downloadRequired
            case .unsupported: throw AskPluginFailure(message: L("ask.plugin.translate.unavailable"), retry: false)
            }
        }
        return try await Translation(state: completed(translator.translate(text, from: source, to: target)))
    }

    private nonisolated static func lookUp(_ dictionary: any AskWordLookingUp, request: AskTranslationFanoutRequest,
                                           translator: (any AskTranslationEngine)?) async throws -> Translation {
        let answer = try await dictionary.lookUp(request.text, from: request.source, to: request.target,
                                                 generation: request.options["generation"] ?? "0")
        switch answer {
        case let .card(card):
            return Translation(state: .done(card.translatedText ?? card.summary, card), usedDictionary: true)
        case let .translation(text):
            return try Translation(state: completed(text), usedDictionary: true)
        case let .unreadable(raw):
            if AskWordCard.looksStructured(raw) {
                guard let translator else { throw AskPluginFailure(
                    message: L("ask.plugin.translate.noModel"),
                    retry: false
                ) }
                return try await Translation(
                    state: completed(translator.translate(request.text, from: request.source, to: request.target)),
                    usedDictionary: true
                )
            }
            return try Translation(state: completed(raw), usedDictionary: true)
        }
    }

    private nonisolated static func completed(_ text: String) throws -> AskTranslationResult.State {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AskPluginFailure(message: L("ask.plugin.translate.empty")) }
        return .done(text)
    }

    /// A new launcher session clears temporary quota skips and old results.
    func reset() {
        task?.cancel()
        task = nil
        generation += 1
        identity = nil
        previous = []
        skipped = []
        previousSubmitted = false
    }

    private func publish(
        _ state: AskTranslationResult.State,
        id: String,
        generation current: Int,
        usedDictionary: Bool = false,
        progress: Progress
    ) {
        guard generation == current, !Task.isCancelled,
              let index = previous.firstIndex(where: { $0.id == id }) else { return }
        previous[index].state = state
        previous[index].usedDictionary = usedDictionary
        progress(previous)
    }
}
