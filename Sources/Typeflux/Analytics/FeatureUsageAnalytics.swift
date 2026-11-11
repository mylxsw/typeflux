import Foundation

/// Low-cardinality product events. Content, paths, custom names and error messages never belong here.
struct FeatureUsageAnalytics: Sendable {
    enum Feature: String, Sendable { case launcher, ring, screenshot, translation, clipboard, keyword, workflow }
    enum Outcome: String, Sendable { case completed, failed, cancelled }
    let reporter: any AnalyticsEventReporting

    init(reporter: any AnalyticsEventReporting = NoopAnalyticsEventReporter.shared) { self.reporter = reporter }

    func event(_ feature: Feature, _ action: String, properties: [String: String] = [:]) {
        reporter.report(eventName: feature.rawValue + "_" + action,
                        properties: properties.merging(["feature": feature.rawValue, "analytics_schema": "1"]) { _, new in new })
    }

    func count(_ key: String, amount: Int = 1) {
        guard let id = UsageMetricCatalog.ids[key] else { return }
        reporter.report(eventName: "usage_counter", properties: ["metric": String(id), "amount": String(amount)])
    }

    func start(_ feature: Feature, properties: [String: String] = [:]) -> Run {
        Run(analytics: self, feature: feature, properties: properties)
    }

    /// A handoff retains the same run. Every cancellation/completion race has exactly one terminal event.
    final class Run: @unchecked Sendable {
        let id = UUID().uuidString.lowercased()
        private let analytics: FeatureUsageAnalytics
        private let feature: Feature
        private let properties: [String: String]
        private let started = ContinuousClock.now
        private let lock = NSLock()
        private var finished = false

        init(analytics: FeatureUsageAnalytics, feature: Feature, properties: [String: String]) {
            self.analytics = analytics; self.feature = feature; self.properties = properties
            analytics.event(feature, "started", properties: properties.merging(["flow_id": id]) { _, new in new })
        }

        func finish(_ outcome: Outcome, properties extra: [String: String] = [:]) {
            let first = lock.withLock { if finished { return false }; finished = true; return true }
            guard first else { return }
            let elapsed = started.duration(to: .now).components
            let milliseconds = max(0, elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            var values = properties.merging(extra) { _, new in new }
            values["flow_id"] = id
            values["duration_ms"] = String(milliseconds)
            analytics.event(feature, outcome.rawValue, properties: values)
        }
    }
}

/// Child processes forward to the host; only the host owns the persisted queue and network sender.
final class FeatureProcessAnalyticsReporter: AnalyticsEventReporting, @unchecked Sendable {
    struct Message: Codable { let eventName: String; let properties: [String: String] }
    private let send: @Sendable (FeatureCommand) -> Void
    init(send: @escaping @Sendable (FeatureCommand) -> Void = { FeatureProcess.send($0) }) { self.send = send }
    func report(eventName: String, properties: [String: String]) {
        guard let payload = try? JSONEncoder().encode(Message(eventName: eventName, properties: properties)) else { return }
        send(.init(destination: .host, action: "analyticsEvent", payload: payload))
    }
    func reportFirstOpenIfNeeded() {}
}
