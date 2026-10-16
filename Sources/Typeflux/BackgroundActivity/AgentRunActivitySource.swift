import Combine
import Foundation

/// The agent runs in progress, as the conversation model sees them.
struct AgentActivityInput: Equatable {
    struct Run: Equatable {
        var id: String
        var title: String?
        /// The step waiting for the user's approval.
        var approval: AskToolCall?
        /// The latest step of the run.
        var step: AskToolCall?
        /// The run's plan, known for the conversation on screen.
        var plan: [AskPlanItem]?
    }

    var runs: [Run] = []
}

@MainActor
protocol AgentActivityControlling: AnyObject {
    var agentActivityInput: AgentActivityInput { get }
    var agentActivityChanges: AnyPublisher<Void, Never> { get }
    func stopAgentRun(_ id: String)
}

extension AskConversationModel: AgentActivityControlling {
    var agentActivityInput: AgentActivityInput {
        AgentActivityInput(runs: busyIds.sorted().map { id in
            let loaded = selected?.id == id ? selected : nil
            let steps = inferenceProgress[id]?.toolCalls ?? loaded?.run?.previewTools ?? []
            return AgentActivityInput.Run(
                id: id,
                title: conversations.first { $0.id == id }?.title ?? loaded?.title,
                approval: pendingApprovals[id],
                step: steps.last { $0.function.name != "update_plan" },
                plan: loaded?.run?.plan
            )
        })
    }

    var agentActivityChanges: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in }.eraseToAnyPublisher()
    }

    func stopAgentRun(_ id: String) {
        stop(id: id)
    }
}

/// Agent runs: what each is doing, and the ones waiting for approval.
@MainActor
final class AgentRunActivitySource: BackgroundActivitySource {
    static let idPrefix = "agent."
    /// The conversation model changes with every streamed token; read it at most this often.
    static let refreshInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(250)

    private let feed: BackgroundActivityFeed
    private let model: any AgentActivityControlling
    private var last = AgentActivityInput()
    private var stopped = Set<String>()
    private var observer: AnyCancellable?

    init(model: any AgentActivityControlling, feed: BackgroundActivityFeed? = nil,
         refreshInterval: DispatchQueue.SchedulerTimeType.Stride? = nil) {
        self.model = model
        self.feed = feed ?? BackgroundActivityFeed()
        // objectWillChange fires before the change lands; read it on a later main queue turn.
        observer = model.agentActivityChanges
            .receive(on: DispatchQueue.main)
            .throttle(for: refreshInterval ?? Self.refreshInterval, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> { feed.activitiesPublisher }
    var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> { feed.completionsPublisher }

    static func activityID(_ conversationID: String) -> String { idPrefix + conversationID }

    func perform(_ action: BackgroundActivity.Action, on activityID: String) {
        guard action == .stop, activityID.hasPrefix(Self.idPrefix) else { return }
        let id = String(activityID.dropFirst(Self.idPrefix.count))
        stopped.insert(id)
        model.stopAgentRun(id)
    }

    func refresh() {
        let next = model.agentActivityInput
        let running = Set(next.runs.map(\.id))
        for run in last.runs where !running.contains(run.id) && !stopped.contains(run.id) {
            feed.complete(Self.activityID(run.id), kind: .agent, title: Self.title(run))
        }
        stopped.formIntersection(running)
        last = next
        feed.publish(Self.activities(for: next))
    }

    static func activities(for input: AgentActivityInput) -> [BackgroundActivity] {
        input.runs.map { run in
            var activity = BackgroundActivity(
                id: activityID(run.id), kind: .agent, title: title(run), detail: "", progress: nil,
                state: .running, actions: [.open, .stop], route: .conversation(run.id)
            )
            if let approval = run.approval {
                activity.state = .attention
                activity.detail = L("activity.agent.approval", AskTheme.toolTitle(approval))
                return activity
            }
            let step = run.step.map { AskTheme.toolTitle($0) } ?? L("ask.activity.working")
            if let plan = run.plan, !plan.isEmpty {
                let done = plan.filter { $0.status == "completed" }.count
                activity.progress = Double(done) / Double(plan.count)
                activity.detail = L("activity.agent.planStep", min(done + 1, plan.count), plan.count, step)
            } else {
                activity.detail = step
            }
            return activity
        }
    }

    static func title(_ run: AgentActivityInput.Run) -> String {
        let title = run.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? L("activity.agent.untitled") : title
    }
}
