import Foundation
import Testing
import TypefluxChatWindowProtocol
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ChatWindowFreezeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_CHAT_WINDOW_FREEZE_TEST"] == "1"))
    func frozenChildMainThreadDoesNotBlockParentMainActorForThirtySeconds() async throws {
        let client = try chatWindowTestClient(stall: 30)
        defer { client.stop() }
        try await client.connect()
        try await client.present(.init(sequence: 1, title: "Isolation fixture", messages: [.init(role: .assistant, text: "Synthetic content")]))
        let started = ContinuousClock.now
        var replied = false, ticks = 0
        var worst = Duration.zero
        let health = Task { try await client.ping(timeout: 40); replied = true }
        while !replied, started.duration(to: .now) < .seconds(40) {
            let tick = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(20))
            worst = max(worst, tick.duration(to: .now))
            ticks += 1
        }
        try await health.value
        let elapsed = started.duration(to: .now)
        #expect(elapsed >= .seconds(29))
        #expect(ticks >= 1000)
        #expect(worst < .milliseconds(500))
        print("CHAT_WINDOW_FREEZE elapsed=\(elapsed) parent_ticks=\(ticks) worst_main_actor_interval=\(worst)")
        await client.shutdown()
    }
}
