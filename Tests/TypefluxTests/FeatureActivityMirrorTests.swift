import Combine
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureActivityMirrorTests {
    @Test func repeatedHeartbeatsDoNotPublishButRealChangesDo() throws {
        let mirror = FeatureActivityMirror()
        var updates = 0
        let subscription = mirror.agentActivityChanges.sink { updates += 1 }
        defer { subscription.cancel() }
        var status = FeatureStatus(role: .screenshot, activity: .init(), pins: 2, clickThroughPins: 1)
        mirror.receive(status)
        for _ in 0..<20 { mirror.receive(status) }
        #expect(updates == 1)
        #expect(mirror.pins == 2 && mirror.clickThroughPins == 1)

        status = FeatureStatus(role: .screenshot, activity: .init(runs: [.init(id: "run", title: "Working")]),
            pins: 3, clickThroughPins: 0)
        mirror.receive(status)
        #expect(updates == 2)
        #expect(mirror.agentActivityInput == status.activity)
        #expect(mirror.pins == 3 && mirror.clickThroughPins == 0)

        status.voiceStatus = .recording
        mirror.receive(status)
        #expect(updates == 3)
        status.modules = [.mediaPreviews: .init(state: .ready, generation: UUID(), pendingStarts: 0,
            activeOperations: 0, hasLifecycleWork: false, failure: nil)]
        mirror.receive(status)
        mirror.receive(try JSONDecoder().decode(FeatureStatus.self, from: JSONEncoder().encode(status)))
        #expect(updates == 4)
        mirror.remove(.voice)
        #expect(updates == 4)
        mirror.remove(.screenshot)
        mirror.remove(.screenshot)
        #expect(updates == 5)
        #expect(mirror.pins == 0 && mirror.clickThroughPins == 0 && mirror.agentActivityInput.runs.isEmpty)
        mirror.receive(status)
        #expect(updates == 6)
    }
}
