import Combine
import Foundation

struct FeatureStatus: Codable, Sendable {
    let role: FeatureRole
    let activity: AgentActivityInput
    let pins: Int
    let clickThroughPins: Int
    var voiceStatus: AppStatus? = nil
    var modules: [ModuleID: ModuleHealth] = [:]
}

struct FeatureQuickProgress: Codable, Sendable, Equatable {
    let owner: String
    let id: String
    let runID: String
    let complete: Bool
    let progress: AskStreamProgress?
}

@MainActor
final class FeatureActivityMirror: AgentActivityControlling {
    static let shared = FeatureActivityMirror()
    private var states: [FeatureRole: FeatureStatus] = [:]
    private let changes = PassthroughSubject<Void, Never>()
    var pins: Int { states[.screenshot]?.pins ?? 0 }
    var clickThroughPins: Int { states[.screenshot]?.clickThroughPins ?? 0 }
    var agentActivityInput: AgentActivityInput { .init(runs: states.values.flatMap(\.activity.runs)) }
    var agentActivityChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    func remove(_ role: FeatureRole) { states[role] = nil; changes.send() }
    func receive(_ status: FeatureStatus) { states[status.role] = status; changes.send() }
    func stopAgentRun(_ id: String) {
        guard let role = states.first(where: { $0.value.activity.runs.contains { $0.id == id } })?.key else { return }
        FeatureProcess.send(.init(destination: role, action: "stopConversation", payload: Data(id.utf8)))
    }
}
