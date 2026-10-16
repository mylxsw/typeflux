import AppKit
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class ContextOwnershipState: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0, fails = false
    var count: Int { lock.withLock { calls } }
    func fail(_ value: Bool) { lock.withLock { fails = value } }
    func run() -> Bool { lock.withLock { calls += 1; return fails } }
}
private actor ContextOwnershipGate {
    private var pending: CheckedContinuation<Void, Never>?
    var waiting: Bool { pending != nil }
    func wait() async { await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
}

@Suite("Context image source ownership", .exclusiveUIState)
@MainActor struct ContextImageSourceOwnershipTests {
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func result() -> AskFilePreviewPDF.Result {
        .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
    private func model(_ state: ContextOwnershipState) -> AskContextImageModel {
        let pixels = result()
        return .init(maximumEdge: 2, decode: { _ in
            if state.run() { throw MediaFailure.unreadable }
            return pixels
        })
    }
    private func entered(_ gate: ContextOwnershipGate) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.waiting), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.waiting)
    }

    @Test func staleDeniedSameEpochAndForeignScopeCannotClearSuccessOrFailure() async throws {
        for failed in [false, true] {
            let state = ContextOwnershipState(), scope = AskImagePresentationScope(), other = AskImagePresentationScope()
            state.fail(failed); let model = model(state), original = access(scope)
            await model.load("fresh", access: original)
            let snapshot = model.image
            #expect(failed ? model.unavailable : snapshot != nil)
            let stale = [AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { false }),
                         AskImagePresentationAccess(scope: other, epoch: other.epoch, authorize: { false }), .init()]
            for denied in stale {
                await model.load("old", access: denied)
                #expect(model.image === snapshot && model.unavailable == failed)
            }
            let invalidatingForeign = AskImagePresentationAccess(scope: other, epoch: other.epoch, authorize: { other.invalidate(); return true })
            await model.load("old", access: invalidatingForeign)
            #expect(model.image === snapshot && model.unavailable == failed)
            await model.load("fresh", access: original)
            #expect(state.count == 1, "Success and failed identities both deduplicate")
            #expect(model.displayed("different", access: original) == nil)
            #expect(model.displayed("fresh", access: .init(scope: other, epoch: scope.epoch, authorize: { true })) == nil)
            await model.load(nil, access: original)
            #expect(model.image == nil && !model.unavailable && state.count == 1)
        }
    }

    @Test func canceledBeforeOrInsideEntryAccessCannotReplaceOwnedState() async throws {
        for failed in [false, true] {
            let state = ContextOwnershipState(), scope = AskImagePresentationScope(); state.fail(failed)
            let model = model(state), original = access(scope)
            await model.load("fresh", access: original); let snapshot = model.image
            let before = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await model.load(nil, access: original)
            }
            await before.value
            let during = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
                withUnsafeCurrentTask { $0?.cancel() }; return true
            })
            let task = Task { await model.load("old", access: during) }; await task.value
            #expect(model.image === snapshot && model.unavailable == failed && state.count == 1)
            scope.invalidate()
        }
    }

    @Test func callbacksInvalidatingEntryOriginalOrDeduplicationCannotAuthorizeMoreWork() async throws {
        for boundary in ["entry", "denied-original", "dedupe-original"] {
            let state = ContextOwnershipState(), scope = AskImagePresentationScope(), model = model(state)
            var armed = false
            let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
                if armed { model.cancel() }
                return true
            })
            await model.load("fresh", access: original); #expect(model.image != nil)
            if boundary == "entry" {
                let incoming = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { model.cancel(); return true })
                await model.load("old", access: incoming)
            } else {
                armed = true
                let incoming = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { boundary != "denied-original" })
                await model.load("fresh", access: incoming)
            }
            #expect(model.image == nil && !model.unavailable && state.count == 1)
            await model.load("reopened", access: access(scope))
            #expect(model.image != nil && state.count == 2)
            scope.invalidate()
        }
    }

    @Test func projectionRetainsOriginalAccessAndRejectsCallbackInvalidation() async throws {
        let state = ContextOwnershipState(), scope = AskImagePresentationScope(), model = model(state)
        var allowed = true, cancelOriginal = false
        let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            if cancelOriginal { model.cancel() }
            return allowed
        })
        await model.load("private", access: original)
        #expect(model.displayed("private", access: original) != nil)
        let revokingFresh = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { allowed = false; return true })
        #expect(model.displayed("private", access: revokingFresh) == nil)
        allowed = false
        for _ in 0..<10 { #expect(model.displayed("private", access: access(scope)) == nil) }
        #expect(state.count == 1)
        await model.load("private", access: original)
        #expect(model.image == nil && !model.unavailable && state.count == 1)
        allowed = true; await model.load("private", access: original)
        cancelOriginal = true
        #expect(model.displayed("private", access: access(scope)) == nil)
        #expect(model.image == nil && state.count == 2)
        cancelOriginal = false; await model.load("private", access: original)
        let canceling = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { model.cancel(); return true })
        #expect(model.displayed("private", access: canceling) == nil)
        #expect(model.image == nil && state.count == 3)
        scope.invalidate()
    }

    @Test(arguments: ["owner", "task", "scope"])
    func terminalCallbacksCannotPublishPixelsOrRestoreOldFailure(_ cancellation: String) async throws {
        for failed in [false, true] {
            let state = ContextOwnershipState(), scope = AskImagePresentationScope(); state.fail(failed)
            let model = model(state); var checks = 0
            let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
                checks += 1
                if checks == 2 {
                    #expect(state.count == 1, "The actual custom decoder has returned before terminal access")
                    switch cancellation {
                    case "owner": model.cancel()
                    case "task": withUnsafeCurrentTask { $0?.cancel() }
                    default: scope.setVisible(false)
                    }
                }
                return true
            })
            let task = Task { await model.load("old", access: original) }; await task.value
            #expect(model.image == nil && !model.unavailable && state.count == 1)
            scope.setVisible(true); state.fail(false)
            await model.load("fresh", access: access(scope))
            #expect(model.image != nil && state.count == 2)
            scope.invalidate()
        }
    }

    @Test func heldOldSuccessOrFailureCannotClearReplacementAndKeepsPixelLease() async throws {
        for failed in [false, true] {
            let state = ContextOwnershipState(), scope = AskImagePresentationScope(), gate = ContextOwnershipGate(), pixels = result()
            let budget = AskToolPixelBudget(limit: 32)
            let model = AskContextImageModel(budget: budget, maximumEdge: 2, decode: { value in
                _ = state.run()
                if value == "old" { await gate.wait(); if failed { throw MediaFailure.unreadable } }
                return pixels
            })
            let original = access(scope)
            let old = Task { await model.load("old", access: original) }; await entered(gate)
            scope.invalidate()
            await model.load("fresh", access: access(scope)); let snapshot = model.image
            #expect(snapshot != nil && state.count == 2)
            let third = AskContextImageModel(budget: budget, maximumEdge: 2, decode: { _ in pixels })
            await third.load("third", access: access(scope))
            #expect(third.unavailable, "Old uncooperative decoder still owns its pixels")
            await model.load("old", access: original)
            await gate.release(); await old.value
            #expect(model.image === snapshot && !model.unavailable && state.count == 2)
            third.cancel(); await third.load("third", access: access(scope))
            #expect(third.image != nil)
            scope.invalidate()
        }
    }

    @Test func failedIdentityNeverRetriesFromFreshAccessGettersOrBodyLikeReloads() async throws {
        let state = ContextOwnershipState(), scope = AskImagePresentationScope(); state.fail(true)
        let model = model(state)
        await model.load("same", access: access(scope)); #expect(model.unavailable && state.count == 1)
        state.fail(false)
        for _ in 0..<10 {
            #expect(model.displayed("same", access: access(scope)) == nil)
            await model.load("same", access: access(scope))
        }
        #expect(model.unavailable && state.count == 1)
        scope.setVisible(false); #expect(!model.unavailable)
        scope.setVisible(true); await model.load("same", access: access(scope))
        #expect(model.image != nil && state.count == 2)
        model.cancel(); await model.load("same", access: access(scope))
        #expect(model.image != nil && state.count == 3)
        scope.invalidate()
    }
}
