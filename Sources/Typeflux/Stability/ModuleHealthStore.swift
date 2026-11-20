import Foundation

enum ModuleID: String, Codable, CaseIterable, Sendable {
    case conversations, wordBook, notebook, mediaExtraction, mediaPreviews, clipboardThumbnails, frameRegistration, textRecognition, clipboardOCR, clipboardMetadata, recordingTimeline, recordingExport, nativeSystem, whisperInference, mediaPlayback, fileIndex, semanticValidation, semanticIndexReading, semanticPriorityReading, semanticQueryInference, semanticIndexInference, semanticMediaInference
}

/// Each record belongs to one service. A reusable reservation survives an unrelated
/// process exit without consuming another attempt on the next launch.
final class ModuleHealthStore: @unchecked Sendable {
    struct Record: Codable, Equatable {
        var version = 2
        var attempts = 0
        var quarantined = false
        var automaticRecoveryUsed: Bool? = nil
        var reusable: Bool? = nil

        var isValid: Bool {
            (version == 1 || version == 2) && (0...4).contains(attempts)
                && (attempts < 4 || quarantined || (version == 2 && reusable == true))
                && (reusable != true || (version == 2 && attempts > 0 && !quarantined))
        }

        // v1 counted whole-process exits, so its counters cannot identify a faulty service.
        var migrated: Record { version == 1 ? Record() : self }
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
        let root = TypefluxDataDirectories.data.appendingPathComponent("ModuleHealth", isDirectory: true)
        if FeatureProcess.enabled { try? FeatureHealthMigration.migrate(root: root, owner: FeatureProcess.role) }
        guard FeatureProcess.enabled, FeatureProcess.role != .host else { return root }
        return root.appendingPathComponent("features/" + FeatureProcess.role.rawValue, isDirectory: true)
    }

    /// Called only inside the supervisor's bounded detached factory task.
    /// Persist before entering potentially crashing native initialization.
    func reserve(automaticRecovery: Bool = false, protectingInitialization: Bool = true) throws {
        try lock.withLock {
            loadIfNeeded()
            guard writable, var next = record else { throw ModuleFailure.healthPersistence }
            if healthLock.withLock({ stable }) { next = Record() }
            if automaticRecovery, next.quarantined, next.automaticRecoveryUsed != true {
                next = Record(automaticRecoveryUsed: true)
            }
            if next.reusable == true { next.attempts -= 1 }
            guard !next.quarantined, next.attempts < 4 else { throw ModuleFailure.quarantined }
            next.attempts += 1
            next.reusable = protectingInitialization ? nil : true
            next.quarantined = protectingInitialization && next.attempts == 4
            try save(next)
            healthLock.withLock { healthySince = nil; stable = false }
        }
    }

    /// Supervisor transitions only. These writes never run on the worker admission path.
    func markReady() {
        lock.withLock {
            guard writable, var next = record, next.reusable != true, next.attempts > 0 else { return }
            next.reusable = true
            next.quarantined = false
            try? save(next)
        }
    }

    func recordFailure() {
        failed()
        lock.withLock {
            guard writable, var next = record, next.reusable == true else { return }
            next.reusable = nil
            next.quarantined = next.attempts == 4
            try? save(next)
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
            guard value.isValid else { throw ModuleFailure.healthPersistence }
            record = value.migrated
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
