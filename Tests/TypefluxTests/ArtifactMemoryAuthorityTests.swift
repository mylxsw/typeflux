import AppKit
import Testing
@testable import Typeflux

private actor ArtifactMemoryGate {
    private var entered = false, released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true; arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

@Suite("Artifact memory source authority", .exclusiveUIState)
@MainActor struct ArtifactMemoryAuthorityTests {
    private func bundle(_ byte: UInt8 = 1) -> AskArtifactBundle {
        let bytes = Data([byte, 2, 3])
        let ref = AskArtifactRef(id: UUID().uuidString, ownerId: "account", conversationId: "conversation", runId: "run",
            version: "1", mediaType: "image/png", sizeBytes: 3, sha256: AskToolPolicy.digest(bytes), cleanup: "device_persistent")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "image", resources: []), files: ["image": bytes])
    }
    private func identity(_ selection: UUID = UUID(), owner: String = "account", token: String = "credential",
                          conversation: String? = "conversation") -> AskArtifactImageSource.Identity {
        .init(owner: owner, token: token, conversation: conversation, selection: selection)
    }
    private func pixels() -> AskFilePreviewPDF.Result {
        .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }

    @Test func productionMemoryFactoryBindsAccountTokenConversationAndSelectionWithoutIO() {
        let saved = bundle(), original = identity(), otherSelection = identity()
        var live: AskArtifactImageSource.Identity? = original
        let source = AskArtifactImageSource(identity: original, current: { live })
        #expect(source.allows(saved.manifest.ref))
        for replacement in [otherSelection, identity(original.selection, owner: "other"),
            identity(original.selection, token: "other"), identity(original.selection, conversation: "other"), nil] {
            live = replacement; #expect(!source.allows(saved.manifest.ref))
        }
        live = original
        var foreign = saved.manifest.ref; foreign.ownerId = "cache-partition"
        #expect(!source.allows(foreign))
        foreign = saved.manifest.ref; foreign.conversationId = "other"
        #expect(!source.allows(foreign))
        let missing = AskArtifactImageSource(identity: identity(owner: ""), current: { original })
        #expect(!missing.allows(saved.manifest.ref))
        let a = AskArtifactAccess(imageSource: source), b = AskArtifactAccess(imageSource: source)
        #expect(a.imageTaskID(for: saved.manifest.ref) == b.imageTaskID(for: saved.manifest.ref))
        #expect(a.imageTaskID(for: saved.manifest.ref) != AskArtifactAccess().imageTaskID(for: saved.manifest.ref))
    }

    @Test func originalProjectionIsSampledLastAndFreshOrUnscopedAccessCannotBlessPixels() async {
        let saved = bundle(), result = pixels(), id = identity()
        var live: AskArtifactImageSource.Identity? = id
        var loads = 0, validations = 0, writes = 0
        let original = AskArtifactImageSource(identity: id, current: { live })
        let access = AskArtifactAccess(load: { _ in loads += 1; return saved }, validate: { _ in validations += 1 }, imageSource: original)
        let model = AskArtifactImageModel(decode: { _, _ in result }, write: { _, _ in writes += 1; return true })
        await model.load(saved.manifest.ref, access: access)
        let snapshot = model.image
        #expect(snapshot != nil)
        for _ in 0..<100 { #expect(model.projection(for: saved.manifest.ref, access: access).image === snapshot) }
        #expect(model.projection(for: saved.manifest.ref).image == nil)
        let fresh = AskArtifactAccess(imageSource: .init(identity: id, current: { live = nil; return id }))
        #expect(model.projection(for: saved.manifest.ref, access: fresh).image == nil)
        let newAuthorizer = AskArtifactAccess(imageSource: .init(identity: id, current: { id }))
        #expect(model.projection(for: saved.manifest.ref, access: newAuthorizer).error == AskArtifactError.denied.localizedDescription)
        #expect(loads == 1 && validations == 2 && writes == 0)
        // Explicit reopen binds the current source; no getter initiates recovery work.
        live = id; model.cancel(); await model.load(saved.manifest.ref, access: access)
        #expect(model.projection(for: saved.manifest.ref, access: access).image != nil && loads == 2)
        model.cancel()
    }

    @Test(arguments: [false, true]) func staleDeniedEntryPreservesOwnedSuccessOrFailure(_ failure: Bool) async {
        let saved = bundle(), old = bundle(9), result = pixels(), id = identity(), stale = identity()
        let source = AskArtifactImageSource(identity: id, current: { id })
        var loads = 0
        let model = AskArtifactImageModel(decode: { _, _ in if failure { throw AskArtifactError.corrupt }; return result })
        let access = AskArtifactAccess(load: { _ in loads += 1; return saved }, validate: { _ in }, imageSource: source)
        await model.load(saved.manifest.ref, access: access)
        let before = model.projection(for: saved.manifest.ref, access: access)
        for deniedID in [id, stale] {
            await model.load(old.manifest.ref, access: .init(load: { _ in Issue.record("Denied read"); return old },
                validate: { _ in Issue.record("Denied filesystem validation") },
                imageSource: .init(identity: deniedID, current: { nil })))
            let after = model.projection(for: saved.manifest.ref, access: access)
            #expect(after.image === before.image && after.error == before.error && !after.busy)
        }
        #expect(loads == 1)
        model.cancel()
    }

    @Test func staleDenialCannotRetireBusyOwnerAndOldCompletionCannotReplaceFreshIdentity() async {
        let saved = bundle(), result = pixels(), oldID = identity(), newID = identity(), gate = ArtifactMemoryGate()
        var live: AskArtifactImageSource.Identity? = oldID
        let old = AskArtifactAccess(load: { _ in saved }, validate: { _ in }, imageSource: .init(identity: oldID, current: { live }))
        let fresh = AskArtifactAccess(load: { _ in saved }, validate: { _ in }, imageSource: .init(identity: newID, current: { live }))
        let model = AskArtifactImageModel(decode: { _, _ in await gate.hold(); return result })
        let first = Task { await model.load(saved.manifest.ref, access: old) }
        await gate.wait()
        await model.load(saved.manifest.ref, access: .init(imageSource: .init(identity: newID, current: { nil })))
        #expect(model.projection(for: saved.manifest.ref, access: old).busy)
        live = newID
        let second = Task { await model.load(saved.manifest.ref, access: fresh) }
        // Both tasks are joined after releasing the decoder; source retirement cannot roll back entered decoding.
        await gate.release(); await first.value; await second.value
        #expect(model.projection(for: saved.manifest.ref, access: fresh).image != nil)
        #expect(model.projection(for: saved.manifest.ref, access: old).image == nil)
        model.cancel()
    }

    @Test func canceledMemoryCallbacksCannotAdmitReadOrProjectRetiredState() async {
        let saved = bundle(), result = pixels(), id = identity()
        var loads = 0
        let model = AskArtifactImageModel(decode: { _, _ in result })
        let access = AskArtifactAccess(load: { _ in loads += 1; return saved }, validate: { _ in },
            imageSource: .init(identity: id, current: { id }))
        await model.load(saved.manifest.ref, access: access)
        let snapshot = model.image
        let cancelEntry = AskArtifactAccess(imageSource: .init(identity: id, current: { model.cancel(); return id }))
        await model.load(saved.manifest.ref, access: cancelEntry)
        #expect(model.image == nil && loads == 1)
        await model.load(saved.manifest.ref, access: access)
        #expect(snapshot != nil)
        #expect(model.projection(for: saved.manifest.ref, access: cancelEntry).image == nil && model.image == nil)
        let task = Task {
            let cancelTask = AskArtifactAccess(imageSource: .init(identity: id, current: { withUnsafeCurrentTask { $0?.cancel() }; return id }))
            await model.load(saved.manifest.ref, access: cancelTask)
        }
        await task.value
        #expect(loads == 2 && !model.busy)
    }

    @Test(arguments: [false, true]) func sourceRevocationInsideLoadOrFinalValidationCannotCopy(_ final: Bool) async {
        let saved = bundle(), result = pixels(), id = identity()
        var live: AskArtifactImageSource.Identity? = id
        var checks = 0, loads = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in loads += 1; if !final { live = nil }; return saved }, validate: { _ in
            checks += 1; if final && checks == 2 { live = nil }
        }, imageSource: .init(identity: id, current: { live }))
        let model = AskArtifactImageModel(decode: { _, _ in result }, write: { _, _ in writes += 1; return true })
        await model.copy(saved.manifest.ref, access: access)
        #expect(loads == 1 && checks == (final ? 2 : 1) && writes == 0 && model.image == nil && !model.busy)
        #expect(model.projection(for: saved.manifest.ref, access: access).error == AskArtifactError.denied.localizedDescription)
        live = id
        let fresh = AskArtifactAccess(load: { _ in saved }, validate: { _ in }, imageSource: .init(identity: id, current: { live }))
        await model.copy(saved.manifest.ref, access: fresh)
        #expect(writes == 1 && model.projection(for: saved.manifest.ref, access: fresh).image != nil)
        #expect(saved.files["image"] == Data([1, 2, 3]))
        model.cancel()
    }

    @Test func initialDenialAndExpiredFallbackRemainSafeAndRevokedOwnerCanBeReplaced() async {
        let saved = bundle(), result = pixels(), id = identity(), newID = identity()
        var live: AskArtifactImageSource.Identity? = nil
        let denied = AskArtifactAccess(imageSource: .init(identity: id, current: { live }))
        let model = AskArtifactImageModel(decode: { _, _ in result })
        await model.load(saved.manifest.ref, access: denied)
        #expect(model.error == AskArtifactError.denied.localizedDescription)
        #expect(model.projection(for: saved.manifest.ref, access: denied).image == nil)
        let anotherDenied = AskArtifactAccess(imageSource: .init(identity: newID, current: { nil }))
        await model.load(saved.manifest.ref, access: anotherDenied)
        #expect(model.projection(for: saved.manifest.ref, access: anotherDenied).error == AskArtifactError.denied.localizedDescription)
        live = newID
        let expired = AskArtifactAccess(validate: { _ in throw AskArtifactError.expired },
            imageSource: .init(identity: newID, current: { live }))
        await model.load(saved.manifest.ref, access: expired)
        #expect(model.projection(for: saved.manifest.ref, access: expired).error == AskArtifactError.expired.localizedDescription)
        model.cancel()
    }

    @Test func originalGetterAndDenialCallbacksCannotRestoreCanceledOwnership() async {
        let saved = bundle(), result = pixels(), id = identity()
        var retire = false
        let model = AskArtifactImageModel(decode: { _, _ in result })
        let original = AskArtifactAccess(load: { _ in saved }, validate: { _ in },
            imageSource: .init(identity: id, current: { if retire { model.cancel() }; return id }))
        let fresh = AskArtifactAccess(imageSource: .init(identity: id, current: { id }))
        await model.load(saved.manifest.ref, access: original)
        retire = true
        #expect(model.projection(for: saved.manifest.ref, access: fresh).image == nil && model.image == nil)
        retire = false; await model.load(saved.manifest.ref, access: original)
        retire = true
        await model.load(saved.manifest.ref, access: .init(imageSource: .init(identity: id, current: { nil })))
        #expect(model.image == nil && model.error == nil && !model.busy)
    }

    @Test func boundProductionAccessCapturesBeforeQueuedLoadAndKeepsExplicitFilesystemChecks() async throws {
        let saved = bundle(), result = pixels(), id = identity(), replacement = identity()
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0, validations = 0, writes = 0
        func make() -> AskArtifactAccess {
            .boundImages(context: { live }, load: { ref, owner in
                #expect(ref == saved.manifest.ref && owner == "account"); reads += 1; return saved
            }, validate: { ref, owner in
                #expect(ref == saved.manifest.ref && owner == "account"); validations += 1
            }, htmlEnabled: true)
        }
        let access = make()
        #expect(reads == 0 && validations == 0 && access.htmlEnabled)
        let model = AskArtifactImageModel(decode: { _, _ in result }, write: { bytes, _ in
            #expect(bytes == saved.files["image"]); writes += 1; return true
        })
        let old = Task { await model.load(saved.manifest.ref, access: access) }
        live = replacement
        await old.value
        #expect(reads == 0 && validations == 0 && writes == 0)
        for operation in [false, true] {
            do {
                if operation { try access.validate(saved.manifest.ref) }
                else { _ = try access.load(saved.manifest.ref) }
                Issue.record("Old access adopted new selection")
            } catch { #expect(error as? AskArtifactError == .denied) }
        }
        let fresh = make()
        await model.copy(saved.manifest.ref, access: fresh)
        #expect(reads == 1 && validations == 2 && writes == 1)
        #expect(model.projection(for: saved.manifest.ref, access: fresh).image != nil)
        live = nil
        let absent = make(), sameAbsent = make()
        #expect(absent.imageTaskID(for: saved.manifest.ref) == sameAbsent.imageTaskID(for: saved.manifest.ref))
        #expect(absent.imageSource?.allows(saved.manifest.ref) == false)
        #expect(model.projection(for: saved.manifest.ref, access: fresh).image == nil)
        do { try absent.validate(saved.manifest.ref); Issue.record("Absent account validated") }
        catch { #expect(error as? AskArtifactError == .denied) }
        #expect(reads == 1 && validations == 2 && writes == 1 && saved.files["image"] == Data([1, 2, 3]))
        model.cancel()
    }
}
