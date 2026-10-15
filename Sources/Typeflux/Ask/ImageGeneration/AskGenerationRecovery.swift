import Foundation
import Darwin

/// Metadata only. Original response bodies are loaded only after an explicit save.
struct AskGenerationRecoveryRecord: Identifiable, Equatable, Sendable {
    var id: String
    var runId: String
    var callId: String
    var files: [String]
}

extension AskImageGenerationRetention {
    static func recoveryRecords(rootURL: URL, owner: String, conversation: String) throws -> [AskGenerationRecoveryRecord] {
        guard !owner.isEmpty, !conversation.isEmpty else { throw AskArtifactError.denied }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let root = try AskSecureDirectory.openRoot(rootURL, create: false)
        try root.lock()
        var records: [AskGenerationRecoveryRecord] = []
        for id in root.entries(limit: maximumRecords).sorted() {
            guard id.count == 64, id.allSatisfy(\.isHexDigit),
                  let directory = try? root.child(id, privateDirectory: true),
                  let data = try? directory.readFile("identity.json", limit: 16 * 1024),
                  let identity = try? JSONDecoder().decode(Identity.self, from: data),
                  identity.ownerId == owner, identity.conversationId == conversation else { continue }
            let files = directory.entries(limit: 16).filter { recoveryFileLimit($0) != nil }.sorted()
            // Completed records keep the replay fence, but have no raw output left.
            if files.contains("response.json") || files.contains(where: { $0.hasPrefix("download-") }) ||
                !directory.entries(limit: 16).contains("published.json") {
                guard records.count < maximumPending else { throw AskArtifactError.tooLarge }
                records.append(.init(id: id, runId: identity.runId, callId: identity.callId, files: files))
            }
        }
        return records
    }

    static func recoveryFile(rootURL: URL, record: AskGenerationRecoveryRecord, owner: String,
                             conversation: String, name: String) throws -> Data {
        guard record.id.count == 64, record.id.allSatisfy(\.isHexDigit),
              let limit = recoveryFileLimit(name) else { throw AskArtifactError.invalid }
        let root = try AskSecureDirectory.openRoot(rootURL, create: false)
        try root.lock()
        let directory = try root.child(record.id, privateDirectory: true)
        let identity = try JSONDecoder().decode(Identity.self, from: directory.readFile("identity.json", limit: 16 * 1024))
        guard identity == Identity(ownerId: owner, conversationId: conversation, runId: record.runId, callId: record.callId)
        else { throw AskArtifactError.denied }
        return try directory.readFile(name, limit: limit)
    }

    private static func recoveryFileLimit(_ name: String) -> Int? {
        if name == "response.json" { return AskImageGenerationService.maximumResponseBytes }
        if name == "request.json" { return 64 * 1024 }
        if (0..<8).contains(where: { name == "download-\($0)" }) { return AskArtifactStore.maximumFileBytes }
        return nil
    }
}

/// Admission is held until disk work actually returns, even if its UI is gone.
enum AskGenerationRecoveryIO {
    private static let lock = NSLock()
    private static var active = 0
    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard lock.withLock({ guard active < 2 else { return false }; active += 1; return true })
        else { throw AskArtifactError.unavailable }
        defer { lock.withLock { active -= 1 } }
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility, operation: work).value
        try Task.checkCancellation()
        return result
    }
}

/// Large writes happen off the UI executor. Only the final rename is committed
/// after a fresh authorization check, with no suspension between check and commit.
final class AskGenerationRecoveryExport: @unchecked Sendable {
    let temporary: URL
    private let parent: AskSecureDirectory
    private let destinationName: String
    init(data: Data, destination: URL) throws {
        destinationName = destination.lastPathComponent
        guard AskSecureDirectory.validName(destinationName) else { throw AskArtifactError.invalid }
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".typeflux-recovery-" + UUID().uuidString)
        parent = try AskSecureDirectory.openRoot(temporary.deletingLastPathComponent(), create: false, privateRoot: false)
        do { try parent.createFile(temporary.lastPathComponent, data: data) }
        catch { try? parent.remove(temporary.lastPathComponent); throw error }
    }
    func commit() throws {
        guard renameat(parent.descriptor, temporary.lastPathComponent, parent.descriptor, destinationName) == 0 else { throw AskArtifactError.unavailable }
    }
    deinit { try? parent.remove(temporary.lastPathComponent) }
}

@MainActor final class AskGenerationRecoveryModel: ObservableObject {
    @Published private(set) var records: [AskGenerationRecoveryRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var generation = UUID()
    private var closed = false

    func cancel() { closed = true; generation = UUID(); records = []; message = nil; busy = false }

    func load(root: URL, owner: String, conversation: String, authorize: () throws -> Void) async {
        guard !busy, !closed else { return }
        let current = generation
        busy = true; message = nil
        defer { if generation == current { busy = false } }
        do {
            try authorize()
            let result = try await AskGenerationRecoveryIO.perform {
                try AskImageGenerationRetention.recoveryRecords(rootURL: root, owner: owner, conversation: conversation)
            }
            try Task.checkCancellation()
            guard generation == current else { return }
            try authorize()
            records = result
        } catch { fail(error, current: current) }
    }

    func save(_ record: AskGenerationRecoveryRecord, name: String, destination: URL, root: URL,
              owner: String, conversation: String, authorize: () throws -> Void) async {
        guard !busy, !closed else { return }
        let current = generation
        busy = true; message = nil
        defer { if generation == current { busy = false } }
        do {
            try authorize()
            let staged = try await AskGenerationRecoveryIO.perform {
                let privatePath = root.resolvingSymlinksInPath().standardizedFileURL.path
                let outputPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
                guard outputPath != privatePath, !outputPath.hasPrefix(privatePath + "/") else { throw AskArtifactError.denied }
                let data = try AskImageGenerationRetention.recoveryFile(rootURL: root, record: record,
                    owner: owner, conversation: conversation, name: name)
                return try AskGenerationRecoveryExport(data: data, destination: destination)
            }
            try Task.checkCancellation()
            guard generation == current else { return }
            try authorize()
            try staged.commit()
            message = L("imagegen.recovery.saved")
        } catch { fail(error, current: current) }
    }

    private func fail(_ error: Error, current: UUID) {
        guard generation == current else { return }
        records = []
        if Task.isCancelled || error is CancellationError { return }
        message = L("imagegen.recovery.unavailable")
    }
}
