import Combine
import Foundation

/// Something that runs background work and reports it to `BackgroundActivityCenter`.
@MainActor
protocol BackgroundActivitySource: AnyObject {
    /// The source's current activities, sent again whenever they change.
    var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> { get }
    /// Work that finished successfully.
    var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> { get }
    func perform(_ action: BackgroundActivity.Action, on activityID: String)
}

/// The plumbing every source shares: the published list, completion events,
/// when each piece of work was first seen, and failures the user dismissed.
@MainActor
final class BackgroundActivityFeed {
    private let subject = CurrentValueSubject<[BackgroundActivity], Never>([])
    private let finished = PassthroughSubject<BackgroundActivityCompletion, Never>()
    private let now: () -> Date
    private var startedAt: [String: Date] = [:]
    /// Failures hidden by the user; they stay hidden while they read exactly the same.
    private var dismissed: [String: BackgroundActivity] = [:]
    /// The last list the source reported, before dismissed failures are removed.
    private(set) var reported: [BackgroundActivity] = []

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> {
        finished.eraseToAnyPublisher()
    }

    var current: [BackgroundActivity] {
        subject.value
    }

    func reported(_ id: String) -> BackgroundActivity? {
        reported.first { $0.id == id }
    }

    func publish(_ activities: [BackgroundActivity]) {
        let time = now()
        let ids = Set(activities.map(\.id))
        startedAt = startedAt.filter { ids.contains($0.key) }
        for activity in activities {
            if activity.state == .failed {
                startedAt[activity.id] = nil
            } else if startedAt[activity.id] == nil {
                startedAt[activity.id] = time
            }
        }
        dismissed = dismissed.filter { id, failure in activities.contains { $0.id == id && $0 == failure } }
        reported = activities
        subject.send(activities.filter { dismissed[$0.id] != $0 })
    }

    /// Reports `id` as finished. Call before publishing the list it is gone from,
    /// so its observed duration is still known.
    func complete(_ id: String, kind: BackgroundActivity.Kind, title: String, notifies: Bool = false) {
        let time = now()
        finished.send(BackgroundActivityCompletion(
            activityID: id,
            kind: kind,
            title: title,
            finishedAt: time,
            duration: startedAt[id].map { time.timeIntervalSince($0) },
            notifies: notifies
        ))
        startedAt[id] = nil
    }

    /// Hides a failure until it changes or goes away.
    func dismiss(_ id: String) {
        guard let failure = reported(id), failure.state == .failed else { return }
        dismissed[id] = failure
        subject.send(reported.filter { dismissed[$0.id] != $0 })
    }
}
