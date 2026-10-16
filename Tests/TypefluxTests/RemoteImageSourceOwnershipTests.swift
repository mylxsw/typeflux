import AppKit
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private actor RemoteSourceTransport: AskImageTransport {
    private(set) var sends = 0
    private var held = false
    private var pending: CheckedContinuation<Data, Never>?
    func holdNext() { held = true }
    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        sends += 1
        if held {
            held = false
            return await withCheckedContinuation { pending = $0 }
        }
        return Data([1])
    }
    var waiting: Bool { pending != nil }
    func release() { pending?.resume(returning: Data([1])); pending = nil }
}

@Suite("Remote image source ownership", .exclusiveUIState)
@MainActor struct RemoteImageSourceOwnershipTests {
    private let asset = AskGeneratedImage(assetId: "original", url: "https://private.invalid/image?signed=fixture")
    private let fresh = AskGeneratedImage(assetId: "fresh", url: "https://private.invalid/fresh")
    private func access(_ scope: AskRemoteImageScope) -> AskRemoteImageAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func model(_ transport: RemoteSourceTransport, budget: AskToolPixelBudget = .shared) -> AskRemoteImageModel {
        let pixels = AskAttachmentFixture.image(width: 2, height: 2)
        return .init(loader: .init(transport: transport, decode: { _ in
            .init(images: [pixels], numbers: [], pages: 0)
        }), budget: budget)
    }
    private func entered(_ transport: RemoteSourceTransport) async {
        let end = ContinuousClock.now + .seconds(5)
        while !(await transport.waiting), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await transport.waiting)
    }

    @Test func canceledEntryCannotClearCompletedOrFailedNewerProjection() async throws {
        let transport = RemoteSourceTransport(), scope = AskRemoteImageScope(), model = model(transport)
        let access = access(scope)
        await model.load(fresh, access: access)
        let snapshot = try #require(model.displayed(fresh, access: access))
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(asset, access: access)
        }
        await canceled.value
        #expect(model.image === snapshot && model.source == fresh && !model.unavailable)
        #expect(await transport.sends == 1)
        let failed = AskRemoteImageModel(loader: .init(transport: transport, decode: { _ in throw MediaFailure.unreadable }))
        await failed.load(asset, access: access)
        #expect(failed.unavailable)
        await failed.load(fresh, access: .init())
        #expect(failed.unavailable && failed.source == asset)
        let late = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await failed.load(fresh, access: access)
        }
        await late.value
        #expect(failed.unavailable && failed.image == nil)
        #expect(await transport.sends == 2)
        scope.invalidate()
    }

    @Test func staleDeniedEpochScopeAndSameEpochAuthorityCannotCancelNewPixels() async throws {
        let transport = RemoteSourceTransport(), scope = AskRemoteImageScope(), model = model(transport)
        let old = access(scope)
        scope.invalidate()
        await model.load(fresh, access: access(scope))
        let snapshot = try #require(model.image)
        let denied = AskRemoteImageAccess(scope: scope, epoch: scope.epoch, authorize: { false })
        let other = AskRemoteImageScope()
        for stale in [old, denied, AskRemoteImageAccess(scope: other, epoch: other.epoch, authorize: { false }), .init()] {
            await model.load(asset, access: stale)
            #expect(model.image === snapshot && model.source == fresh && !model.unavailable)
        }
        #expect(await transport.sends == 1)
        #expect(model.displayed(asset, access: access(scope)) == nil)
        // Even a coincident epoch from another scope cannot bless this projection.
        #expect(model.displayed(fresh, access: .init(scope: other, epoch: scope.epoch, authorize: { true })) == nil)
        scope.invalidate()
    }

    @Test func projectionRetainsOriginalAccessAndExplicitReloadCanReplaceIt() async throws {
        let transport = RemoteSourceTransport(), scope = AskRemoteImageScope(), model = model(transport)
        var originalAllowed = true
        let original = AskRemoteImageAccess(scope: scope, epoch: scope.epoch, authorize: { originalAllowed })
        await model.load(asset, access: original)
        #expect(model.displayed(asset, access: original) != nil)
        originalAllowed = false
        let freshAccess = access(scope)
        for _ in 0..<10 { #expect(model.displayed(asset, access: freshAccess) == nil) }
        #expect(await transport.sends == 1, "Projection reads never retry")
        await model.load(asset, access: original)
        #expect(model.image == nil && !model.unavailable)
        #expect(await transport.sends == 1)
        await model.load(asset, access: freshAccess)
        #expect(model.displayed(asset, access: freshAccess) != nil)
        #expect(await transport.sends == 2)
        scope.setVisible(false)
        #expect(model.image == nil && model.displayed(asset, access: freshAccess) == nil)
        scope.setVisible(true)
        await model.load(asset, access: access(scope))
        #expect(model.image != nil)
        #expect(await transport.sends == 3)
        #expect(asset.safeURL?.query == "signed=fixture")
        scope.invalidate()
    }

    @Test func canceledDuringEntryAuthorizationDoesNotReplaceCurrentSnapshot() async throws {
        let transport = RemoteSourceTransport(), scope = AskRemoteImageScope(), model = model(transport)
        await model.load(fresh, access: access(scope))
        let snapshot = try #require(model.image)
        let canceling = AskRemoteImageAccess(scope: scope, epoch: scope.epoch, authorize: {
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        })
        let task = Task { await model.load(asset, access: canceling) }
        await task.value
        #expect(model.image === snapshot && model.source == fresh)
        #expect(await transport.sends == 1)
        scope.invalidate()
    }

    @Test func queuedOldCompletionAndDeniedEntryCannotClearReplacement() async throws {
        let transport = RemoteSourceTransport(), scope = AskRemoteImageScope(), model = model(transport)
        let oldAccess = access(scope)
        await transport.holdNext()
        let old = Task { await model.load(asset, access: oldAccess) }
        await entered(transport)
        scope.invalidate()
        let freshAccess = access(scope)
        await model.load(fresh, access: freshAccess)
        let snapshot = model.displayed(fresh, access: freshAccess)
        #expect(snapshot != nil)
        await model.load(asset, access: oldAccess)
        await transport.release(); await old.value
        #expect(model.image === snapshot && model.source == fresh && !model.unavailable)
        #expect(await transport.sends == 2)
        scope.invalidate()
    }

    @Test func revokedOriginalResultIsWithheldAndDeniedEmptyEntryDoesNoWork() async throws {
        let transport = RemoteSourceTransport(), scope = AskRemoteImageScope(), model = model(transport)
        await model.load(asset, access: .init())
        #expect(model.image == nil && model.source == nil && !model.unavailable)
        #expect(await transport.sends == 0)
        var allowed = true
        let original = AskRemoteImageAccess(scope: scope, epoch: scope.epoch, authorize: { allowed })
        await transport.holdNext()
        let pending = Task { await model.load(asset, access: original) }
        await entered(transport); allowed = false
        await transport.release(); await pending.value
        #expect(model.image == nil && !model.unavailable)
        #expect(await transport.sends == 1)
        await model.load(asset, access: access(scope))
        #expect(model.displayed(asset, access: access(scope)) != nil)
        #expect(await transport.sends == 2)
        model.cancel()
        #expect(model.displayed(asset, access: access(scope)) == nil)
    }
}
