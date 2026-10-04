import Foundation
import Testing
@testable import Typeflux

@Suite("Ask user reasoning effort", .serialized)
@MainActor
struct AskReasoningEffortTests {
    @Test func catalogCapabilityAndRequestEncodingRemainBackwardCompatible() throws {
        let model = try AskCoding.decoder().decode(AskCloudModel.self, from: Data(#"{"id":"deep","name":"Deep","capabilities":{"reasoning":true}}"#.utf8))
        let restored = try JSONDecoder().decode(RegisteredModel.self, from: JSONEncoder().encode(model.registered))
        #expect(restored.reasoning == true)
        for choice in AskReasoningEffort.allCases {
            let request = AskSendRequest(id: "m", deviceId: "d", text: "Question", tools: [],
                                         reasoningEffort: choice.requestValue(for: restored))
            let body = try #require(JSONSerialization.jsonObject(with: AskCoding.encoder().encode(request)) as? [String: Any])
            // A catalog without levels offers the default three; heavier choices use the closest.
            let expected: String? = switch choice {
            case .providerDefault: nil
            case .xhigh, .max: "high"
            default: choice.rawValue
            }
            #expect(body["reasoning_effort"] as? String == expected)
        }
        let old = try AskCoding.decoder().decode(AskSendRequest.self, from: Data(#"{"id":"m","device_id":"d","text":"Question","tools":[]}"#.utf8))
        #expect(old.reasoningEffort == nil)
        #expect(AskReasoningEffort.high.requestValue(for: nil) == nil)
        #expect(AskReasoningEffort.high.requestValue(for: .init(id: "plain", name: "Plain", reference: "cloud:plain", reasoning: false)) == nil)
        // The user's own models get the choice unless known not to reason.
        #expect(AskReasoningEffort.high.requestValue(for: .init(id: "custom", name: "Custom", reasoning: true)) == "high")
        #expect(AskReasoningEffort.high.requestValue(for: .init(id: "unknown", name: "Unknown")) == "high")
        #expect(AskReasoningEffort.high.requestValue(for: .init(id: "plain", name: "Plain", reasoning: false)) == nil)
        #expect(AskReasoningEffort.providerDefault.requestValue(for: .init(id: "custom", name: "Custom")) == nil)
    }

    @Test func chosenEffortIsSentAndUnsupportedModelsOmitIt() async throws {
        let suite = "ask-reasoning-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([.init(id: "deep", name: "Deep", reference: "cloud:deep", vision: true,
                                    scenarios: ["ask"], reasoning: true)], providerID: "typefluxCloud")
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        await fixture.api.setCloudModels([
            .init(id: "default", name: "Default", vision: true),
            .init(id: "deep", name: "Deep", vision: true, capabilities: ["reasoning": true])
        ])
        await fixture.api.setFailSend(true)
        await fixture.model.prepareLauncher()
        fixture.model.reasoningEffort = .high
        fixture.model.launcherDraft.modelRef = "cloud:deep"
        fixture.model.launcherDraft.text = "Think carefully"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.isEmpty)
        fixture.model.reasoningEffort = .low
        await fixture.api.setFailSend(false)
        fixture.model.resume()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.last?.reasoningEffort == "high")
        fixture.model.draft.modelRef = "cloud:default"
        fixture.model.draft.text = "Plain model"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.count == 2)
        #expect(await fixture.api.sends.last?.reasoningEffort == nil)
    }
}
