import SwiftUI
import Testing
@testable import Typeflux

@Suite("Artifact retained preview source", .exclusiveUIState)
@MainActor struct ArtifactPreviewSourceTests {
    private func bundle(_ bytes: Data = Data("private text".utf8), type: String = "text/plain") -> AskArtifactBundle {
        let ref = AskArtifactRef(id: UUID().uuidString, ownerId: "account", conversationId: "conversation", runId: "run",
            version: "1", mediaType: type, sizeBytes: Int64(bytes.count), sha256: AskToolPolicy.digest(bytes), cleanup: "device_30_days")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "private", resources: []), files: ["private": bytes])
    }
    private func identity() -> AskArtifactImageSource.Identity {
        .init(owner: "account", token: "credential", conversation: "conversation", selection: UUID())
    }

    @Test func sameProductionFactoryBindsBeforeQueuedOpenAndProjectionNeverReadsFiles() async {
        let saved = bundle(), id = identity(), replacement = identity(), model = AskArtifactPreviewModel()
        var live: AskArtifactImageSource.Identity? = id
        var loads = 0, validations = 0
        func make() -> AskArtifactAccess {
            .boundImages(context: { live }, load: { ref, owner in
                #expect(ref == saved.manifest.ref && owner == "account"); loads += 1; return saved
            }, validate: { _, _ in validations += 1 })
        }
        let old = make()
        let task = Task { model.open(saved.manifest.ref, access: old) }
        live = replacement
        await task.value
        #expect(loads == 0 && validations == 0)
        let fresh = make()
        model.open(saved.manifest.ref, access: fresh)
        let receipt = model.projection(for: saved.manifest.ref, access: fresh).preview
        #expect(receipt?.bundle.files == saved.files)
        for _ in 0..<100 {
            #expect(model.projection(for: saved.manifest.ref, access: fresh).preview?.bundle.files == saved.files)
        }
        var foreign = saved.manifest.ref; foreign.sha256 += "other"
        #expect(model.projection(for: foreign, access: fresh).preview == nil)
        #expect(model.projection(for: saved.manifest.ref, access: old).preview == nil)
        #expect(model.projection(for: saved.manifest.ref, access: .init()).preview == nil)
        #expect(loads == 1 && validations == 0)
        model.close()
        #expect(receipt?.source.isCurrent(with: fresh) == false)
        #expect(model.projection(for: saved.manifest.ref, access: fresh).preview == nil)
        #expect(saved.files["private"] == Data("private text".utf8))
    }

    @Test func freshAuthorizerCannotReviveOriginalBundleAndExplicitReopenUsesFreshSource() {
        let saved = bundle(), id = identity(), model = AskArtifactPreviewModel()
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0
        let original = AskArtifactAccess(load: { _ in reads += 1; return saved },
            imageSource: .init(identity: id, current: { live }))
        model.open(saved.manifest.ref, access: original)
        let receipt = model.projection(for: saved.manifest.ref, access: original).preview
        #expect(receipt != nil)
        let fresh = AskArtifactAccess(imageSource: .init(identity: id, current: { live = nil; return id }))
        #expect(model.projection(for: saved.manifest.ref, access: fresh).preview == nil)
        let authorizer = AskArtifactAccess(imageSource: .init(identity: id, current: { id }))
        #expect(receipt?.source.isCurrent(with: authorizer) == false)
        #expect(model.projection(for: saved.manifest.ref, access: authorizer).error == AskArtifactError.denied.localizedDescription)
        #expect(reads == 1)
        live = id; model.open(saved.manifest.ref, access: original)
        #expect(model.projection(for: saved.manifest.ref, access: original).preview != nil && reads == 2)
        #expect(receipt?.source.isCurrent(with: original) == false, "Reopen cannot revive a closed attempt's receipt")
        model.close()
    }

    @Test(arguments: [false, true]) func staleDeniedEntryPreservesOwnedBundleOrFailure(_ failure: Bool) {
        let saved = bundle(), other = bundle(Data([9])), id = identity(), foreign = identity(), model = AskArtifactPreviewModel()
        var reads = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; if failure { throw AskArtifactError.expired }; return saved },
            imageSource: .init(identity: id, current: { id }))
        model.open(saved.manifest.ref, access: access)
        let before = model.projection(for: saved.manifest.ref, access: access)
        for deniedID in [id, foreign] {
            model.open(other.manifest.ref, access: .init(load: { _ in Issue.record("Denied source read"); return other },
                imageSource: .init(identity: deniedID, current: { nil })))
            let after = model.projection(for: saved.manifest.ref, access: access)
            #expect(after.preview?.bundle.files == before.preview?.bundle.files && after.error == before.error)
        }
        #expect(reads == 1)
        model.close()
    }

    @Test func initialDenialExpiredCorruptAndUnknownErrorsHaveBoundedFallback() {
        let saved = bundle(), other = bundle(Data([9])), id = identity(), model = AskArtifactPreviewModel()
        let denied = AskArtifactAccess(imageSource: .init(identity: id, current: { nil }))
        model.open(saved.manifest.ref, access: denied)
        #expect(model.projection(for: saved.manifest.ref, access: denied).error == AskArtifactError.denied.localizedDescription)
        // A second denied identity can replace an already-revoked owner without reading a file.
        let another = AskArtifactAccess(imageSource: .init(identity: identity(), current: { nil }))
        model.open(saved.manifest.ref, access: another)
        #expect(model.projection(for: saved.manifest.ref, access: another).error == AskArtifactError.denied.localizedDescription)
        for failure in [AskArtifactError.expired, .unavailable] {
            let access = AskArtifactAccess(load: { _ in throw failure })
            model.open(saved.manifest.ref, access: access)
            #expect(model.projection(for: saved.manifest.ref, access: access).error == failure.localizedDescription)
        }
        model.open(saved.manifest.ref, access: .init(load: { _ in other }))
        #expect(model.projection(for: saved.manifest.ref, access: .init()).error == AskArtifactError.corrupt.localizedDescription)
        model.open(saved.manifest.ref, access: .init(load: { _ in throw NSError(domain: "private/path", code: 1) }))
        #expect(model.projection(for: saved.manifest.ref, access: .init()).error == AskArtifactError.unavailable.localizedDescription)
        model.close()
    }

    @Test(arguments: [false, true]) func oldReentrantSourceReturnOrThrowCannotReplaceNewBundle(_ throwsError: Bool) {
        let old = bundle(), fresh = bundle(Data("new".utf8)), model = AskArtifactPreviewModel()
        let freshAccess = AskArtifactAccess(load: { _ in fresh })
        model.open(old.manifest.ref, access: .init(load: { _ in
            model.open(fresh.manifest.ref, access: freshAccess)
            if throwsError { throw AskArtifactError.expired }
            return old
        }))
        #expect(model.projection(for: fresh.manifest.ref, access: freshAccess).preview?.bundle.files == fresh.files)
        #expect(model.projection(for: old.manifest.ref, access: .init()).preview == nil)
        model.close()
    }

    @Test(arguments: [1, 2, 3]) func sourceCallbackRetirementCannotReadOrPublish(_ boundary: Int) {
        let saved = bundle(), id = identity(), model = AskArtifactPreviewModel()
        var checks = 0, reads = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; return saved }, imageSource: .init(identity: id, current: {
            checks += 1; if checks == boundary { model.close() }; return id
        }))
        model.open(saved.manifest.ref, access: access)
        #expect(reads == (boundary == 1 ? 0 : 1))
        #expect(model.projection(for: saved.manifest.ref, access: access).preview == nil)
    }

    @Test func cancellationAtEntrySourceAndTerminalKeepsExistingOwnerOrWithholdsOutput() async {
        let saved = bundle(), id = identity(), model = AskArtifactPreviewModel()
        var reads = 0
        let normal = AskArtifactAccess(load: { _ in reads += 1; return saved })
        model.open(saved.manifest.ref, access: normal)
        let retained = model.projection(for: saved.manifest.ref, access: normal).preview
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            model.open(saved.manifest.ref, access: normal)
            #expect(model.projection(for: saved.manifest.ref, access: normal).preview == nil)
        }
        await canceled.value
        #expect(retained?.source.isCurrent(with: normal) == true && reads == 1)
        for boundary in [1, 2] {
            var checks = 0
            let task = Task {
                let access = AskArtifactAccess(load: { _ in reads += 1; return saved }, imageSource: .init(identity: id, current: {
                    checks += 1; if checks == boundary { withUnsafeCurrentTask { $0?.cancel() } }; return id
                }))
                model.open(saved.manifest.ref, access: access)
            }
            await task.value
        }
        #expect(reads == 2)
        model.close()
        model.open(saved.manifest.ref, access: .init(load: { _ in model.close(); throw AskArtifactError.expired }))
        #expect(model.projection(for: saved.manifest.ref, access: .init()).error == nil)
    }

    @Test func getterCallbacksAndDeniedOriginalCannotRestoreClosedReceipt() {
        let saved = bundle(), id = identity(), model = AskArtifactPreviewModel()
        var retire = false
        let original = AskArtifactAccess(load: { _ in saved }, imageSource: .init(identity: id, current: {
            if retire { model.close() }; return id
        }))
        let fresh = AskArtifactAccess(imageSource: .init(identity: id, current: { id }))
        model.open(saved.manifest.ref, access: original)
        retire = true
        #expect(model.projection(for: saved.manifest.ref, access: fresh).preview == nil)
        retire = false; model.open(saved.manifest.ref, access: original); retire = true
        model.open(saved.manifest.ref, access: .init(imageSource: .init(identity: id, current: { nil })))
        #expect(model.projection(for: saved.manifest.ref, access: fresh).error == nil)
        retire = false; model.open(saved.manifest.ref, access: original)
        let closingFresh = AskArtifactAccess(imageSource: .init(identity: id, current: { model.close(); return id }))
        #expect(model.projection(for: saved.manifest.ref, access: closingFresh).preview == nil)
    }

    @Test func bundleRevokedDuringReadIsRetainedPrivatelyWithoutReopenOrWrite() {
        let saved = bundle(), id = identity(), model = AskArtifactPreviewModel()
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; live = nil; return saved },
            imageSource: .init(identity: id, current: { live }))
        model.open(saved.manifest.ref, access: access)
        #expect(model.projection(for: saved.manifest.ref, access: access).preview == nil)
        for _ in 0..<10 { _ = model.projection(for: saved.manifest.ref, access: access) }
        #expect(reads == 1 && saved.files["private"] == Data("private text".utf8))
        model.close()
    }

    @Test func bodyValuesAndDirectLegacyPreviewDoNoPreparationAcrossAllContentBranches() {
        let id = identity(), otherID = identity()
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0, validations = 0, writes = 0
        let previewModel = AskArtifactPreviewModel()
        let imageModel = AskArtifactImageModel(decode: { _, _ in Issue.record("Body decoded"); throw AskArtifactError.unavailable },
            write: { _, _ in writes += 1; return true })
        let cases = [(Data("text".utf8), "text/plain"), (Data(repeating: 65, count: 200_000), "text/plain"),
                     (Data([255]), "text/plain"), (Data("{}".utf8), "application/json"),
                     (Data("<h1>private</h1>".utf8), "text/html"), (Data([1]), "image/png"), (Data([1]), "application/zip")]
        for (bytes, type) in cases {
            let saved = bundle(bytes, type: type)
            for enabled in [false, true] {
                live = id
                let access = AskArtifactAccess(load: { _ in reads += 1; return saved }, validate: { _ in validations += 1 },
                    htmlEnabled: enabled, imageSource: .init(identity: id, current: { live }))
                previewModel.open(saved.manifest.ref, access: access)
                let receipt = previewModel.projection(for: saved.manifest.ref, access: access).preview!
                let before = reads
                // Values only: never host, render, construct a coordinator, open WebKit or run a task/button.
                _ = AskStoredArtifactCard(ref: saved.manifest.ref, imageModel: imageModel, previewModel: previewModel).body
                _ = AskArtifactPreviewView(bundle: saved, access: access, close: {}, imageModel: imageModel, source: receipt.source).body
                live = otherID
                let fresh = AskArtifactAccess(htmlEnabled: enabled, imageSource: .init(identity: otherID, current: { live }))
                #expect(previewModel.projection(for: saved.manifest.ref, access: fresh).preview == nil)
                _ = AskArtifactPreviewView(bundle: saved, access: fresh, close: {}, imageModel: imageModel, source: receipt.source).body
                #expect(reads == before && validations == 0 && writes == 0)
                previewModel.close()
            }
        }
        let saved = bundle()
        let direct = AskArtifactPreviewView(bundle: saved, access: .init(), close: {}, imageModel: imageModel)
        #expect(direct.source.isCurrent(with: .init()))
        _ = direct.body
        #expect(validations == 0 && writes == 0)
    }

    @Test func actualImageContinuationRefusesClosedForeignCanceledAndRevokedPreviewBeforeRead() async throws {
        let saved = bundle(Data([1, 2, 3]), type: "image/png"), text = bundle(), id = identity()
        let preview = AskArtifactPreviewModel()
        let pixels = AskFilePreviewPDF.Result(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
        var live: AskArtifactImageSource.Identity? = id
        var reads = 0, validations = 0
        let access = AskArtifactAccess(load: { _ in reads += 1; return saved }, validate: { _ in validations += 1 },
            imageSource: .init(identity: id, current: { live }))
        let image = AskArtifactImageModel(decode: { _, _ in pixels }, write: { _, _ in Issue.record("Continuation wrote"); return false })
        preview.open(saved.manifest.ref, access: access)
        let source = try #require(preview.projection(for: saved.manifest.ref, access: access).preview?.source)
        await AskArtifactPreviewView.loadImage(text.manifest.ref, source: source, access: access, model: image)
        await AskArtifactPreviewView.loadImage(saved.manifest.ref, source: source, access: access, model: image)
        #expect(reads == 2 && validations == 2 && image.image != nil)
        preview.close()
        await AskArtifactPreviewView.loadImage(saved.manifest.ref, source: source, access: access, model: image)
        #expect(reads == 2 && validations == 2)
        preview.open(saved.manifest.ref, access: access)
        let reopened = try #require(preview.projection(for: saved.manifest.ref, access: access).preview?.source)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await AskArtifactPreviewView.loadImage(saved.manifest.ref, source: reopened, access: access, model: image)
        }
        await task.value
        live = nil
        let fresh = AskArtifactAccess(imageSource: .init(identity: id, current: { id }))
        await AskArtifactPreviewView.loadImage(saved.manifest.ref, source: reopened, access: fresh, model: image)
        let plain = AskArtifactPreviewSource(ref: text.manifest.ref, access: .init(load: { _ in Issue.record("Text image read"); return text }))
        await AskArtifactPreviewView.loadImage(text.manifest.ref, source: plain, access: .init(), model: image)
        #expect(reads == 3 && validations == 2 && saved.files["private"] == Data([1, 2, 3]))
        image.cancel(); preview.close()
    }
}
