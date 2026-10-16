import Combine
import Foundation

/// What the content index activities are made from.
struct ContentIndexActivityInput: Equatable {
    var phase: SemanticFileSearchService.Phase = .off
    var modelReady = false
    var mediaDownload: Double?
    var mediaFailed = false
    var indexProgress: SemanticFileIndexer.Summary?
}

/// The content index and what it needs: control over its model download and indexing.
@MainActor
protocol ContentIndexActivityControlling: AnyObject {
    var activityInput: ContentIndexActivityInput { get }
    var activityChanges: AnyPublisher<Void, Never> { get }
    func downloadModel()
    func cancelDownload()
    func pause(_ paused: Bool)
    func start(force: Bool)
}

extension SemanticFileSearchService: ContentIndexActivityControlling {
    var activityInput: ContentIndexActivityInput {
        ContentIndexActivityInput(phase: phase, modelReady: modelReady, mediaDownload: mediaDownload,
                                  mediaFailed: mediaFailed, indexProgress: indexProgress)
    }

    var activityChanges: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in }.eraseToAnyPublisher()
    }
}

/// The content index: its search model download, the voice search model download
/// it needs for audio and video, and indexing itself.
@MainActor
final class ContentIndexActivitySource: BackgroundActivitySource {
    static let modelID = "content.model"
    static let mediaModelID = "content.mediaModel"
    static let indexID = "content.index"

    private let feed: BackgroundActivityFeed
    private let service: any ContentIndexActivityControlling
    private var last = ContentIndexActivityInput()
    private var observer: AnyCancellable?

    init(service: any ContentIndexActivityControlling, feed: BackgroundActivityFeed? = nil) {
        self.service = service
        self.feed = feed ?? BackgroundActivityFeed()
        // objectWillChange fires before the change lands; read it on the next main queue turn.
        observer = service.activityChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> { feed.activitiesPublisher }
    var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> { feed.completionsPublisher }

    func perform(_ action: BackgroundActivity.Action, on activityID: String) {
        switch (action, activityID) {
        case (.cancel, Self.modelID): service.cancelDownload()
        case (.pause, Self.indexID): service.pause(true)
        case (.resume, Self.indexID): service.pause(false)
        case (.retry, Self.modelID): service.downloadModel()
        case (.retry, Self.indexID): service.start(force: true)
        case (.dismiss, _): feed.dismiss(activityID)
        default: break
        }
    }

    func refresh() {
        let next = service.activityInput
        for (id, kind, title) in Self.completions(from: last, to: next) {
            feed.complete(id, kind: kind, title: title, notifies: kind == .download)
        }
        last = next
        feed.publish(Self.activities(for: next))
    }

    /// The work that finished between two readings.
    static func completions(from previous: ContentIndexActivityInput, to next: ContentIndexActivityInput)
        -> [(String, BackgroundActivity.Kind, String)] {
        var finished: [(String, BackgroundActivity.Kind, String)] = []
        if case .downloading = previous.phase, next.modelReady,
           ![.failed, .modelRequired, .off].contains(next.phase) {
            if case .downloading = next.phase {} else {
                finished.append((modelID, .download, L("activity.contentModel.title")))
            }
        }
        if previous.mediaDownload != nil, next.mediaDownload == nil, !next.mediaFailed, next.phase != .failed,
           next.phase != .off {
            finished.append((mediaModelID, .download, L("activity.mediaModel.title")))
        }
        let wasIndexing = previous.phase == .indexing || (previous.phase == .paused && previous.indexProgress != nil)
        if wasIndexing, next.phase == .ready {
            finished.append((indexID, .index, L("activity.contentIndex.title")))
        }
        return finished
    }

    static func activities(for input: ContentIndexActivityInput) -> [BackgroundActivity] {
        switch input.phase {
        case let .downloading(fraction):
            return [BackgroundActivity(
                id: modelID, kind: .download, title: L("activity.contentModel.title"),
                detail: BackgroundActivityFormat.bytes(fraction: fraction, of: SemanticModel.bytes),
                progress: fraction, state: .running, actions: [.cancel], route: .contentSearchSettings
            )]
        case .indexing:
            var result: [BackgroundActivity] = []
            if let media = input.mediaDownload {
                result.append(BackgroundActivity(
                    id: mediaModelID, kind: .download, title: L("activity.mediaModel.title"),
                    detail: BackgroundActivityFormat.bytes(fraction: media, of: SemanticMediaModel.bytes),
                    progress: media, state: .running, route: .contentSearchSettings
                ))
            }
            result.append(indexActivity(input.indexProgress, paused: false))
            return result
        case .paused:
            // Paused after indexing finished has nothing left to show.
            guard input.indexProgress != nil else { return [] }
            return [indexActivity(input.indexProgress, paused: true)]
        case .failed:
            let id = input.modelReady ? indexID : modelID
            let detail = if input.modelReady {
                L(input.mediaFailed ? "semantic.media.failed" : "semantic.failed.index")
            } else {
                L("semantic.failed.download")
            }
            return [BackgroundActivity(
                id: id, kind: input.modelReady ? .index : .download,
                title: L(input.modelReady ? "activity.contentIndex.title" : "activity.contentModel.title"),
                detail: detail, progress: nil, state: .failed, actions: [.retry, .dismiss],
                route: .contentSearchSettings
            )]
        case .off, .preparing, .modelRequired, .ready:
            return []
        }
    }

    private static func indexActivity(_ summary: SemanticFileIndexer.Summary?, paused: Bool) -> BackgroundActivity {
        let progress: Double? = summary.flatMap { summary in
            summary.total.flatMap { $0 > 0 ? min(1, Double(summary.processed) / Double($0)) : nil }
        }
        let counts: String = if let summary, let total = summary.total {
            L("activity.contentIndex.progress", BackgroundActivityFormat.count(summary.processed),
              BackgroundActivityFormat.count(total))
        } else {
            L("activity.contentIndex.scanning", BackgroundActivityFormat.count(summary?.scanned ?? 0))
        }
        let waiting = !paused && summary?.waitingForIdle == true
        let state: BackgroundActivity.State = paused ? .paused : (waiting ? .waiting : .running)
        let detail = switch state {
        case .paused: L("activity.paused", counts)
        case .waiting: L("activity.contentIndex.waitingIdle", counts)
        default: counts
        }
        return BackgroundActivity(
            id: indexID, kind: .index, title: L("activity.contentIndex.title"), detail: detail,
            progress: progress, state: state, actions: paused ? [.resume] : (waiting ? [] : [.pause]),
            route: .contentSearchSettings
        )
    }
}
