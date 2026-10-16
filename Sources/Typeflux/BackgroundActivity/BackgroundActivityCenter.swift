import Combine
import Foundation

/// Gathers the background work of every source into one ordered list for the
/// menu bar icon, the menu section and the background tasks window.
@MainActor
final class BackgroundActivityCenter: ObservableObject {
    static let recentLimit = 20
    /// Work shorter than this finished while the user was likely still watching.
    static let notificationThreshold: TimeInterval = 60

    @Published private(set) var activities: [BackgroundActivity] = []
    @Published private(set) var recent: [BackgroundActivityCompletion] = []
    @Published var indicatorEnabled: Bool {
        didSet { settings.backgroundActivityIndicatorEnabled = indicatorEnabled }
    }

    @Published var notificationsEnabled: Bool {
        didSet { settings.backgroundActivityNotificationsEnabled = notificationsEnabled }
    }

    /// Opens what an activity belongs to; set by the app once its windows exist.
    var onOpen: (BackgroundActivity.Route) -> Void = { _ in }

    var indicator: BackgroundActivityIndicator {
        indicatorEnabled ? .of(activities) : .none
    }

    /// Activities using resources or waiting for the user.
    var activeCount: Int {
        activities.filter(\.isActive).count
    }

    private let settings: SettingsStore
    private let notifications: LocalNotificationSending
    private let coalesceInterval: TimeInterval
    private var sources: [ObjectIdentifier: any BackgroundActivitySource] = [:]
    private var order: [ObjectIdentifier] = []
    private var lists: [ObjectIdentifier: [BackgroundActivity]] = [:]
    private var owners: [String: ObjectIdentifier] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var mergeScheduled = false

    /// `coalesceInterval` bounds how often progress reaches the UI; zero merges at once.
    init(settings: SettingsStore, notifications: LocalNotificationSending, coalesceInterval: TimeInterval = 0.25) {
        self.settings = settings
        self.notifications = notifications
        self.coalesceInterval = coalesceInterval
        indicatorEnabled = settings.backgroundActivityIndicatorEnabled
        notificationsEnabled = settings.backgroundActivityNotificationsEnabled
    }

    func register(_ source: any BackgroundActivitySource) {
        let key = ObjectIdentifier(source)
        guard sources[key] == nil else { return }
        sources[key] = source
        order.append(key)
        lists[key] = []
        source.activitiesPublisher
            .sink { [weak self] list in
                self?.lists[key] = list
                self?.scheduleMerge()
            }
            .store(in: &cancellables)
        source.completionsPublisher
            .sink { [weak self] completion in self?.record(completion) }
            .store(in: &cancellables)
    }

    func activity(_ id: String) -> BackgroundActivity? {
        activities.first { $0.id == id }
    }

    func perform(_ action: BackgroundActivity.Action, on id: String) {
        guard let activity = activity(id) else { return }
        if action == .open {
            if let route = activity.route {
                onOpen(route)
            }
            return
        }
        guard let owner = owners[id], let source = sources[owner] else { return }
        source.perform(action, on: id)
    }

    func clearRecent() {
        recent.removeAll()
    }

    private func scheduleMerge() {
        guard coalesceInterval > 0 else { merge(); return }
        guard !mergeScheduled else { return }
        mergeScheduled = true
        let delay = UInt64(coalesceInterval * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            mergeScheduled = false
            merge()
        }
    }

    private func merge() {
        var merged: [BackgroundActivity] = []
        var owners: [String: ObjectIdentifier] = [:]
        for key in order {
            for activity in lists[key] ?? [] where owners[activity.id] == nil {
                owners[activity.id] = key
                merged.append(activity)
            }
        }
        self.owners = owners
        let sorted = BackgroundActivity.sorted(merged)
        if sorted != activities {
            activities = sorted
        }
    }

    private func record(_ completion: BackgroundActivityCompletion) {
        recent.insert(completion, at: 0)
        if recent.count > Self.recentLimit {
            recent.removeLast(recent.count - Self.recentLimit)
        }
        guard completion.notifies, notificationsEnabled,
              (completion.duration ?? 0) >= Self.notificationThreshold else { return }
        let notifications = notifications
        Task {
            await notifications.sendLocalNotification(
                title: L("activity.notification.title"),
                body: L("activity.notification.body", completion.title),
                identifier: "ai.gulu.app.typeflux.activity.\(completion.activityID)"
            )
        }
    }
}
