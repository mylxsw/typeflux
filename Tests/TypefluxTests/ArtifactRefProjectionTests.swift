import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private actor ArtifactProjectionGate {
    private var entered = false, released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true; arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
private actor ArtifactProjectionCounter {
    var count = 0
    func decode(_ result: AskFilePreviewPDF.Result) -> AskFilePreviewPDF.Result { count += 1; return result }
}

@Suite("Artifact exact reference projection", .exclusiveUIState)
@MainActor struct ArtifactRefProjectionTests {
    private func bundle(_ byte: UInt8 = 1) -> AskArtifactBundle {
        let data = Data([byte, 2, 3])
        let ref = AskArtifactRef(id: UUID().uuidString, ownerId: "owner", conversationId: "conversation", runId: "run",
            version: "1", mediaType: "image/png", sizeBytes: 3, sha256: AskToolPolicy.digest(data), cleanup: "device_persistent")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "image", resources: []), files: ["image": data])
    }
    private func pixels() -> AskFilePreviewPDF.Result {
        .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
    private func empty(_ projection: AskArtifactImageModel.Projection) {
        #expect(projection.image == nil && projection.error == nil && !projection.busy)
    }
    private func otherRefs(_ original: AskArtifactRef) -> [AskArtifactRef] {
        let changes: [(inout AskArtifactRef) -> Void] = [
            { $0.id += "other" }, { $0.ownerId += "other" }, { $0.conversationId += "other" },
            { $0.runId += "other" }, { $0.version += "other" }, { $0.mediaType = "image/jpeg" },
            { $0.sizeBytes += 1 }, { $0.sha256 += "other" }, { $0.cleanup = "device_30_days" },
            { $0.expiresAt = Date(timeIntervalSince1970: 1) }
        ]
        return changes.map { change in var ref = original; change(&ref); return ref }
    }

    @Test func getterRequiresEntireOriginalReferenceAndPerformsNoPreparation() async {
        let saved = bundle(), result = pixels(), counter = ArtifactProjectionCounter()
        var loads = 0, validations = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in loads += 1; return saved }, validate: { _ in validations += 1 })
        let model = AskArtifactImageModel(decode: { _, _ in await counter.decode(result) }, write: { _, _ in writes += 1; return true })
        empty(model.projection(for: saved.manifest.ref))
        await model.load(saved.manifest.ref, access: access)
        let snapshot = model.image
        #expect(snapshot != nil)
        for _ in 0..<100 {
            let projection = model.projection(for: saved.manifest.ref)
            #expect(projection.image === snapshot && projection.error == nil && !projection.busy)
            for ref in otherRefs(saved.manifest.ref) { empty(model.projection(for: ref)) }
        }
        #expect(loads == 1 && validations == 2 && writes == 0)
        #expect(await counter.count == 1)
        #expect(saved.files["image"] == Data([1, 2, 3]))
        model.cancel()
    }

    @Test func busyAndFailureBelongOnlyToCurrentAttemptReference() async {
        let old = bundle(), fresh = bundle(9), result = pixels(), gate = ArtifactProjectionGate()
        let model = AskArtifactImageModel(decode: { data, _ in
            if data.first == 9 { await gate.hold(); throw AskArtifactError.corrupt }
            return result
        }, write: { _, _ in Issue.record("Unexpected write"); return false })
        await model.load(old.manifest.ref, access: .init(load: { _ in old }, validate: { _ in }))
        #expect(model.projection(for: old.manifest.ref).image != nil)
        let task = Task { await model.load(fresh.manifest.ref, access: .init(load: { _ in fresh }, validate: { _ in })) }
        await gate.waitForEntry()
        empty(model.projection(for: old.manifest.ref))
        let pending = model.projection(for: fresh.manifest.ref)
        #expect(pending.busy && pending.image == nil && pending.error == nil)
        await gate.release(); await task.value
        empty(model.projection(for: old.manifest.ref))
        let failed = model.projection(for: fresh.manifest.ref)
        #expect(!failed.busy && failed.image == nil && failed.error == AskArtifactError.corrupt.localizedDescription)
        model.cancel()
    }

    @Test func copyingDifferentReferenceCannotProjectRetainedPixelsAsNewSource() async {
        let old = bundle(), fresh = bundle(9), result = pixels(), gate = ArtifactProjectionGate()
        var writes: [Data] = []
        let model = AskArtifactImageModel(decode: { data, _ in
            if data.first == 9 { await gate.hold() }; return result
        }, write: { data, mime in #expect(mime == "image/png"); writes.append(data); return true })
        await model.load(old.manifest.ref, access: .init(load: { _ in old }, validate: { _ in }))
        let previous = model.image
        let task = Task { await model.copy(fresh.manifest.ref, access: .init(load: { _ in fresh }, validate: { _ in })) }
        await gate.waitForEntry()
        #expect(model.image === previous, "Legacy raw state may retain pixels during copy")
        #expect(model.projection(for: fresh.manifest.ref).image == nil && model.projection(for: fresh.manifest.ref).busy)
        empty(model.projection(for: old.manifest.ref))
        await gate.release(); await task.value
        #expect(writes == [Data([9, 2, 3])] && model.projection(for: fresh.manifest.ref).image != nil)
        empty(model.projection(for: old.manifest.ref))
        #expect(old.files["image"] == Data([1, 2, 3]) && fresh.files["image"] == Data([9, 2, 3]))
        model.cancel()
    }

    @Test(arguments: [false, true]) func collectedOldResultCannotChangeFreshProjection(_ oldFails: Bool) async {
        let old = bundle(), fresh = bundle(9), result = pixels(), gate = ArtifactProjectionGate()
        let model = AskArtifactImageModel(decode: { data, _ in
            if data.first == 1 { await gate.hold(); if oldFails { throw AskArtifactError.corrupt } }
            return result
        }, write: { _, _ in Issue.record("Unexpected write"); return false })
        let task = Task { await model.load(old.manifest.ref, access: .init(load: { _ in old }, validate: { _ in })) }
        await gate.waitForEntry()
        await model.load(fresh.manifest.ref, access: .init(load: { _ in fresh }, validate: { _ in }))
        let snapshot = model.projection(for: fresh.manifest.ref).image
        #expect(snapshot != nil); empty(model.projection(for: old.manifest.ref))
        await gate.release(); await task.value
        let projection = model.projection(for: fresh.manifest.ref)
        #expect(projection.image === snapshot && projection.error == nil && !projection.busy)
        empty(model.projection(for: old.manifest.ref))
        model.cancel()
    }

    @Test func canceledEntryPreservesOwnedProjectionAndCancelClearsBothIdentities() async {
        let old = bundle(), fresh = bundle(9), result = pixels()
        var loads = 0
        let model = AskArtifactImageModel(decode: { _, _ in result }, write: { _, _ in Issue.record("Unexpected write"); return false })
        await model.load(old.manifest.ref, access: .init(load: { _ in loads += 1; return old }, validate: { _ in }))
        let snapshot = model.projection(for: old.manifest.ref).image
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(fresh.manifest.ref, access: .init(load: { _ in loads += 1; return fresh }, validate: { _ in }))
        }
        await task.value
        #expect(model.projection(for: old.manifest.ref).image === snapshot && loads == 1)
        empty(model.projection(for: fresh.manifest.ref))
        model.cancel()
        empty(model.projection(for: old.manifest.ref)); empty(model.projection(for: fresh.manifest.ref))
    }

    @Test func initialDeniedAndExpiredFailuresRemainKeyedWithoutSourceReads() async {
        let saved = bundle(), other = bundle(9), result = pixels()
        let model = AskArtifactImageModel(decode: { _, _ in Issue.record("Denied decode"); return result },
            write: { _, _ in Issue.record("Denied write"); return false })
        for failure in [AskArtifactError.denied, .expired] {
            await model.load(saved.manifest.ref, access: .init(load: { _ in Issue.record("Denied source read"); return saved },
                validate: { _ in throw failure }))
            let projection = model.projection(for: saved.manifest.ref)
            #expect(projection.image == nil && !projection.busy && projection.error == failure.localizedDescription)
            empty(model.projection(for: other.manifest.ref))
        }
        model.cancel(); empty(model.projection(for: saved.manifest.ref))
    }

    @Test func viewValueConstructionNeverLoadsValidatesDecodesOrWrites() async {
        let saved = bundle(), fresh = bundle(9), result = pixels(), counter = ArtifactProjectionCounter(), gate = ArtifactProjectionGate()
        var loads = 0, validations = 0, writes = 0
        let model = AskArtifactImageModel(decode: { data, _ in
            let pixels = await counter.decode(result)
            if data.first == 9 { await gate.hold(); throw AskArtifactError.corrupt }
            return pixels
        }, write: { _, _ in writes += 1; return true })
        let access = AskArtifactAccess(load: { ref in loads += 1; return ref == saved.manifest.ref ? saved : fresh },
                                       validate: { _ in validations += 1 })
        func construct(_ bundle: AskArtifactBundle) async {
            let before = [loads, validations, writes], decoded = await counter.count
            // Only SwiftUI values: no host, layout, symbol resolution, window or encoder.
            _ = AskStoredArtifactCard(ref: bundle.manifest.ref, imageModel: model).body
            _ = AskArtifactPreviewView(bundle: bundle, access: access, close: {}, imageModel: model).body
            #expect([loads, validations, writes] == before)
            #expect(await counter.count == decoded)
        }
        await construct(saved)
        await model.load(saved.manifest.ref, access: access)
        let snapshot = model.projection(for: saved.manifest.ref).image
        #expect(snapshot != nil)
        await construct(saved); await construct(fresh)
        #expect(model.projection(for: saved.manifest.ref).image === snapshot)
        let task = Task { await model.load(fresh.manifest.ref, access: access) }
        await gate.waitForEntry()
        #expect(model.projection(for: fresh.manifest.ref).busy)
        await construct(fresh); await construct(saved)
        await gate.release(); await task.value
        #expect(model.projection(for: fresh.manifest.ref).error == AskArtifactError.corrupt.localizedDescription)
        await construct(fresh)
        #expect(loads == 2 && validations == 3 && writes == 0)
        model.cancel()
    }
}
