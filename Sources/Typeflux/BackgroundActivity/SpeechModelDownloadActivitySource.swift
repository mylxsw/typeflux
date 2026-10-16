import Combine
import Foundation

/// Speech recognition model downloads, as reported to `LocalModelDownloadProgressCenter`
/// by onboarding, settings, the workflow and the automatic download.
@MainActor
final class SpeechModelDownloadActivitySource: BackgroundActivitySource {
    static let activityID = "speech.download"
    /// The shared center reports idle for both a finished and a cancelled download;
    /// one that had reached this far is taken as finished.
    static let completionThreshold = 0.99

    private let feed: BackgroundActivityFeed
    private let status: () -> LocalModelDownloadProgressStatus
    private var lastStatus: LocalModelDownloadProgressStatus = .idle
    private var observer: AnyCancellable?

    init(
        status: @escaping () -> LocalModelDownloadProgressStatus = { LocalModelDownloadProgressCenter.shared.status },
        changes: AnyPublisher<Void, Never> = NotificationCenter.default
            .publisher(for: .localModelDownloadProgressDidChange).map { _ in }.eraseToAnyPublisher(),
        feed: BackgroundActivityFeed? = nil
    ) {
        self.status = status
        self.feed = feed ?? BackgroundActivityFeed()
        observer = changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> {
        feed.activitiesPublisher
    }

    var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> {
        feed.completionsPublisher
    }

    func perform(_ action: BackgroundActivity.Action, on activityID: String) {
        guard activityID == Self.activityID, action == .dismiss else { return }
        feed.dismiss(activityID)
    }

    func refresh() {
        let next = status()
        if case let .downloading(model, progress) = lastStatus, next == .idle, progress >= Self.completionThreshold {
            // Typeflux already announces a ready speech model, so no second notification.
            feed.complete(Self.activityID, kind: .download, title: Self.title(model))
        }
        lastStatus = next
        feed.publish(Self.activities(for: next))
    }

    static func activities(for status: LocalModelDownloadProgressStatus) -> [BackgroundActivity] {
        switch status {
        case .idle:
            []
        case let .downloading(model, progress):
            [BackgroundActivity(
                id: activityID, kind: .download, title: title(model),
                detail: L("activity.download.percent", BackgroundActivityFormat.percent(progress)),
                progress: progress, state: .running, route: .speechModels
            )]
        case let .failed(model, message):
            [BackgroundActivity(
                id: activityID, kind: .download, title: title(model),
                detail: L("activity.download.failed", message), progress: nil, state: .failed,
                actions: [.open, .dismiss], route: .speechModels
            )]
        }
    }

    static func title(_ model: LocalSTTModel) -> String {
        L("activity.speechModel.title", model.displayName)
    }
}
