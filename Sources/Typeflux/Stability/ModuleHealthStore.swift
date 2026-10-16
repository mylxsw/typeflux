import Foundation

enum ModuleID: String, Codable, CaseIterable, Sendable {
    case conversations, wordBook, notebook, mediaExtraction, mediaPreviews, clipboardThumbnails, frameRegistration, textRecognition, clipboardOCR, clipboardMetadata, recordingTimeline, recordingExport, nativeSystem, whisperInference, mediaPlayback, fileIndex
}

/// One small file per fault domain. No user content, paths, errors or clock
/// values are persisted. A reservation survives process death until a clean
/// stop or ten minutes of observed healthy service, never merely a successful open.
final class ModuleHealthStore: @unchecked Sendable {
    struct Record: Codable, Equatable {
        var version = 1
        var attempts = 0
        var quarantined = false
    }

    private let lock = NSLock()
    private let healthLock = NSLock()
    private let url: URL
    private var record: Record?
    private var healthySince: TimeInterval?
    private var stable = false
    private var writable = true
    private let uptime: @Sendable () -> TimeInterval

    init(url: URL, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.url = url
        self.uptime = uptime
    }

    static func directory() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Typeflux/ModuleHealth", isDirectory: true)
    }

    /// Called only inside the supervisor's bounded detached factory task.
    /// Persist before entering potentially crashing native initialization.
    func reserve() throws {
        try lock.withLock {
            loadIfNeeded()
            guard writable, var next = record else { throw ModuleFailure.healthPersistence }
            if healthLock.withLock({ stable }) { next = Record() }
            guard !next.quarantined, next.attempts < 4 else { throw ModuleFailure.quarantined }
            next.attempts += 1
            next.quarantined = next.attempts == 4
            try save(next)
            healthLock.withLock { healthySince = nil; stable = false }
        }
    }

    /// Memory-only; health publication and the supervisor never wait for disk.
    func succeeded() {
        healthLock.withLock {
            let now = uptime()
            if let healthySince { stable = now - healthySince >= 600 }
            else { healthySince = now }
        }
    }

    func failed() {
        healthLock.withLock { healthySince = nil }
    }

    /// Run with bounded cleanup. Failed generations cannot clear their budget.
    func cleanStop() {
        lock.withLock {
            guard healthLock.withLock({ healthySince != nil }), writable else { return }
            do { try save(Record()) } catch { /* Remain fail-closed on next start. */ }
            healthLock.withLock { healthySince = nil; stable = false }
        }
    }

    /// Explicit user recovery only; never called by automatic recovery or enable.
    /// A damaged file is retained until this deliberate replacement succeeds.
    func reset() throws {
        try lock.withLock {
            writable = true
            try save(Record())
            healthLock.withLock { healthySince = nil; stable = false }
        }
    }

    private func loadIfNeeded() {
        guard record == nil else { return }
        do {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                record = Record(); return
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 4096 else {
                throw ModuleFailure.healthPersistence
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 4097) ?? Data()
            guard data.count <= 4096 else { throw ModuleFailure.healthPersistence }
            let value = try JSONDecoder().decode(Record.self, from: data)
            guard value.version == 1, (0...4).contains(value.attempts),
                  value.attempts != 4 || value.quarantined else { throw ModuleFailure.healthPersistence }
            record = value
        } catch {
            record = Record(attempts: 4, quarantined: true)
            writable = false
        }
    }

    private func save(_ value: Record) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            record = value
        } catch {
            writable = false
            throw ModuleFailure.healthPersistence
        }
    }
}
