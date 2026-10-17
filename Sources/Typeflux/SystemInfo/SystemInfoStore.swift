import Foundation

/// Holds the latest read of the Mac's configuration. Each time `sys` opens it reads
/// again (addresses and capacity change), showing the previous read meanwhile.
@MainActor
final class SystemInfoStore: ObservableObject {
    static let shared = SystemInfoStore(reader: DarwinSystemInfoReader())

    @Published private(set) var snapshot: SystemInfoSnapshot?
    @Published private(set) var isReading = false

    private let reader: SystemInfoReading
    private let now: () -> Date
    private var reading: Task<Void, Never>?
    private var readAt: Date?

    /// A read this recent is kept: the keyword's row and the view opening right after it read once.
    static let freshness: TimeInterval = 5

    init(reader: SystemInfoReading, now: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.now = now
    }

    /// Starts a read unless one is under way or the last one is still fresh.
    func refresh() {
        guard reading == nil else { return }
        if let readAt, now().timeIntervalSince(readAt) < Self.freshness {
            return
        }
        isReading = true
        reading = Task { [weak self, reader] in
            let facts = await reader.read()
            guard let self else { return }
            let time = now()
            readAt = time
            snapshot = SystemInfoSnapshot.make(facts, now: time)
            isReading = false
            reading = nil
        }
    }

    /// Waits for the read under way, for tests.
    func settle() async {
        await reading?.value
    }
}
