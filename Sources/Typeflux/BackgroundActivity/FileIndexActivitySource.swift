import Combine
import Foundation

/// The file name index while it scans the search folders.
@MainActor
final class FileIndexActivitySource: BackgroundActivitySource {
    static let activityID = "files.index"

    private let feed: BackgroundActivityFeed
    private let status: () -> AskFileIndexStatus
    private var wasBuilding = false
    private var observer: AnyCancellable?

    init(
        status: @escaping () -> AskFileIndexStatus = { AskFileIndex.shared.status },
        changes: AnyPublisher<Void, Never> = NotificationCenter.default
            .publisher(for: AskFileIndex.didChange).map { _ in }.eraseToAnyPublisher(),
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

    func perform(_: BackgroundActivity.Action, on _: String) {}

    func refresh() {
        let next = status()
        if wasBuilding, next.phase == .ready {
            feed.complete(Self.activityID, kind: .index, title: L("activity.fileIndex.title"))
        }
        wasBuilding = next.isBuilding
        feed.publish(Self.activities(for: next))
    }

    static func activities(for status: AskFileIndexStatus) -> [BackgroundActivity] {
        guard case let .building(found, estimate) = status.phase else { return [] }
        let detail = if let estimate, estimate > 0 {
            L("activity.fileIndex.progress", BackgroundActivityFormat.count(found),
              BackgroundActivityFormat.count(estimate))
        } else {
            L("activity.fileIndex.found", BackgroundActivityFormat.count(found))
        }
        return [BackgroundActivity(
            id: activityID, kind: .index, title: L("activity.fileIndex.title"), detail: detail,
            progress: status.progress, state: .running, route: .contentSearchSettings
        )]
    }
}
