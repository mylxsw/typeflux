import Foundation
import Testing
@testable import Typeflux

private final class AuthorityEncoder: SemanticEmbedding, @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, entered = false, requested = false, answer: Bool?
    var waiting: Bool { condition.withLock { entered && held } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
    // A worker samples its original cancellation while MainActor stays blocked.
    func sample() -> Bool? {
        condition.lock(); defer { condition.unlock() }
        requested = true; answer = nil; condition.broadcast()
        let deadline = Date().addingTimeInterval(2)
        while answer == nil, condition.wait(until: deadline) {}
        return answer
    }

    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        condition.lock(); entered = true; condition.broadcast()
        while held {
            if requested { answer = cancelled(); requested = false; condition.broadcast() }
            _ = condition.wait(until: Date().addingTimeInterval(0.01))
        }
        condition.unlock()
        if cancelled() { throw CancellationError() }
        return texts.map { _ in semanticVector() }
    }
}

private final class AuthorityReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SemanticSettingsChange] = []
    func append(_ value: SemanticSettingsChange) { lock.withLock { values.append(value) } }
    var latest: SemanticSettingsChange? { lock.withLock { values.last } }
}

@Suite("Semantic settings producer authority", .serialized, .exclusiveUIState)
@MainActor
struct SemanticSettingsAuthorityTests {
    private func fixture(automatic: Bool = true) async throws -> (SemanticFileSearchService, URL, AuthorityEncoder) {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        base.settings.semanticFileSearch = .init(enabled: true)
        let encoder = AuthorityEncoder()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: automatic, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, idle: { true }, makeReader: { reader }, makeEncoder: { _, _ in encoder },
            makeQuery: { _, _ in SemanticFixtureQuery() }, eventHistory: { _ in (100, "fixture-volume") })
        if !automatic { service.start() }
        try await SemanticFileServiceTests.wait { encoder.waiting }
        return (service, root, encoder)
    }

    @Test(arguments: ["semantic", "files", "roots"])
    func acceptedEditRevokesOriginalProducerBeforeActorCanRun(_ edit: String) async throws {
        let (service, root, encoder) = try await fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        // A different SettingsStore using the same defaults object must revoke too.
        let alias = SettingsStore(defaults: service.settings.defaults)
        if edit == "semantic" { alias.semanticFileSearch = .init(enabled: false) }
        else if edit == "files" { alias.askQuickFileSearchEnabled = false }
        else {
            var names = alias.askLauncherSearchSettings; names.fileRoots = []
            alias.askLauncherSearchSettings = names
        }
        #expect(service.phase == .indexing, "the queued MainActor transition has not executed")
        #expect(encoder.sample() == true, "off-actor admission sees synchronous original-token revocation")
        encoder.release()
        await service.clear(removeModel: true)
        #expect(service.phase == .off)
    }

    @Test func roundTripAndDelayedOldReceiptCannotRevokeReplacement() async throws {
        let (service, root, encoder) = try await fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        let receipts = AuthorityReceipts()
        let observer = NotificationCenter.default.addObserver(forName: SemanticSettingsChange.notification,
            object: nil, queue: nil) { note in
                if let change = note.userInfo?["change"] as? SemanticSettingsChange { receipts.append(change) }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        service.settings.semanticFileSearch = .init(enabled: false)
        let old = try #require(receipts.latest)
        service.settings.semanticFileSearch = .init(enabled: true)
        #expect(encoder.sample() == true)
        encoder.release()
        service.start() // Same fingerprint still needs a fresh token after A -> B -> A.
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        NotificationCenter.default.post(name: SemanticSettingsChange.notification, object: service.settings,
                                        userInfo: ["change": old])
        service.start()
        #expect(service.phase == .ready && service.isEnabled)
        #expect(!(await service.search("handbook", type: .document, limit: 5)).isEmpty)
        await service.clear(removeModel: true)
    }

    @Test func unrelatedNoopAndForeignSettingsKeepOriginalProducer() async throws {
        let (service, root, encoder) = try await fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        service.settings.semanticFileSearch = .init(enabled: true)
        service.settings.askQuickFileSearchEnabled = true
        var names = service.settings.askLauncherSearchSettings
        names.fuzzy.toggle(); names.fileIcons = .icons
        service.settings.askLauncherSearchSettings = names
        service.settings.askQuickCalculatorEnabled = false
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let foreign = SettingsStore(defaults: defaults)
        foreign.semanticFileSearch = .init(enabled: true)
        #expect(encoder.sample() == false)
        encoder.release()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        await service.clear(removeModel: true)
    }

    @Test func standaloneAutomaticStartFalseRetainsExplicitTransitionContract() async throws {
        let (service, root, encoder) = try await fixture(automatic: false)
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        service.settings.semanticFileSearch = .init(enabled: false)
        #expect(encoder.sample() == false)
        service.start()
        #expect(encoder.sample() == true)
        encoder.release()
        await service.clear(removeModel: true)
    }

    @Test func outOfOrderReceiptCannotAdoptOrRevokeALaterScope() {
        let authority = SemanticSettingsAuthority(), original = AskSearchCancellation()
        authority.bind(original, fingerprint: "original")
        let old = SemanticSettingsChange(fingerprint: "old")
        let latest = SemanticSettingsChange(fingerprint: "latest")
        authority.receive(latest); authority.receive(old)
        #expect(original.isCancelled)
        let replacement = AskSearchCancellation()
        authority.bind(replacement, fingerprint: "latest")
        authority.receive(old); authority.receive(latest)
        #expect(!replacement.isCancelled)
    }

    @Test func receiptRevokesBeforePersistenceAndDuplicateCannotRevokeNewBind() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults), authority = SemanticSettingsAuthority()
        let old = AskSearchCancellation()
        authority.bind(old, fingerprint: settings.semanticScopeFingerprint())
        let receipts = AuthorityReceipts(), identity = ObjectIdentifier(defaults)
        let observer = NotificationCenter.default.addObserver(forName: SemanticSettingsChange.notification,
            object: nil, queue: nil) { note in
                guard let source = note.object as? SettingsStore, ObjectIdentifier(source.defaults) == identity,
                      let change = note.userInfo?["change"] as? SemanticSettingsChange else { return }
                #expect(!source.semanticFileSearch.enabled, "revocation precedes the accepted write")
                authority.receive(change)
                #expect(old.isCancelled)
                receipts.append(change)
            }
        settings.semanticFileSearch = .init(enabled: true)
        NotificationCenter.default.removeObserver(observer)
        let receipt = try #require(receipts.latest), replacement = AskSearchCancellation()
        authority.bind(replacement, fingerprint: settings.semanticScopeFingerprint())
        authority.receive(receipt)
        #expect(!replacement.isCancelled)
        authority.receive(SemanticSettingsChange(fingerprint: settings.semanticScopeFingerprint()))
        #expect(!replacement.isCancelled, "same-scope signals carry no revocation")
        authority.receive(SemanticSettingsChange(fingerprint: "changed"))
        #expect(replacement.isCancelled)
    }
}
