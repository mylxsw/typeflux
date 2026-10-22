import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureModuleHealthTests {
    @Test func settingsShowsTheFailedOwnerAndRecoversThroughTheHost() async throws {
        let failed = ModuleHealth(state: .degraded, generation: UUID(), pendingStarts: 0,
            activeOperations: 0, hasLifecycleWork: false, failure: .quarantined)
        let healthy = ModuleHealth(state: .ready, generation: UUID(), pendingStarts: 0,
            activeOperations: 1, hasLifecycleWork: false, failure: nil)
        var recovery: FeatureModuleRecovery?
        let bridge = FeatureModuleHealth(route: { command in
            #expect(command.destination == .host)
            if command.action == "moduleHealth" {
                return try JSONEncoder().encode([FeatureRole.notes: [ModuleID.notebook: failed], .launcher: [.notebook: healthy]])
            }
            #expect(command.action == "recoverModules")
            recovery = try JSONDecoder().decode(FeatureModuleRecovery.self, from: command.payload)
            return try JSONEncoder().encode(ModuleRecoveryResponse.started)
        })
        let model = ModuleHealthSettingsModel(registry: nil, remote: bridge)
        model.startObserving()
        defer { model.stopObserving() }
        for _ in 0..<100 where model.health[.notebook]?.failure != .quarantined { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.canOfferRetry(.notebook))
        #expect(model.unavailableCount == 1)
        model.recover(.notebook)
        for _ in 0..<100 where recovery == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(recovery?.id == .notebook && recovery?.reset == true)
    }

    @Test func disconnectedHealthIsUnknownAndRecoveryIsNotReportedAsSuccessful() async throws {
        let bridge = FeatureModuleHealth(route: { _ in throw FeatureRPC.Failure.unavailable })
        #expect(await bridge.recover(.notebook, reset: false) == .unavailable)
        let model = ModuleHealthSettingsModel(registry: nil, remote: bridge)
        model.startObserving()
        defer { model.stopObserving() }
        for _ in 0..<100 where model.observationFailed.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.summaryKey == "settings.services.summaryUnknown")
        #expect(!model.canOfferRetry(.notebook))
    }
}
