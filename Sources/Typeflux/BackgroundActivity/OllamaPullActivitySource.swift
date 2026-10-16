import Combine
import Foundation

/// Local language model downloads through Ollama.
///
/// Pull events arrive on any thread. They change a locked record in the order they
/// happen, and the main actor then publishes the record, so a late progress event
/// can never bring back a pull that already ended.
final class OllamaPullActivitySource: BackgroundActivitySource, OllamaPullProgressReporting, @unchecked Sendable {
    struct Pull {
        var completed: Int64 = 0
        var total: Int64 = 0
        var failure: String?
        var cancel: (@Sendable () -> Void)?
    }

    /// The pulls as reported from any thread.
    final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var pulls: [String: Pull] = [:]
        /// Models whose pulls finished and have not been published yet.
        private var finished: [String] = []
        private var refreshScheduled = false

        func update(_ body: (inout [String: Pull], inout [String]) -> Void) {
            lock.withLock { body(&pulls, &finished) }
        }

        /// True for the first caller since the last `take`.
        func claimRefresh() -> Bool {
            lock.withLock {
                defer { refreshScheduled = true }
                return !refreshScheduled
            }
        }

        func take() -> (pulls: [String: Pull], finished: [String]) {
            lock.withLock {
                refreshScheduled = false
                defer { finished.removeAll() }
                return (pulls, finished)
            }
        }
    }

    private let record = Record()
    private let feed: BackgroundActivityFeed

    @MainActor init(feed: BackgroundActivityFeed? = nil) {
        self.feed = feed ?? BackgroundActivityFeed()
    }

    static func activityID(_ model: String) -> String { "ollama.\(model)" }

    static func title(_ model: String) -> String { L("activity.llmModel.title", model) }

    @MainActor var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> { feed.activitiesPublisher }
    @MainActor var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> {
        feed.completionsPublisher
    }

    @MainActor func perform(_ action: BackgroundActivity.Action, on activityID: String) {
        var cancel: (@Sendable () -> Void)?
        record.update { pulls, _ in
            guard let model = pulls.keys.first(where: { Self.activityID($0) == activityID }) else { return }
            if action == .cancel {
                cancel = pulls[model]?.cancel
            } else if action == .dismiss, pulls[model]?.failure != nil {
                pulls[model] = nil
            }
        }
        cancel?()
        refresh()
    }

    nonisolated func pullStarted(model: String, cancel: @escaping @Sendable () -> Void) {
        record.update { pulls, _ in pulls[model] = Pull(cancel: cancel) }
        scheduleRefresh()
    }

    nonisolated func pullProgressed(model: String, completed: Int64, total: Int64) {
        record.update { pulls, _ in
            guard pulls[model]?.cancel != nil else { return }
            pulls[model]?.completed = completed
            pulls[model]?.total = total
        }
        scheduleRefresh()
    }

    nonisolated func pullFinished(model: String, error: Error?) {
        let message = error.flatMap { $0 is CancellationError ? nil : $0.localizedDescription }
        record.update { pulls, finished in
            if let message {
                pulls[model] = Pull(completed: pulls[model]?.completed ?? 0, total: pulls[model]?.total ?? 0,
                                    failure: message)
            } else {
                pulls[model] = nil
                if error == nil { finished.append(model) }
            }
        }
        scheduleRefresh()
    }

    private nonisolated func scheduleRefresh() {
        guard record.claimRefresh() else { return }
        // `refresh` reads the record itself, so the order these hops run in does not matter.
        Task { @MainActor [weak self] in self?.refresh() }
    }

    @MainActor func refresh() {
        let (pulls, finished) = record.take()
        for model in finished {
            feed.complete(Self.activityID(model), kind: .download, title: Self.title(model), notifies: true)
        }
        feed.publish(pulls.keys.sorted().compactMap { model in
            pulls[model].map { Self.activity(model: model, pull: $0) }
        })
    }

    private static func activity(model: String, pull: Pull) -> BackgroundActivity {
        if let failure = pull.failure {
            return BackgroundActivity(
                id: activityID(model), kind: .download, title: title(model),
                detail: L("activity.download.failed", failure), progress: nil, state: .failed,
                actions: [.dismiss]
            )
        }
        let progress = pull.total > 0 ? min(1, Double(pull.completed) / Double(pull.total)) : nil
        return BackgroundActivity(
            id: activityID(model), kind: .download, title: title(model),
            detail: pull.total > 0 ? BackgroundActivityFormat.bytes(pull.completed, of: pull.total)
                : L("activity.preparing"),
            progress: progress, state: .running, actions: [.cancel]
        )
    }
}
