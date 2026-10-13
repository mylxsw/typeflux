import Foundation
@testable import Typeflux

/// Captures the first page before clear, then releases it to exercise stale-result rejection.
final class HistorySettingsGateStore: HistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [HistoryRecord]
    private var entered = false
    private var returned = false
    let release = DispatchSemaphore(value: 0)

    init() {
        records = [HistoryRecord(date: Date(), transcriptText: "Old query result")]
    }

    var didEnter: Bool {
        lock.withLock { entered }
    }

    var didReturn: Bool {
        lock.withLock { returned }
    }

    func save(record: HistoryRecord) {
        lock.withLock { records.append(record) }
    }

    func list() -> [HistoryRecord] {
        lock.withLock { records }
    }

    func list(limit: Int, offset: Int, searchQuery _: String?) -> [HistoryRecord] {
        let snapshot = lock.withLock { () -> [HistoryRecord] in
            entered = true
            return Array(records.dropFirst(offset).prefix(limit))
        }
        release.wait()
        lock.withLock { returned = true }
        return snapshot
    }

    func record(id: UUID) -> HistoryRecord? {
        list().first { $0.id == id }
    }

    func delete(id: UUID) {
        lock.withLock { records.removeAll { $0.id == id } }
    }

    func purge(olderThanDays _: Int) {}
    func clear() {
        lock.withLock { records = [] }
    }

    func exportMarkdown() throws -> URL {
        throw CocoaError(.fileNoSuchFile)
    }
}
