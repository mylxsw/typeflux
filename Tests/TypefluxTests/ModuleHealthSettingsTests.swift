import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private final class RecoveryUIClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    private var count = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance() { lock.withLock { value += 601 } }
    func opened() -> Int { lock.withLock { count += 1; return count } }
    var opens: Int { lock.withLock { count } }
}

private actor RecoveryUIGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite("Deliberate module recovery admission")
struct ModuleRecoveryRequestTests {
    @Test func requestsRespectBudgetAndNeverClearQuarantineOnRejection() async throws {
        let clock = RecoveryUIClock()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let module = ModuleHandle<Int>(policy: policy, factory: {
            _ = clock.opened(); throw ModuleFailure.unavailable
        }, uptime: { clock.now() })
        await #expect(throws: ModuleFailure.unavailable) { try await module.start() }
        #expect(await module.supervisor.requestRecovery(resetPersistentBudget: true) == .coolingDown)
        #expect(clock.opens == 1)
        clock.advance()
        #expect(await module.supervisor.requestRecovery(resetPersistentBudget: false) == .started)
        for _ in 0..<100 where clock.opens < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clock.opens == 2)
        await module.shutdown()
        #expect(await module.supervisor.requestRecovery(resetPersistentBudget: true) == .disabled)
        let cancelled = Task { () -> ModuleRecoveryResponse in
            withUnsafeCurrentTask { $0?.cancel() }
            return await module.supervisor.requestRecovery(resetPersistentBudget: true)
        }
        #expect(await cancelled.value == .cancelled)
        var invalid = ModulePolicy(); invalid.maxInFlight = 0
        let invalidModule = ModuleHandle(policy: invalid, factory: { 1 })
        #expect(await invalidModule.supervisor.requestRecovery(resetPersistentBudget: false) == .unavailable)
        await invalidModule.shutdown()
    }

    @Test func repeatedRequestsShareStartupAndNeverRebuildReadyService() async throws {
        let gate = RecoveryUIGate(), clock = RecoveryUIClock()
        let module = ModuleHandle(factory: { _ = clock.opened(); await gate.wait(); return 1 })
        #expect(await module.supervisor.requestRecovery(resetPersistentBudget: true) == .started)
        #expect(await module.supervisor.requestRecovery(resetPersistentBudget: true) == .busy)
        await gate.open()
        try await module.start()
        #expect(await module.supervisor.requestRecovery(resetPersistentBudget: true) == .ready)
        #expect(clock.opens == 1)
        await module.shutdown()
    }
}

@Suite("Storage health settings", .exclusiveUIState)
@MainActor
struct ModuleHealthSettingsTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func snapshot(_ state: ModuleState, failure: ModuleFailure? = nil, activeOperations: Int = 0) -> ModuleHealth {
        .init(state: state, generation: UUID(), pendingStarts: 0, activeOperations: activeOperations,
              hasLifecycleWork: false, failure: failure)
    }

    @Test func openingAndReopeningOnlyObserveAndReleaseSubscriptions() async throws {
        let clock = RecoveryUIClock(), module = ModuleHandle(factory: { clock.opened() })
        let registry = ModuleRegistry([.init(.notebook, handle: module)])
        let model = ModuleHealthSettingsModel(registry: registry)
        module.health.publish(snapshot(.degraded, failure: .quarantined))
        for _ in 0..<20 {
            model.startObserving(); model.startObserving()
            #expect(model.health[.notebook]?.failure == .quarantined)
            model.stopObserving()
            await Task.yield()
        }
        #expect(clock.opens == 0)
        #expect(!model.canRecover(.notebook))
        let streams = try (0..<16).map { _ in try module.health.observe() }
        #expect(streams.count == 16)
        await registry.shutdown()
    }

    @Test func summaryCountsAffectedFeaturesAndOffersRetryOnlyWhenWorkHasStopped() async throws {
        let media = ModuleHandle(factory: { 1 }), preview = ModuleHandle(factory: { 2 })
        let notes = ModuleHandle(factory: { 3 })
        let registry = ModuleRegistry([.init(.mediaExtraction, handle: media), .init(.mediaPreviews, handle: preview),
                                       .init(.notebook, handle: notes)])
        let model = ModuleHealthSettingsModel(registry: registry)
        model.startObserving()
        media.health.publish(snapshot(.ready))
        preview.health.publish(snapshot(.ready))
        notes.health.publish(snapshot(.disabled))
        try await UI.wait { model.health[.mediaExtraction]?.state == .ready
            && model.health[.mediaPreviews]?.state == .ready && model.health[.notebook]?.state == .disabled }
        #expect(model.summaryKey == "settings.services.summaryHealthy")
        #expect(model.affectedEntries.isEmpty)

        media.health.publish(snapshot(.recovering))
        preview.health.publish(snapshot(.recovering))
        try await UI.wait { model.health[.mediaExtraction]?.state == .recovering
            && model.health[.mediaPreviews]?.state == .recovering }
        #expect(model.summaryKey == "settings.services.summaryRecovering")
        #expect(model.affectedFeatureCount == 1)
        #expect(!model.canOfferRetry(.mediaExtraction))

        media.health.publish(snapshot(.degraded, activeOperations: 1))
        try await UI.wait { model.health[.mediaExtraction]?.activeOperations == 1 }
        #expect(model.summaryKey == "settings.services.summaryUnavailable")
        #expect(model.unavailableCount == 1)
        #expect(!model.canOfferRetry(.mediaExtraction))
        media.health.publish(snapshot(.degraded))
        try await UI.wait { model.health[.mediaExtraction]?.activeOperations == 0 }
        #expect(model.canOfferRetry(.mediaExtraction))
        media.health.publish(snapshot(.degraded, failure: .invalidPolicy))
        try await UI.wait { model.health[.mediaExtraction]?.failure == .invalidPolicy }
        #expect(!model.canOfferRetry(.mediaExtraction))
        #expect(model.detailKey(.mediaExtraction) == "settings.services.invalidPolicyDetail")
        model.stopObserving()
        await registry.shutdown()
    }

    @Test func quarantineRecoveryPreservesNotebookAndDoesNotReplayWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("notes.db"), metadata = root.appendingPathComponent("health.json")
        let original = makeTestNote()
        let seed = SQLiteAskNoteStore(url: database)
        #expect(try seed.save(original))
        try Data("invalid metadata".utf8).write(to: metadata)
        let clock = RecoveryUIClock()
        let notes = RecoveringAskNoteStore(factory: {
            _ = clock.opened(); return SQLiteAskNoteStore(url: database)
        }, healthStore: ModuleHealthStore(url: metadata), uptime: { clock.now() })
        let registry = ModuleRegistry([.init(.notebook, handle: notes.module)])
        _ = await registry.startAll()
        let model = ModuleHealthSettingsModel(registry: registry)
        model.startObserving()
        #expect(clock.opens == 0)
        #expect(try Data(contentsOf: metadata) == Data("invalid metadata".utf8))
        model.recover(.notebook)
        try await UI.wait { model.responses[.notebook] == .coolingDown }
        #expect(model.responseKey(.notebook) == "settings.services.wait")
        #expect(clock.opens == 0)
        clock.advance()
        model.recover(.notebook); model.recover(.notebook)
        try await UI.wait { model.health[.notebook]?.state == .ready }
        #expect(clock.opens == 1)
        #expect(try await notes.note(id: original.id) == original)
        #expect(try await notes.count(.all) == 1)
        #expect(model.responses[.notebook] == nil)
        model.stopObserving()
        await registry.shutdown()
    }

    @Test func closingCancelsQueuedRequestAndReopeningNeverResubmitsIt() async throws {
        let clock = RecoveryUIClock(), module = ModuleHandle(factory: { clock.opened() })
        let model = ModuleHealthSettingsModel(registry: ModuleRegistry([.init(.notebook, handle: module)]))
        module.supervisor.admission.setEnabled(true)
        module.health.publish(snapshot(.degraded))
        model.startObserving()
        model.recover(.notebook)
        model.stopObserving()
        await Task.yield()
        #expect(clock.opens == 0)
        #expect(model.responses.isEmpty && model.requests.isEmpty)
        model.startObserving()
        await Task.yield()
        #expect(clock.opens == 0)
        model.stopObserving()
        await module.shutdown()
    }

    @Test func unavailableObservationFailsClosedAndStateCopyIsLocalized() async throws {
        try await UI.withFixture { _ in
            let module = ModuleHandle(factory: { 1 })
            let registry = ModuleRegistry([.init(.notebook, handle: module)])
            let occupied = try (0..<16).map { _ in try module.health.observe() }
            let model = ModuleHealthSettingsModel(registry: registry)
            model.startObserving()
            #expect(model.observationFailed == [.notebook])
            #expect(model.statusKey(.notebook) == "settings.services.observationFailed")
            model.recover(.notebook)
            #expect(model.requests.isEmpty)
            #expect(occupied.count == 16)
            model.stopObserving()
            let states: [ModuleState] = [.stopped, .starting, .ready, .recovering, .circuitOpen, .degraded, .disabled]
            for language in AppLanguage.allCases {
                AppLocalization.shared.setLanguage(language)
                for state in states {
                    module.health.publish(snapshot(state))
                    let fresh = ModuleHealthSettingsModel(registry: registry)
                    // Read snapshots even when subscriber capacity is exhausted.
                    fresh.startObserving()
                    #expect(L(fresh.statusKey(.notebook)) != fresh.statusKey(.notebook))
                    fresh.stopObserving()
                }
                for key in ["title", "conversations", "wordBook", "notebook", "mediaExtraction", "mediaPreviews", "recover", "hint", "stopped", "recovering",
                            "ready", "coolingDown", "unavailable", "disabled", "quarantined", "observationFailed", "requested", "wait", "busy",
                            "summaryHealthy", "summaryHealthyDetail", "summaryUnavailable", "summaryUnavailableDetail", "summaryRecovering",
                            "summaryUnknown", "summaryUnknownDetail", "diagnostics", "retry", "invalidPolicyDetail", "quarantinedDetail", "healthPersistenceDetail",
                            "unavailableDetail", "coolingDownDetail", "recoveringDetail", "featureAttachments", "featureClipboard",
                            "featureScreenshots", "featureRecordings", "featureCommands", "featureTranscription", "featureFileSearch"] {
                    #expect(L("settings.services." + key) != "settings.services." + key)
                }
            }
            await registry.shutdown()
        }
    }

    @Test func statusesAndFailureOutcomesRemainTruthful() async throws {
        let module = ModuleHandle(factory: { 1 }), registry = ModuleRegistry([])
        let empty = ModuleHealthSettingsModel(registry: nil)
        #expect(empty.entries.isEmpty && empty.statusKey(.notebook) == "settings.services.stopped")
        empty.recover(.notebook)
        let registration = ModuleRegistry([.init(.notebook, handle: module)])
        let model = ModuleHealthSettingsModel(registry: registration)
        model.startObserving()
        for (state, key) in [(ModuleState.stopped, "stopped"), (.starting, "recovering"), (.recovering, "recovering"),
                             (.ready, "ready"), (.circuitOpen, "coolingDown"), (.degraded, "unavailable"), (.disabled, "disabled")] {
            module.health.publish(snapshot(state))
            try await UI.wait { model.health[.notebook]?.state == state }
            #expect(model.statusKey(.notebook) == "settings.services." + key)
        }
        module.health.publish(snapshot(.degraded, failure: .quarantined))
        try await UI.wait { model.health[.notebook]?.failure == .quarantined }
        #expect(model.statusKey(.notebook) == "settings.services.quarantined")
        model.recover(.notebook) // Admission was never enabled by the registry.
        try await UI.wait { model.responses[.notebook] == .disabled }
        #expect(model.responseKey(.notebook) == "settings.services.disabled")
        model.stopObserving()
        await registration.shutdown()
        await registry.shutdown()
    }

    @Test func failedRecoveryAndBusyCleanupNeverReportReady() async throws {
        let clock = RecoveryUIClock()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let module = ModuleHandle<Int>(policy: policy, factory: {
            _ = clock.opened(); throw ModuleFailure.unavailable
        }, classify: { _ in .waitForExplicitRetry }, uptime: { clock.now() })
        let registry = ModuleRegistry([.init(.notebook, handle: module)])
        _ = await registry.startAll()
        let model = ModuleHealthSettingsModel(registry: registry)
        model.startObserving()
        clock.advance()
        model.recover(.notebook)
        try await UI.wait { clock.opens == 2 && model.health[.notebook]?.state == .degraded && model.requests.isEmpty }
        #expect(model.statusKey(.notebook) == "settings.services.unavailable")
        // The starting snapshot may clear the request acknowledgement before failure arrives.
        // The durable status must report failure; an optional acknowledgement must never imply success.
        #expect(model.responseKey(.notebook) == nil || model.responseKey(.notebook) == "settings.services.unavailable")
        model.stopObserving()
        await registry.shutdown()

        let gate = RecoveryUIGate()
        let busy = ModuleHandle(policy: policy, factory: { 1 }, cleanup: { _ in await gate.wait() })
        let busyRegistry = ModuleRegistry([.init(.notebook, handle: busy)])
        try await busyRegistry.start(.notebook)
        await #expect(throws: ModuleFailure.unavailable) { try await busy.perform { _ in throw ModuleFailure.unavailable } }
        let busyModel = ModuleHealthSettingsModel(registry: busyRegistry)
        busyModel.startObserving()
        busyModel.recover(.notebook)
        try await UI.wait { busyModel.responses[.notebook] == .busy }
        #expect(busyModel.responseKey(.notebook) == "settings.services.busy")
        busyModel.stopObserving()
        await gate.open()
        await busyRegistry.shutdown()
    }

    @Test func advancedPageRendersStatusesAndRecoveryActionWithoutReplayingOnNavigation() async throws {
        try await UI.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-settings-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let clock = RecoveryUIClock()
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let chat = ModuleHandle(factory: { 1 })
            let words = ModuleHandle(policy: policy, factory: {
                if clock.opened() == 1 { throw ModuleFailure.quarantined }
                return 2
            }, classify: { _ in .waitForExplicitRetry }, uptime: { clock.now() })
            let notes = ModuleHandle<Int>(policy: policy, factory: { throw ModuleFailure.unavailable },
                                         classify: { _ in .waitForExplicitRetry })
            let registry = ModuleRegistry([.init(.conversations, handle: chat), .init(.wordBook, handle: words),
                                           .init(.notebook, handle: notes)])
            _ = await registry.startAll()
            let healthModel = ModuleHealthSettingsModel(registry: registry)
            let studio = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                initialSection: .settings, localModelManager: FixtureLocalModels(),
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false))
            try await UI.withWindow(StudioView(viewModel: studio, settingsPane: .advanced, moduleHealth: healthModel),
                                    width: 1100, height: 1000) { _, host in
                try await UI.wait { UI.contains(L("settings.services.quarantined"), in: host) }
                #expect(UI.contains(L("settings.services.summaryUnavailable", 2), in: host))
                #expect(UI.contains(L("settings.services.summaryUnavailableDetail"), in: host))
                #expect(UI.contains(L("settings.services.quarantinedDetail"), in: host))
                #expect(!UI.contains(L("settings.services.conversations"), in: host))
                #expect(UI.contains(L("settings.services.hint"), in: host))
                try UI.snapshot(host, name: "recovery-services-zh-Hans")
                try UI.button(L("settings.services.diagnostics"), in: host).press()
                try await UI.wait { UI.contains(L("settings.services.conversations"), in: host) }
                #expect(UI.contains(L("settings.services.ready"), in: host))
                let button = try #require(UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "settings.services.wordBook.recover"
                })
                clock.advance()
                try button.press()
                try await UI.wait { healthModel.health[.wordBook]?.state == .ready }
                #expect(clock.opens == 2)
                try UI.button(AppSettingsPane.general.title, in: host).press()
                try await UI.wait { !healthModel.observing }
                try UI.button(AppSettingsPane.advanced.title, in: host).press()
                try await UI.wait { healthModel.observing }
                #expect(clock.opens == 2)
            }
            healthModel.stopObserving()
            await registry.shutdown()
        }
    }

    @Test func standaloneUnavailablePanelAndModelReleaseAreSafe() async throws {
        try await UI.withFixture { _ in
            let model = ModuleHealthSettingsModel(registry: nil)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 700, height: 300) { _, host in
                try await UI.wait { UI.contains(L("settings.services.summaryUnknown"), in: host) }
                #expect(!model.canRecover(.notebook))
            }
            model.stopObserving()
        }
        let module = ModuleHandle(factory: { 1 }), registry = ModuleRegistry([])
        let configured = ModuleRegistry([.init(.notebook, handle: module)])
        var model: ModuleHealthSettingsModel? = ModuleHealthSettingsModel(registry: configured)
        weak var released = model
        model?.startObserving()
        model = nil
        try await UI.wait { released == nil }
        await configured.shutdown()
        await registry.shutdown()
    }

    @Test func healthyPanelHidesModuleListAndRecoveryControlsUntilDiagnosticsOpen() async throws {
        try await UI.withFixture { _ in
            let module = ModuleHandle(factory: { 1 })
            let registry = ModuleRegistry([.init(.notebook, handle: module)])
            try await registry.start(.notebook)
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 700, height: 300) { _, host in
                try await UI.wait {
                    model.health[.notebook]?.state == .ready && UI.contains(L("settings.services.summaryHealthy"), in: host)
                }
                #expect(!UI.contains(L("settings.services.notebook"), in: host))
                #expect(!UI.contains(L("settings.services.retry"), in: host))
                #expect(UI.contains(L("settings.services.summaryHealthyDetail"), in: host))
                try UI.snapshot(host, name: "service-health-healthy")
                try UI.button(L("settings.services.diagnostics"), in: host).press()
                try await UI.wait { UI.contains(L("settings.services.notebook"), in: host) }
                #expect(!UI.contains(L("settings.services.retry"), in: host))
            }
            model.stopObserving()
            await registry.shutdown()
        }
    }
}
