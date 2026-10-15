import Foundation
import os

/// Query contents and paths are deliberately excluded from performance events.
struct SemanticSearchTrace: Sendable {
    @TaskLocal static var current: SemanticSearchTrace?
    private static let log = OSLog(subsystem: "com.typeflux", category: "ContentSearch")
    private let id = OSSignpostID(log: log)
    private let start = ProcessInfo.processInfo.systemUptime
    struct Event: Codable, Sendable {
        var stage: String
        var milliseconds: Double
        var duration: Bool
    }
    private let sink: (@Sendable (Event) -> Void)?

    init(sink: (@Sendable (Event) -> Void)? = nil) { self.sink = sink }

    func measure(_ stage: StaticString, milliseconds: Double) {
        sink?(.init(stage: stage.description, milliseconds: milliseconds, duration: true))
        os_signpost(.event, log: Self.log, name: stage, signpostID: id, "duration_ms=%{public}.3f", milliseconds)
    }

    func mark(_ stage: StaticString) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        sink?(.init(stage: stage.description, milliseconds: elapsed, duration: false))
        os_signpost(.event, log: Self.log, name: stage, signpostID: id,
                    "elapsed_ms=%{public}.3f", elapsed)
    }
}
