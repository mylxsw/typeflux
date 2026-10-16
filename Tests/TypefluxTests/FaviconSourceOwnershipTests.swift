import AppKit
import Testing
@testable import Typeflux

private final class FaviconSourceState: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0, decodes = 0
    var counts: (Int, Int) { lock.withLock { (loads, decodes) } }
    func load() { lock.withLock { loads += 1 } }
    func decode() { lock.withLock { decodes += 1 } }
}
private actor FaviconSourceGate {
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

@Suite("Favicon source callback ownership", .exclusiveUIState)
@MainActor struct FaviconSourceOwnershipTests {
    private func url(_ name: String = "private") -> URL { URL(string: "https://\(name).test/favicon.ico")! }
    private func pixels() -> CGImage { AskAttachmentFixture.image(width: 2, height: 2) }

    @Test(arguments: [false, true])
    func staleDeniedAndCanceledEntriesPreserveOwnedSuccessOrFailure(failed: Bool) async {
        let scope = AskImagePresentationScope(), foreign = AskImagePresentationScope(), state = FaviconSourceState(), image = pixels()
        var now = Date(timeIntervalSinceReferenceDate: 100), checks = 0
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { checks += 1; return true })
        let cache = AskBrowserFaviconCache(loader: { _ in state.load(); return failed ? nil : Data([1]) }, clock: { now }, decode: { _ in state.decode(); return image })
        let first = await cache.image(url(), access: access)
        #expect((first == nil) == failed)
        for denied in [AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { false }),
                       .init(scope: foreign, epoch: foreign.epoch, authorize: { false }), .init()] {
            #expect(await cache.image(url(), access: denied) == nil)
            #expect(cache.cached(url(), access: access) === first)
        }
        let before = checks
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(url(), access: access)
        }
        #expect(await canceled.value == nil); #expect(checks == before)
        #expect(await cache.image(url(), access: access) === first)
        #expect(state.counts == (1, failed ? 0 : 1), "Stale denial cannot reset the owned failure cooldown")
        now += 60
        _ = await cache.image(url(), access: access)
        #expect(state.counts.0 == (failed ? 2 : 1))
        cache.cancel()
    }

    @Test func cancellationInsideIncomingAccessCannotReplaceCurrentCacheOrStartLoader() async {
        let state = FaviconSourceState(), scope = AskImagePresentationScope(), image = pixels()
        let cache = AskBrowserFaviconCache(loader: { _ in state.load(); return Data([1]) }, decode: { _ in image })
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let snapshot = await cache.image(url(), access: access)
        #expect(snapshot != nil)
        let task = Task {
            await cache.image(url("new"), access: .init(scope: scope, epoch: scope.epoch, authorize: {
                withUnsafeCurrentTask { $0?.cancel() }; return true
            }))
        }
        #expect(await task.value == nil)
        #expect(cache.cached(url(), access: access) === snapshot && state.counts.0 == 1)
        let canceledOwner = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { cache.cancel(); return true })
        #expect(await cache.image(url("new"), access: canceledOwner) == nil)
        #expect(state.counts.0 == 1 && cache.cached(url(), access: access) == nil)
        #expect(await cache.image(url("new"), access: access) != nil)
        #expect(state.counts.0 == 2)
        cache.cancel()
    }

    @Test func originalCallbacksDuringDedupeOrDenialCannotContinueOldEntry() async {
        for denied in [false, true] {
            let scope = AskImagePresentationScope(), state = FaviconSourceState(), image = pixels()
            var revoke: (() -> Void)?
            let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { revoke?(); return true })
            let cache = AskBrowserFaviconCache(loader: { _ in state.load(); return Data([1]) }, decode: { _ in image })
            #expect(await cache.image(url(), access: original) != nil)
            revoke = { cache.cancel() }
            let incoming = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { !denied })
            #expect(await cache.image(url("new"), access: incoming) == nil)
            #expect(state.counts.0 == 1 && cache.cached(url()) == nil)
            revoke = nil
            #expect(await cache.image(url("new"), access: original) != nil)
            #expect(state.counts.0 == 2)
            cache.cancel()
        }
    }

    @Test(arguments: [false, true])
    func accessRetirementAfterBindingStillPreventsPendingAdmission(cancelTask: Bool) async {
        let scope = AskImagePresentationScope(), state = FaviconSourceState(), image = pixels()
        let cache = AskBrowserFaviconCache(loader: { _ in state.load(); return Data([1]) }, decode: { _ in image })
        var calls = 0
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            calls += 1
            if calls == 2 {
                if cancelTask { withUnsafeCurrentTask { $0?.cancel() } }
                else { cache.cancel() }
            }
            return true
        })
        let task = Task { await cache.image(url(), access: access) }
        #expect(await task.value == nil); #expect(calls == 2 && state.counts.0 == 0)
        let fresh = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        #expect(await cache.image(url(), access: fresh) != nil)
        #expect(state.counts.0 == 1)
        cache.cancel()
    }

    @Test func getterRequiresOriginalAuthorityAndExactScopeWithoutStartingWork() async {
        let scope = AskImagePresentationScope(), other = AskImagePresentationScope(), state = FaviconSourceState(), image = pixels()
        var allowed = true
        var revoke: (() -> Void)?
        let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { revoke?(); return allowed })
        let cache = AskBrowserFaviconCache(loader: { _ in state.load(); return Data([1]) }, decode: { _ in state.decode(); return image })
        #expect(await cache.image(url(), access: original) != nil)
        let foreign = AskImagePresentationAccess(scope: other, epoch: scope.epoch, authorize: { Issue.record("Foreign authorizer invoked"); return true })
        #expect(cache.cached(url(), access: foreign) == nil && cache.cached(url()) == nil)
        let fresh = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { allowed = false; return true })
        #expect(cache.cached(url(), access: fresh) == nil)
        #expect(state.counts == (1, 1), "A getter cannot replay preparation")
        let current = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        #expect(cache.cached(url(), access: current) == nil)
        #expect(await cache.image(url(), access: original) == nil)
        allowed = true
        #expect(await cache.image(url(), access: original) != nil)
        revoke = { cache.cancel() }
        #expect(cache.cached(url(), access: current) == nil)
        #expect(state.counts == (2, 2))
        revoke = nil
        #expect(await cache.image(url(), access: original) != nil)
        scope.setVisible(false)
        #expect(cache.cached(url(), access: current) == nil)
        scope.setVisible(true)
        let reopened = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        #expect(await cache.image(url(), access: reopened) != nil)
        let before = state.counts
        #expect(cache.cached(url(), access: .init(scope: scope, epoch: scope.epoch, authorize: { cache.cancel(); return true })) == nil)
        #expect(state.counts == before)
        cache.cancel()
    }

    @Test(arguments: [false, true])
    func terminalCallbackRetirementCannotPublishPixelsOrNegativeCache(failed: Bool) async {
        for mode in ["owner", "scope", "task"] {
            let state = FaviconSourceState(), scope = AskImagePresentationScope(), image = pixels()
            var armed = true
            let cache = AskBrowserFaviconCache(loader: { _ in state.load(); return failed ? nil : Data([1]) }, decode: { _ in state.decode(); return image })
            let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
                if armed && state.counts.0 == 1 {
                    #expect(state.counts.1 == (failed ? 0 : 1))
                    armed = false
                    if mode == "owner" { cache.cancel() }
                    else if mode == "scope" { scope.invalidate() }
                    else { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return true
            })
            let task = Task { await cache.image(url(), access: original) }
            #expect(await task.value == nil); #expect(!armed)
            let current = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
            #expect(cache.cached(url(), access: current) == nil)
            _ = await cache.image(url(), access: current)
            #expect(state.counts.0 == 2, "A retired terminal callback must not leave a failure cooldown or pixels")
            cache.cancel()
        }
    }

    @Test(arguments: [false, true])
    func oldHeldCompletionCannotOverwriteFreshScopeOrKeepOldFailure(failed: Bool) async {
        let state = FaviconSourceState(), gate = FaviconSourceGate(), scope = AskImagePresentationScope(), image = pixels()
        let old = url("old"), fresh = url("fresh")
        let cache = AskBrowserFaviconCache(loader: { site in
            state.load()
            if site == old && state.counts.0 == 1 { await gate.hold(); return failed ? nil : Data([1]) }
            return Data([1])
        }, decode: { _ in state.decode(); return image })
        let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let task = Task { await cache.image(old, access: original) }
        await gate.waitForEntry(); scope.invalidate()
        let current = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let snapshot = await cache.image(fresh, access: current)
        #expect(snapshot != nil)
        await gate.release(); #expect(await task.value == nil)
        #expect(cache.cached(fresh, access: current) === snapshot)
        #expect(await cache.image(old, access: current) != nil)
        #expect(state.counts == (3, 2))
        cache.cancel()
    }
}
