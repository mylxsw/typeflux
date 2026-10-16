import AppKit
import Testing
@testable import Typeflux

private actor ArtifactAttemptDecoder {
    private(set) var count = 0
    func decode(_ result: AskFilePreviewPDF.Result) -> AskFilePreviewPDF.Result { count += 1; return result }
}

private actor ArtifactAttemptGate {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}

@Suite("Artifact image callback attempt ownership", .exclusiveUIState)
@MainActor struct ArtifactImageAttemptOwnershipTests {
    private func bundle(_ byte: UInt8 = 1) -> AskArtifactBundle {
        let data = Data([byte, 2, 3])
        let ref = AskArtifactRef(id: UUID().uuidString, ownerId: "owner", conversationId: "conversation", runId: "original",
            version: "1", mediaType: "image/png", sizeBytes: 3, sha256: AskToolPolicy.digest(data), cleanup: "device_persistent")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "image", resources: []), files: ["image": data])
    }
    private func pixels() -> AskFilePreviewPDF.Result {
        .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }

    @Test(arguments: [false, true])
    func retiringAttemptInsideInitialValidationPreventsSourceAndDecode(copying: Bool) async {
        let saved = bundle(), result = pixels()
        let model = AskArtifactImageModel(decode: { _, _ in Issue.record("Retired decode"); return result },
                                         write: { _, _ in Issue.record("Retired write"); return true })
        var checks = 0
        let access = AskArtifactAccess(load: { _ in Issue.record("Retired source read"); return saved }, validate: { _ in
            checks += 1; model.cancel()
        })
        if copying { await model.copy(saved.manifest.ref, access: access) }
        else { await model.load(saved.manifest.ref, access: access) }
        #expect(checks == 1 && model.image == nil && model.error == nil && !model.busy)
        #expect(saved.files["image"] == Data([1, 2, 3]))
    }

    @Test func retiringAttemptInsideSourceLoadPreventsDecodeAndAllowsFreshExplicitCopy() async {
        let saved = bundle(), result = pixels()
        let decoder = ArtifactAttemptDecoder()
        var loads = 0, writes = 0
        let model = AskArtifactImageModel(decode: { _, _ in await decoder.decode(result) }, write: { data, type in
            #expect(data == saved.files["image"] && type == "image/png"); writes += 1; return true
        })
        await model.copy(saved.manifest.ref, access: .init(load: { _ in
            loads += 1; model.cancel(); return saved
        }, validate: { _ in }))
        #expect(loads == 1 && writes == 0 && model.image == nil && model.error == nil && !model.busy)
        #expect(await decoder.count == 0)
        // A second operation is explicit; returning from the canceled callback does not retry it.
        await model.copy(saved.manifest.ref, access: .init(load: { _ in loads += 1; return saved }, validate: { _ in }))
        #expect(loads == 2 && writes == 1 && model.image != nil && model.error == nil && !model.busy)
        #expect(await decoder.count == 1)
        model.cancel()
    }

    @Test(arguments: [false, true])
    func retiringAttemptAfterSuccessfulDecodePreventsPublicationAndCopy(copying: Bool) async {
        let saved = bundle(), result = pixels()
        var checks = 0
        let model = AskArtifactImageModel(decode: { _, _ in result }, write: { _, _ in Issue.record("Retired copy"); return true })
        let access = AskArtifactAccess(load: { _ in saved }, validate: { _ in
            checks += 1
            if checks == 2 { model.cancel() }
        })
        if copying { await model.copy(saved.manifest.ref, access: access) }
        else { await model.load(saved.manifest.ref, access: access) }
        #expect(checks == 2 && model.image == nil && model.error == nil && !model.busy)
    }

    @Test(arguments: [false, true])
    func enteredCopyEffectIsKeptButRetiredCompletionCannotPublish(taskCancellation: Bool) async {
        let saved = bundle(), result = pixels()
        var writes: [Data] = []
        var model: AskArtifactImageModel!
        model = AskArtifactImageModel(decode: { _, _ in result }, write: { data, _ in
            writes.append(data)
            if taskCancellation { withUnsafeCurrentTask { $0?.cancel() } }
            else { model.cancel() }
            return true
        })
        let task = Task { await model.copy(saved.manifest.ref, access: .init(load: { _ in saved }, validate: { _ in })) }
        await task.value
        #expect(writes == [Data([1, 2, 3])] && saved.files["image"] == Data([1, 2, 3]))
        #expect(model.image == nil && model.error == nil && !model.busy)
        model.cancel(); model = nil
    }

    @Test func canceledCallbackErrorsCannotRestoreFailureAndTaskCancellationStopsSource() async {
        let saved = bundle(), result = pixels()
        let model = AskArtifactImageModel(decode: { _, _ in Issue.record("Canceled decode"); return result },
                                         write: { _, _ in Issue.record("Canceled write"); return true })
        for fromLoad in [false, true] {
            await model.load(saved.manifest.ref, access: .init(load: { _ in
                if fromLoad { model.cancel(); throw AskArtifactError.corrupt }
                Issue.record("Unexpected load"); return saved
            }, validate: { _ in
                if !fromLoad { model.cancel(); throw AskArtifactError.denied }
            }))
            #expect(model.image == nil && model.error == nil && !model.busy)
        }
        let task = Task {
            await model.copy(saved.manifest.ref, access: .init(load: { _ in
                Issue.record("Task canceled source"); return saved
            }, validate: { _ in withUnsafeCurrentTask { $0?.cancel() } }))
        }
        await task.value
        #expect(model.image == nil && model.error == nil && !model.busy)
    }

    @Test(arguments: [false, true])
    func collectedOldResultOrErrorCannotClearNewBusyOrPublishedState(oldFails: Bool) async throws {
        let old = bundle(1), fresh = bundle(9), result = pixels()
        let oldGate = ArtifactAttemptGate(), newGate = ArtifactAttemptGate()
        var writes = 0
        let model = AskArtifactImageModel(decode: { data, _ in
            if data.first == 1 {
                await oldGate.hold()
                if oldFails { throw AskArtifactError.corrupt }
            } else { await newGate.hold() }
            return result
        }, write: { _, _ in writes += 1; return true })
        let oldTask = Task { await model.copy(old.manifest.ref, access: .init(load: { _ in old }, validate: { _ in })) }
        await oldGate.waitForEntry()
        model.cancel()
        let freshTask = Task { await model.load(fresh.manifest.ref, access: .init(load: { _ in fresh }, validate: { _ in })) }
        await newGate.waitForEntry()
        await oldGate.release(); await oldTask.value
        #expect(model.busy && model.image == nil && model.error == nil && writes == 0)
        await newGate.release(); await freshTask.value
        #expect(!model.busy && model.image != nil && model.error == nil && writes == 0)
        #expect(old.files["image"] == Data([1, 2, 3]) && fresh.files["image"] == Data([9, 2, 3]))
        model.cancel()
    }
}
