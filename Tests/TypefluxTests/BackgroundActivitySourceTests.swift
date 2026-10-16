import Combine
import XCTest
@testable import Typeflux

@MainActor
final class BackgroundActivitySourceTests: XCTestCase {
    // MARK: - Speech model downloads

    func testSpeechDownloadMapsEachStatus() {
        XCTAssertTrue(SpeechModelDownloadActivitySource.activities(for: .idle).isEmpty)

        let running = SpeechModelDownloadActivitySource.activities(for: .downloading(model: .qwen3ASR, progress: 0.42))
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].id, SpeechModelDownloadActivitySource.activityID)
        XCTAssertEqual(running[0].title, L("activity.speechModel.title", LocalSTTModel.qwen3ASR.displayName))
        XCTAssertEqual(running[0].detail, L("activity.download.percent", "42%"))
        XCTAssertEqual(running[0].progress, 0.42)
        XCTAssertEqual(running[0].state, .running)
        XCTAssertEqual(running[0].route, .speechModels)

        let failed = SpeechModelDownloadActivitySource.activities(for: .failed(model: .senseVoiceSmall, message: "Offline"))
        XCTAssertEqual(failed[0].state, .failed)
        XCTAssertEqual(failed[0].detail, L("activity.download.failed", "Offline"))
        XCTAssertEqual(failed[0].actions, [.open, .dismiss])
    }

    func testSpeechDownloadCompletesOnlyWhenItReachedTheEnd() {
        var status: LocalModelDownloadProgressStatus = .downloading(model: .whisperLocal, progress: 0.5)
        let changes = PassthroughSubject<Void, Never>()
        let source = SpeechModelDownloadActivitySource(status: { status }, changes: changes.eraseToAnyPublisher())
        let recorder = Recorder(source)
        XCTAssertEqual(recorder.latest.map(\.id), [SpeechModelDownloadActivitySource.activityID])

        status = .idle
        source.refresh()
        XCTAssertTrue(recorder.completions.isEmpty, "idle at 50% is a cancellation")
        XCTAssertTrue(recorder.latest.isEmpty)

        status = .downloading(model: .whisperLocal, progress: 1)
        source.refresh()
        status = .idle
        source.refresh()
        XCTAssertEqual(recorder.completions.map(\.title),
                       [L("activity.speechModel.title", LocalSTTModel.whisperLocal.displayName)])
        XCTAssertEqual(recorder.completions.first?.notifies, false)
    }

    func testSpeechDownloadRefreshesOnChangesAndDismissesFailures() {
        var status: LocalModelDownloadProgressStatus = .idle
        let changes = PassthroughSubject<Void, Never>()
        let source = SpeechModelDownloadActivitySource(status: { status }, changes: changes.eraseToAnyPublisher())
        let recorder = Recorder(source)

        status = .failed(model: .whisperLocal, message: "x")
        changes.send()
        drainMainQueue()
        XCTAssertEqual(recorder.latest.first?.state, .failed)

        source.perform(.retry, on: SpeechModelDownloadActivitySource.activityID)
        source.perform(.dismiss, on: "other")
        XCTAssertEqual(recorder.latest.count, 1)
        source.perform(.dismiss, on: SpeechModelDownloadActivitySource.activityID)
        XCTAssertTrue(recorder.latest.isEmpty)
    }

    // MARK: - File name index

    func testFileIndexShowsOnlyWhileBuilding() {
        var status = AskFileIndexStatus()
        XCTAssertTrue(FileIndexActivitySource.activities(for: status).isEmpty)

        status.phase = .building(found: 1200, estimate: 2400)
        let estimated = FileIndexActivitySource.activities(for: status)
        XCTAssertEqual(estimated.first?.progress, 0.5)
        XCTAssertEqual(estimated.first?.detail, L("activity.fileIndex.progress", 1200.formatted(), 2400.formatted()))
        XCTAssertEqual(estimated.first?.route, .contentSearchSettings)
        XCTAssertEqual(estimated.first?.kind, .index)

        status.phase = .building(found: 30, estimate: nil)
        let unknown = FileIndexActivitySource.activities(for: status)
        XCTAssertNil(unknown.first?.progress)
        XCTAssertEqual(unknown.first?.detail, L("activity.fileIndex.found", 30.formatted()))

        status.phase = .building(found: 30, estimate: 0)
        XCTAssertEqual(FileIndexActivitySource.activities(for: status).first?.detail,
                       L("activity.fileIndex.found", 30.formatted()))
    }

    func testFileIndexCompletesWhenABuildBecomesReady() {
        var status = AskFileIndexStatus(phase: .loading)
        let changes = PassthroughSubject<Void, Never>()
        let source = FileIndexActivitySource(status: { status }, changes: changes.eraseToAnyPublisher())
        let recorder = Recorder(source)

        status.phase = .ready
        source.refresh()
        XCTAssertTrue(recorder.completions.isEmpty, "loading a saved index is not a build")

        status.phase = .building(found: 1, estimate: nil)
        changes.send()
        drainMainQueue()
        XCTAssertEqual(recorder.latest.count, 1)
        source.perform(.pause, on: FileIndexActivitySource.activityID)

        status.phase = .ready
        source.refresh()
        XCTAssertEqual(recorder.completions.map(\.kind), [.index])
        XCTAssertTrue(recorder.latest.isEmpty)
    }

    // MARK: - Content index

    func testContentIndexMapsModelDownload() {
        let activities = ContentIndexActivitySource.activities(for: .init(phase: .downloading(0.5)))
        XCTAssertEqual(activities.map(\.id), [ContentIndexActivitySource.modelID])
        XCTAssertEqual(activities[0].detail, BackgroundActivityFormat.bytes(fraction: 0.5, of: SemanticModel.bytes))
        XCTAssertEqual(activities[0].actions, [.cancel])
        XCTAssertEqual(activities[0].kind, .download)
    }

    func testContentIndexMapsIndexingWithMediaModelDownload() {
        var summary = SemanticFileIndexer.Summary()
        summary.total = 200
        summary.processed = 50
        let activities = ContentIndexActivitySource.activities(for: .init(
            phase: .indexing, modelReady: true, mediaDownload: 0.25, indexProgress: summary
        ))

        XCTAssertEqual(activities.map(\.id), [ContentIndexActivitySource.mediaModelID, ContentIndexActivitySource.indexID])
        XCTAssertEqual(activities[0].detail,
                       BackgroundActivityFormat.bytes(fraction: 0.25, of: SemanticMediaModel.bytes))
        XCTAssertEqual(activities[1].progress, 0.25)
        XCTAssertEqual(activities[1].detail, L("activity.contentIndex.progress", 50.formatted(), 200.formatted()))
        XCTAssertEqual(activities[1].actions, [.pause])
        XCTAssertEqual(activities[1].state, .running)
    }

    func testContentIndexMapsScanningWaitingAndPaused() {
        var summary = SemanticFileIndexer.Summary()
        summary.scanned = 12
        let scanning = ContentIndexActivitySource.activities(for: .init(phase: .indexing, indexProgress: summary))
        XCTAssertNil(scanning[0].progress)
        XCTAssertEqual(scanning[0].detail, L("activity.contentIndex.scanning", 12.formatted()))
        XCTAssertEqual(ContentIndexActivitySource.activities(for: .init(phase: .indexing))[0].detail,
                       L("activity.contentIndex.scanning", 0.formatted()))

        summary.total = 0
        summary.waitingForIdle = true
        let waiting = ContentIndexActivitySource.activities(for: .init(phase: .indexing, indexProgress: summary))
        XCTAssertEqual(waiting[0].state, .waiting)
        XCTAssertNil(waiting[0].progress)
        XCTAssertTrue(waiting[0].actions.isEmpty)
        XCTAssertEqual(waiting[0].detail,
                       L("activity.contentIndex.waitingIdle", L("activity.contentIndex.progress", "0", "0")))

        summary.total = 10
        summary.processed = 5
        let paused = ContentIndexActivitySource.activities(for: .init(phase: .paused, indexProgress: summary))
        XCTAssertEqual(paused[0].state, .paused)
        XCTAssertEqual(paused[0].actions, [.resume])
        XCTAssertEqual(paused[0].detail, L("activity.paused", L("activity.contentIndex.progress", "5", "10")))
        XCTAssertTrue(ContentIndexActivitySource.activities(for: .init(phase: .paused)).isEmpty)
    }

    func testContentIndexMapsFailuresAndRestingPhases() {
        let model = ContentIndexActivitySource.activities(for: .init(phase: .failed))
        XCTAssertEqual(model.map(\.id), [ContentIndexActivitySource.modelID])
        XCTAssertEqual(model[0].detail, L("semantic.failed.download"))
        XCTAssertEqual(model[0].actions, [.retry, .dismiss])

        let index = ContentIndexActivitySource.activities(for: .init(phase: .failed, modelReady: true))
        XCTAssertEqual(index.map(\.id), [ContentIndexActivitySource.indexID])
        XCTAssertEqual(index[0].detail, L("semantic.failed.index"))
        XCTAssertEqual(ContentIndexActivitySource.activities(for: .init(phase: .failed, modelReady: true,
                                                                        mediaFailed: true))[0].detail,
                       L("semantic.media.failed"))

        for phase: SemanticFileSearchService.Phase in [.off, .preparing, .modelRequired, .ready] {
            XCTAssertTrue(ContentIndexActivitySource.activities(for: .init(phase: phase)).isEmpty, "\(phase)")
        }
    }

    func testContentIndexCompletions() {
        typealias Input = ContentIndexActivityInput
        func ids(_ from: Input, _ to: Input) -> [String] {
            ContentIndexActivitySource.completions(from: from, to: to).map(\.0)
        }
        XCTAssertEqual(ids(.init(phase: .downloading(0.9)), .init(phase: .preparing, modelReady: true)),
                       [ContentIndexActivitySource.modelID])
        XCTAssertEqual(ids(.init(phase: .downloading(0.9)), .init(phase: .downloading(1), modelReady: true)), [])
        XCTAssertEqual(ids(.init(phase: .downloading(0.9)), .init(phase: .failed)), [])
        XCTAssertEqual(ids(.init(phase: .downloading(0.9)), .init(phase: .modelRequired)), [])
        XCTAssertEqual(ids(.init(phase: .indexing, mediaDownload: 0.9), .init(phase: .indexing)),
                       [ContentIndexActivitySource.mediaModelID])
        XCTAssertEqual(ids(.init(phase: .indexing, mediaDownload: 0.9), .init(phase: .indexing, mediaFailed: true)), [])
        XCTAssertEqual(ids(.init(phase: .indexing, mediaDownload: 0.9), .init(phase: .off)), [])
        XCTAssertEqual(ids(.init(phase: .indexing), .init(phase: .ready)), [ContentIndexActivitySource.indexID])
        XCTAssertEqual(ids(.init(phase: .paused, indexProgress: .init()), .init(phase: .ready)),
                       [ContentIndexActivitySource.indexID])
        XCTAssertEqual(ids(.init(phase: .paused), .init(phase: .ready)), [])
        XCTAssertEqual(ids(.init(phase: .indexing), .init(phase: .failed)), [])
    }

    func testContentIndexRoutesActionsToTheService() {
        let service = FakeContentIndexService()
        let source = ContentIndexActivitySource(service: service)
        let recorder = Recorder(source)

        source.perform(.cancel, on: ContentIndexActivitySource.modelID)
        source.perform(.pause, on: ContentIndexActivitySource.indexID)
        source.perform(.resume, on: ContentIndexActivitySource.indexID)
        source.perform(.retry, on: ContentIndexActivitySource.modelID)
        source.perform(.retry, on: ContentIndexActivitySource.indexID)
        source.perform(.stop, on: ContentIndexActivitySource.indexID)
        XCTAssertEqual(service.calls, ["cancel", "pause:true", "pause:false", "download", "start:true"])

        service.input = .init(phase: .failed)
        service.changes.send()
        drainMainQueue()
        XCTAssertEqual(recorder.latest.map(\.state), [.failed])
        source.perform(.dismiss, on: ContentIndexActivitySource.modelID)
        XCTAssertTrue(recorder.latest.isEmpty)

        service.input = .init(phase: .downloading(0.4))
        service.changes.send()
        drainMainQueue()
        service.input = .init(phase: .preparing, modelReady: true)
        service.changes.send()
        drainMainQueue()
        XCTAssertEqual(recorder.completions.map(\.activityID), [ContentIndexActivitySource.modelID])
        XCTAssertEqual(recorder.completions.first?.notifies, true)
    }

    func testSemanticServiceReportsItsActivityInput() {
        let suite = "BackgroundActivitySourceTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let service = SemanticFileSearchService(settings: SettingsStore(defaults: UserDefaults(suiteName: suite)!),
                                                supported: false, automaticStart: false)
        XCTAssertEqual(service.activityInput, ContentIndexActivityInput())
        var fired = false
        let cancellable = service.activityChanges.sink { fired = true }
        defer { cancellable.cancel() }
        service.objectWillChange.send()
        XCTAssertTrue(fired)
    }

    // MARK: - Agent runs

    func testAgentRunsMapApprovalPlanAndCurrentStep() {
        let call = AskToolCall(id: "t1", function: .init(name: "web_search", arguments: "{}"))
        let plan = [AskPlanItem(step: "a", status: "completed"), AskPlanItem(step: "b", status: "in_progress"),
                    AskPlanItem(step: "c", status: "pending"), AskPlanItem(step: "d", status: "pending")]
        let activities = AgentRunActivitySource.activities(for: .init(runs: [
            .init(id: "c1", title: "Plan run", step: call, plan: plan),
            .init(id: "c2", title: "  ", approval: call),
            .init(id: "c3", title: nil),
        ]))

        XCTAssertEqual(activities.map(\.id), ["agent.c1", "agent.c2", "agent.c3"])
        XCTAssertEqual(activities[0].progress, 0.25)
        XCTAssertEqual(activities[0].detail, L("activity.agent.planStep", 2, 4, AskTheme.toolTitle(call)))
        XCTAssertEqual(activities[0].actions, [.open, .stop])
        XCTAssertEqual(activities[0].route, .conversation("c1"))
        XCTAssertEqual(activities[1].state, .attention)
        XCTAssertEqual(activities[1].title, L("activity.agent.untitled"))
        XCTAssertEqual(activities[1].detail, L("activity.agent.approval", AskTheme.toolTitle(call)))
        XCTAssertNil(activities[2].progress)
        XCTAssertEqual(activities[2].detail, L("ask.activity.working"))
        XCTAssertEqual(activities[2].state, .running)
    }

    func testAgentRunsCompleteUnlessStoppedFromTheMenu() {
        let model = FakeAgentModel()
        model.input = .init(runs: [.init(id: "a", title: "A"), .init(id: "b", title: "B")])
        let source = AgentRunActivitySource(model: model, refreshInterval: .milliseconds(1))
        let recorder = Recorder(source)
        XCTAssertEqual(recorder.latest.count, 2)

        source.perform(.stop, on: "agent.b")
        source.perform(.stop, on: "other")
        source.perform(.pause, on: "agent.a")
        XCTAssertEqual(model.stopped, ["b"])

        model.input = .init()
        source.refresh()
        XCTAssertEqual(recorder.completions.map(\.title), ["A"])
        XCTAssertEqual(recorder.completions.first?.kind, .agent)

        model.input = .init(runs: [.init(id: "b", title: "B")])
        model.changes.send()
        let expectation = expectation(description: "refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        model.input = .init()
        source.refresh()
        XCTAssertEqual(recorder.completions.map(\.title), ["A", "B"], "a stop is forgotten once the run ends")
    }

    // MARK: - Ollama pulls

    func testOllamaPullReportsProgressCompletionAndCancel() {
        let source = OllamaPullActivitySource()
        let recorder = Recorder(source)
        let cancelled = CancelFlag()

        source.pullStarted(model: "qwen3:8b", cancel: { cancelled.set() })
        source.refresh()
        XCTAssertEqual(recorder.latest.first?.detail, L("activity.preparing"))
        XCTAssertNil(recorder.latest.first?.progress)

        source.pullProgressed(model: "qwen3:8b", completed: 50, total: 200)
        source.pullProgressed(model: "unknown", completed: 1, total: 2)
        source.refresh()
        XCTAssertEqual(recorder.latest.map(\.id), [OllamaPullActivitySource.activityID("qwen3:8b")])
        XCTAssertEqual(recorder.latest.first?.progress, 0.25)
        XCTAssertEqual(recorder.latest.first?.detail, BackgroundActivityFormat.bytes(50, of: 200))
        XCTAssertEqual(recorder.latest.first?.title, L("activity.llmModel.title", "qwen3:8b"))

        source.perform(.cancel, on: OllamaPullActivitySource.activityID("qwen3:8b"))
        XCTAssertTrue(cancelled.isSet)

        source.pullFinished(model: "qwen3:8b", error: nil)
        source.pullProgressed(model: "qwen3:8b", completed: 60, total: 200)
        source.refresh()
        XCTAssertTrue(recorder.latest.isEmpty, "late progress never revives a finished pull")
        XCTAssertEqual(recorder.completions.map(\.activityID), [OllamaPullActivitySource.activityID("qwen3:8b")])
        XCTAssertEqual(recorder.completions.first?.notifies, true)
    }

    func testOllamaPullFailureStaysUntilDismissedAndCancellationDisappears() {
        let source = OllamaPullActivitySource()
        let recorder = Recorder(source)
        let id = OllamaPullActivitySource.activityID("m")

        source.pullStarted(model: "m", cancel: {})
        source.pullFinished(model: "m", error: OllamaPullProgress.Failure(message: "disk full"))
        source.refresh()
        XCTAssertEqual(recorder.latest.first?.state, .failed)
        XCTAssertEqual(recorder.latest.first?.detail, L("activity.download.failed", "disk full"))
        XCTAssertEqual(recorder.latest.first?.actions, [.dismiss])

        source.perform(.cancel, on: id)
        XCTAssertEqual(recorder.latest.count, 1)
        source.perform(.dismiss, on: id)
        XCTAssertTrue(recorder.latest.isEmpty)

        source.pullStarted(model: "m", cancel: {})
        source.perform(.dismiss, on: id)
        XCTAssertEqual(recorder.latest.count, 1, "a running pull cannot be dismissed")
        source.pullFinished(model: "m", error: CancellationError())
        source.refresh()
        XCTAssertTrue(recorder.latest.isEmpty)
        XCTAssertTrue(recorder.completions.isEmpty)
    }

    func testOllamaPullRefreshesOnTheMainActorByItself() async throws {
        let source = OllamaPullActivitySource()
        let recorder = Recorder(source)
        await Task.detached { source.pullStarted(model: "m", cancel: {}) }.value
        for _ in 0 ..< 50 where recorder.latest.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(recorder.latest.count, 1)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@MainActor
private final class Recorder {
    var latest: [BackgroundActivity] = []
    var completions: [BackgroundActivityCompletion] = []
    private var cancellables = Set<AnyCancellable>()

    init(_ source: any BackgroundActivitySource) {
        source.activitiesPublisher.sink { [unowned self] in latest = $0 }.store(in: &cancellables)
        source.completionsPublisher.sink { [unowned self] in completions.append($0) }.store(in: &cancellables)
    }
}

@MainActor
private final class FakeContentIndexService: ContentIndexActivityControlling {
    var input = ContentIndexActivityInput()
    let changes = PassthroughSubject<Void, Never>()
    var calls: [String] = []

    var activityInput: ContentIndexActivityInput { input }
    var activityChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    func downloadModel() { calls.append("download") }
    func cancelDownload() { calls.append("cancel") }
    func pause(_ paused: Bool) { calls.append("pause:\(paused)") }
    func start(force: Bool) { calls.append("start:\(force)") }
}

@MainActor
private final class FakeAgentModel: AgentActivityControlling {
    var input = AgentActivityInput()
    let changes = PassthroughSubject<Void, Never>()
    var stopped: [String] = []

    var agentActivityInput: AgentActivityInput { input }
    var agentActivityChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    func stopAgentRun(_ id: String) { stopped.append(id) }
}
