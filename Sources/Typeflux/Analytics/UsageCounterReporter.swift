import Foundation

/// Cumulative counters, persisted individually. No per-click event queue or network request.
/// Replaying an older snapshot cannot decrease or double-count a server-side counter.
final class UsageCounterReporter: @unchecked Sendable {
    private let defaults: UserDefaults
    private let transport: any AppAnalyticsTransporting
    private let clientInfoProvider: TypefluxCloudClientInfoProvider
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let prefix: String
    private let interval: Duration
    private var epoch: String
    private var values: [String: Int] = [:]
    private var acknowledged: [String: Int] = [:]
    private var cachedDayBucket: Int?
    private var cachedDay = ""
    private var enabled = true
    private var generation = 0
    private var sending = false
    private var timer: Task<Void, Never>?

    init(defaults: UserDefaults, transport: any AppAnalyticsTransporting,
         clientInfoProvider: TypefluxCloudClientInfoProvider, prefix: String = "analytics.counters.v1",
         interval: Duration = .seconds(60), now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults; self.transport = transport; self.clientInfoProvider = clientInfoProvider
        self.prefix = prefix; self.interval = interval; self.now = now
        epoch = defaults.string(forKey: prefix + ".epoch") ?? UUID().uuidString.lowercased()
        defaults.set(epoch, forKey: prefix + ".epoch")
        let cutoff = Self.day(now().addingTimeInterval(-30 * 86400))
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix + ".value.") {
            let metric = String(key.dropFirst((prefix + ".value.").count))
            if String(metric.prefix(10)) >= cutoff, String(metric.prefix(10)) <= Self.day(now()),
               let id = Int(metric.split(separator: "/").last ?? ""), UsageMetricCatalog.validIDs.contains(id),
               let value = value as? Int, value > 0, value <= 1_000_000_000 {
                values[metric] = value
            } else { defaults.removeObject(forKey: key) }
        }
    }

    deinit { timer?.cancel() }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func setEnabled(_ value: Bool) {
        lock.withLock {
            enabled = value
            if !value {
                generation += 1
                timer?.cancel(); timer = nil
                for key in values.keys { defaults.removeObject(forKey: prefix + ".value." + key) }
                values.removeAll(); acknowledged.removeAll()
                epoch = UUID().uuidString.lowercased()
                defaults.set(epoch, forKey: prefix + ".epoch")
            }
        }
        if value { schedule() }
    }

    func increment(_ metric: Int, amount: Int = 1) {
        guard UsageMetricCatalog.validIDs.contains(metric), amount > 0, amount <= 1_000_000_000 else { return }
        lock.withLock {
            guard enabled else { return }
            let date = now()
            let bucket = Int(floor((date.timeIntervalSince1970 + 28800) / 86400))
            if cachedDayBucket != bucket { cachedDayBucket = bucket; cachedDay = Self.day(date) }
            let key = cachedDay + "/" + String(metric)
            let value = min(1_000_000_000, (values[key] ?? 0) + amount)
            values[key] = value
            defaults.set(value, forKey: prefix + ".value." + key)
        }
        schedule()
    }

    private func schedule() {
        lock.withLock {
            guard enabled, timer == nil, values.contains(where: { acknowledged[$0.key] != $0.value }) else { return }
            let interval = interval
            let token = generation
            timer = Task { [weak self] in
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await flush()
                lock.withLock { if self.generation == token { self.timer = nil } }
                schedule()
            }
        }
    }

    /// Bounded snapshots use the existing authenticated transport and fastest-node failover.
    func flush() async {
        let snapshot = lock.withLock { () -> (String, Int, [String: Int])? in
            guard enabled, !sending else { return nil }
            let cutoff = Self.day(now().addingTimeInterval(-30 * 86400))
            for key in Array(values.keys) where String(key.prefix(10)) < cutoff {
                values.removeValue(forKey: key); acknowledged.removeValue(forKey: key)
                defaults.removeObject(forKey: prefix + ".value." + key)
            }
            let dirty = values.filter { acknowledged[$0.key] != $0.value }
            guard !dirty.isEmpty else { return nil }
            sending = true
            return (epoch, generation, dirty)
        }
        guard let (epoch, token, dirty) = snapshot else { return }
        defer { lock.withLock { sending = false } }
        let days = Dictionary(grouping: dirty.keys, by: { String($0.prefix(10)) })
        var batches: [(keys: [String], event: AppAnalyticsEvent)] = []
        for day in days.keys.sorted() {
            let keys = days[day]!.sorted()
            for offset in stride(from: 0, to: keys.count, by: 128) {
                guard lock.withLock({ enabled && generation == token }) else { return }
                let chunk = Array(keys[offset..<min(offset + 128, keys.count)])
                let pairs = chunk.compactMap { key -> [Int]? in
                    guard let id = Int(key.split(separator: "/").last ?? ""), let value = dirty[key] else { return nil }
                    return [id, value]
                }
                guard let data = try? JSONEncoder().encode(pairs), let counts = String(data: data, encoding: .utf8) else { return }
                let info = clientInfoProvider.info()
                let event = AppAnalyticsEvent(eventID: UUID().uuidString.lowercased(), eventName: "usage_counters",
                    source: "app", occurredAt: now(), clientID: info.clientID, architecture: info.architecture,
                    properties: ["schema": "1", "epoch": epoch, "day": day, "counts": counts])
                batches.append((chunk, event))
            }
        }
        for offset in stride(from: 0, to: batches.count, by: 20) {
            guard lock.withLock({ enabled && generation == token }) else { return }
            let batch = batches[offset..<min(offset + 20, batches.count)]
            do { try await transport.send(events: batch.map(\.event)) } catch { return }
            lock.withLock {
                guard enabled, generation == token else { return }
                for part in batch {
                    for key in part.keys { acknowledged[key] = dirty[key] }
                }
            }
        }
    }
}
