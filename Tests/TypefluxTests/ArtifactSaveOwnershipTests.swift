import SwiftUI
import Testing
@testable import Typeflux

@Suite("Artifact explicit save ownership", .exclusiveUIState)
@MainActor struct ArtifactSaveOwnershipTests {
    private let destination = URL(fileURLWithPath: "/private/unused-artifact-save-sink")
    private func bundle(_ byte: UInt8 = 1) -> AskArtifactBundle {
        let bytes = Data([byte, 2, 3])
        let ref = AskArtifactRef(id: UUID().uuidString, ownerId: "account", conversationId: "conversation", runId: "run",
            version: "1", mediaType: "text/plain", sizeBytes: 3, sha256: AskToolPolicy.digest(bytes), cleanup: "device_30_days")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "private", resources: []), files: ["private": bytes])
    }
    private func identity() -> AskArtifactImageSource.Identity {
        .init(owner: "account", token: "private-credential", conversation: "conversation", selection: UUID())
    }

    @Test func productionAccessRetainsOriginalAcrossChooserAndFreshExplicitSaveWritesOnce() {
        let saved = bundle(), id = identity(), replacement = identity(), model = AskArtifactSaveModel()
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0, checks = 0, choices = 0, writes = 0
        func make() -> AskArtifactAccess {
            .boundImages(context: { live }, load: { ref, owner in
                #expect(ref == saved.manifest.ref && owner == "account"); reads += 1; return saved
            }, validate: { _, _ in checks += 1 })
        }
        let original = make()
        model.save(saved.manifest.ref, access: original, choose: { _ in choices += 1; live = replacement; return destination },
            write: { _, _ in writes += 1 })
        #expect(reads == 1 && choices == 1 && writes == 0)
        let fresh = make()
        model.save(saved.manifest.ref, access: fresh, choose: { _ in choices += 1; return destination }, write: { output, url in
            #expect(output.files == saved.files && url == destination); writes += 1
        })
        for _ in 0..<100 { #expect(model.projectedError(for: saved.manifest.ref, access: fresh) == nil) }
        #expect(reads == 3 && choices == 2 && writes == 1 && checks == 0)
        #expect(saved.files["private"] == Data([1, 2, 3]))
        model.cancel()
    }

    @Test func exactSourceErrorsAndDeniedOldEntryCannotReplaceOwnedFailure() {
        let saved = bundle(), other = bundle(9), id = identity(), foreign = identity(), model = AskArtifactSaveModel()
        var reads = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; throw AskArtifactError.expired },
            imageSource: .init(identity: id, current: { id }))
        model.save(saved.manifest.ref, access: access, choose: { _ in Issue.record("Expired chooser"); return nil }, write: { _, _ in Issue.record("Expired write") })
        let expected = AskArtifactError.expired.localizedDescription
        #expect(model.projectedError(for: saved.manifest.ref, access: access) == expected)
        for deniedID in [id, foreign] {
            let denied = AskArtifactAccess(imageSource: .init(identity: deniedID, current: { nil }))
            model.save(other.manifest.ref, access: denied, choose: { _ in Issue.record("Denied chooser"); return nil }, write: { _, _ in })
            #expect(model.projectedError(for: saved.manifest.ref, access: access) == expected)
        }
        #expect(model.projectedError(for: other.manifest.ref, access: access) == nil)
        #expect(model.projectedError(for: saved.manifest.ref, access: .init()) == nil)
        #expect(reads == 1)
        model.cancel()
        let denied = AskArtifactAccess(imageSource: .init(identity: foreign, current: { nil }))
        model.save(saved.manifest.ref, access: denied, choose: { _ in nil }, write: { _, _ in })
        #expect(model.projectedError(for: saved.manifest.ref, access: denied) == AskArtifactError.denied.localizedDescription)
    }

    @Test func getterSamplesOriginalLastAndNeverReadsOrClearsNewOwnership() {
        let saved = bundle(), id = identity(), model = AskArtifactSaveModel()
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0, validations = 0
        let original = AskArtifactAccess(load: { _ in reads += 1; throw AskArtifactError.expired }, validate: { _ in validations += 1 },
            imageSource: .init(identity: id, current: { live }))
        model.save(saved.manifest.ref, access: original, choose: { _ in nil }, write: { _, _ in })
        let fresh = AskArtifactAccess(imageSource: .init(identity: id, current: { live = nil; return id }))
        #expect(model.projectedError(for: saved.manifest.ref, access: fresh) == AskArtifactError.denied.localizedDescription)
        let authorizer = AskArtifactAccess(imageSource: .init(identity: id, current: { id }))
        for _ in 0..<100 { #expect(model.projectedError(for: saved.manifest.ref, access: authorizer) == AskArtifactError.denied.localizedDescription) }
        let closing = AskArtifactAccess(imageSource: .init(identity: id, current: { model.cancel(); return id }))
        #expect(model.projectedError(for: saved.manifest.ref, access: closing) == nil)
        #expect(reads == 1 && validations == 0)
    }

    @Test(arguments: ["source", "firstLoad", "choose", "finalLoad"])
    func cancellationAtEachBoundaryStopsNextEffect(_ boundary: String) {
        let saved = bundle(), id = identity(), model = AskArtifactSaveModel()
        var reads = 0, choices = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in
            reads += 1
            if boundary == "firstLoad" || (boundary == "finalLoad" && reads == 2) { model.cancel() }
            return saved
        }, imageSource: .init(identity: id, current: { if boundary == "source" { model.cancel() }; return id }))
        model.save(saved.manifest.ref, access: access, choose: { _ in
            choices += 1; if boundary == "choose" { model.cancel() }; return destination
        }, write: { _, _ in writes += 1 })
        #expect(reads == (boundary == "source" ? 0 : boundary == "finalLoad" ? 2 : 1))
        #expect(choices == ((boundary == "choose" || boundary == "finalLoad") ? 1 : 0))
        #expect(writes == 0 && model.projectedError(for: saved.manifest.ref, access: access) == nil)
    }

    @Test func precanceledAndTaskCanceledChooserNeverWriteOrMutateOwnedError() async {
        let saved = bundle(), model = AskArtifactSaveModel()
        let failed = AskArtifactAccess(load: { _ in throw AskArtifactError.expired })
        model.save(saved.manifest.ref, access: failed, choose: { _ in nil }, write: { _, _ in })
        var reads = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; return saved })
        let first = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            model.save(saved.manifest.ref, access: access, choose: { _ in destination }, write: { _, _ in writes += 1 })
        }
        await first.value
        #expect(reads == 0 && model.projectedError(for: saved.manifest.ref, access: failed) == AskArtifactError.expired.localizedDescription)
        let second = Task {
            model.save(saved.manifest.ref, access: access, choose: { _ in withUnsafeCurrentTask { $0?.cancel() }; return destination }, write: { _, _ in writes += 1 })
        }
        await second.value
        #expect(reads == 1 && writes == 0)
        model.cancel()
    }

    @Test(arguments: [false, true]) func oldReentrantLoadReturnOrThrowCannotClearFreshError(_ throwing: Bool) {
        let saved = bundle(), fresh = bundle(9), model = AskArtifactSaveModel()
        let failed = AskArtifactAccess(load: { _ in throw AskArtifactError.expired })
        model.save(saved.manifest.ref, access: .init(load: { _ in
            model.save(fresh.manifest.ref, access: failed, choose: { _ in nil }, write: { _, _ in })
            if throwing { throw AskArtifactError.corrupt }; return saved
        }), choose: { _ in Issue.record("Retired chooser"); return nil }, write: { _, _ in Issue.record("Retired write") })
        #expect(model.projectedError(for: fresh.manifest.ref, access: failed) == AskArtifactError.expired.localizedDescription)
        #expect(model.projectedError(for: saved.manifest.ref, access: .init()) == nil)
    }

    @Test(arguments: [false, true]) func enteredWriterEffectIsOnceAndCannotClearNestedNewFailure(_ throwing: Bool) {
        let saved = bundle(), fresh = bundle(9), model = AskArtifactSaveModel()
        var writes = 0
        let failed = AskArtifactAccess(load: { _ in throw AskArtifactError.expired })
        model.save(saved.manifest.ref, access: .init(load: { _ in saved }), choose: { _ in destination }, write: { output, _ in
            #expect(output.files == saved.files); writes += 1
            model.save(fresh.manifest.ref, access: failed, choose: { _ in nil }, write: { _, _ in Issue.record("Nested write") })
            if throwing { throw AskArtifactError.corrupt }
        })
        #expect(writes == 1 && model.projectedError(for: fresh.manifest.ref, access: failed) == AskArtifactError.expired.localizedDescription)
    }

    @Test(arguments: ["ref", "digest", "missing", "unknown", "cancelDialog"])
    func finalReloadAndFallbackPreserveBundleWithoutWrite(_ failure: String) {
        let saved = bundle(), other = bundle(9), model = AskArtifactSaveModel()
        var reads = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in
            reads += 1
            if failure == "unknown" { throw NSError(domain: "private-path", code: 1) }
            if reads == 1 { return saved }
            if failure == "ref" { return other }
            var corrupted = saved
            corrupted.files = failure == "missing" ? [:] : ["private": Data([9])]
            return corrupted
        })
        model.save(saved.manifest.ref, access: access, choose: { _ in failure == "cancelDialog" ? nil : destination }, write: { _, _ in writes += 1 })
        let expected: String? = failure == "cancelDialog" ? nil : (failure == "unknown" ? AskArtifactError.unavailable : .corrupt).localizedDescription
        #expect(model.projectedError(for: saved.manifest.ref, access: access) == expected && writes == 0)
        #expect(reads == ((failure == "unknown" || failure == "cancelDialog") ? 1 : 2))
        #expect(saved.files["private"] == Data([1, 2, 3]))
    }

    @Test func validFinalReloadRevocationAndInitialWrongRefStopWriter() {
        let saved = bundle(), other = bundle(9), id = identity(), model = AskArtifactSaveModel()
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; if reads == 2 { live = nil }; return saved },
            imageSource: .init(identity: id, current: { live }))
        model.save(saved.manifest.ref, access: access, choose: { _ in destination }, write: { _, _ in writes += 1 })
        #expect(reads == 2 && writes == 0 && model.projectedError(for: saved.manifest.ref, access: access) == AskArtifactError.denied.localizedDescription)
        let wrong = AskArtifactAccess(load: { _ in other })
        model.save(saved.manifest.ref, access: wrong, choose: { _ in Issue.record("Wrong ref chooser"); return nil }, write: { _, _ in writes += 1 })
        #expect(writes == 0 && model.projectedError(for: saved.manifest.ref, access: wrong) == AskArtifactError.corrupt.localizedDescription)
    }

    @Test func writerAndEntryCallbacksCannotRestoreRetiredState() {
        let saved = bundle(), fresh = bundle(9), id = identity(), model = AskArtifactSaveModel()
        var writes = 0
        let access = AskArtifactAccess(load: { _ in saved })
        model.save(saved.manifest.ref, access: access, choose: { _ in destination }, write: { _, _ in
            writes += 1; model.cancel()
        })
        #expect(writes == 1 && model.projectedError(for: saved.manifest.ref, access: access) == nil)
        let failed = AskArtifactAccess(load: { _ in throw AskArtifactError.expired })
        let nested = AskArtifactAccess(imageSource: .init(identity: id, current: {
            model.save(fresh.manifest.ref, access: failed, choose: { _ in nil }, write: { _, _ in })
            return id
        }))
        model.save(saved.manifest.ref, access: nested, choose: { _ in Issue.record("Retired entry"); return nil }, write: { _, _ in })
        #expect(model.projectedError(for: fresh.manifest.ref, access: failed) == AskArtifactError.expired.localizedDescription)
        let retiringOriginal = AskArtifactAccess(load: { _ in throw AskArtifactError.expired },
            imageSource: .init(identity: id, current: { id }))
        model.save(saved.manifest.ref, access: retiringOriginal, choose: { _ in nil }, write: { _, _ in })
        // Denial's original-source callback may itself close the owner.
        let closing = AskArtifactAccess(imageSource: .init(identity: id, current: { model.cancel(); return id }))
        #expect(model.projectedError(for: saved.manifest.ref, access: closing) == nil)
    }

    @Test func cardBodyValueProjectsErrorWithoutChooserOrIO() {
        let saved = bundle(), model = AskArtifactSaveModel()
        var reads = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; throw AskArtifactError.expired })
        model.save(saved.manifest.ref, access: access, choose: { _ in nil }, write: { _, _ in })
        _ = AskStoredArtifactCard(ref: saved.manifest.ref, saveModel: model).body
        _ = AskStoredArtifactCard(ref: bundle(9).manifest.ref, saveModel: model).body
        #expect(reads == 1)
        model.cancel()
    }
}
