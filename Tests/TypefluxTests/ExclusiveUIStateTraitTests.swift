import Testing

@Suite("Exclusive UI state trait")
struct ExclusiveUIStateTraitTests {
    private struct Failure: Error {}

    private actor Recorder {
        var events: [String] = []
        var running = 0
        var maximumRunning = 0

        func enter(_ name: String) {
            running += 1
            maximumRunning = max(maximumRunning, running)
            events.append("enter \(name)")
        }

        func leave(_ name: String) {
            running -= 1
            events.append("leave \(name)")
        }
    }

    /// Waits until `count` tasks queue on `lock`, so the test controls their arrival order.
    private func waitForWaiters(_ lock: ExclusiveUIStateLock, count: Int) async throws {
        for _ in 0 ..< 1000 {
            if await lock.waiterCount == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for \(count) waiters")
    }

    @Test func casesNeverOverlapAndRunInArrivalOrder() async throws {
        let lock = ExclusiveUIStateLock()
        let recorder = Recorder()
        await lock.acquire()
        var tasks: [Task<Void, Error>] = []
        for name in ["a", "b", "c"] {
            tasks.append(Task {
                try await lock.withLock {
                    await recorder.enter(name)
                    try await Task.sleep(for: .milliseconds(5))
                    await recorder.leave(name)
                }
            })
            try await waitForWaiters(lock, count: tasks.count)
        }
        await lock.release()
        for task in tasks { try await task.value }

        #expect(await recorder.maximumRunning == 1)
        #expect(await recorder.events == ["enter a", "leave a", "enter b", "leave b", "enter c", "leave c"])
        #expect(await !lock.isLocked)
    }

    @Test func nestedScopesOnTheSameLockDoNotWaitForThemselves() async throws {
        let lock = ExclusiveUIStateLock()
        let recorder = Recorder()
        try await lock.withLock {
            try await lock.withLock { await recorder.enter("inner") }
            #expect(await lock.isLocked)
        }
        #expect(await recorder.events == ["enter inner"])
        #expect(await !lock.isLocked)
    }

    @Test func holdingOneLockStillWaitsForAnother() async throws {
        let outer = ExclusiveUIStateLock()
        let inner = ExclusiveUIStateLock()
        await inner.acquire()
        let task = Task {
            try await outer.withLock { try await inner.withLock {} }
        }
        try await waitForWaiters(inner, count: 1)
        #expect(await outer.isLocked)
        await inner.release()
        try await task.value
        #expect(await !outer.isLocked)
        #expect(await !inner.isLocked)
    }

    @Test func aThrowingCaseReleasesTheLockForTheNextOne() async throws {
        let lock = ExclusiveUIStateLock()
        await #expect(throws: Failure.self) {
            try await lock.withLock { throw Failure() }
        }
        #expect(await !lock.isLocked)
        let recorder = Recorder()
        try await lock.withLock { await recorder.enter("next") }
        #expect(await recorder.events == ["enter next"])
    }

    @Test func traitScopesEachCaseButNotTheWholeSuite() async throws {
        let lock = ExclusiveUIStateLock()
        let trait = ExclusiveUIStateTrait(lock: lock)
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        #expect(trait.isRecursive)
        #expect(trait.scopeProvider(for: test, testCase: nil) == nil)
        #expect(trait.scopeProvider(for: test, testCase: testCase) != nil)

        let recorder = Recorder()
        try await trait.provideScope(for: test, testCase: testCase) {
            await recorder.enter(await lock.isLocked ? "locked" : "unlocked")
        }
        #expect(await recorder.events == ["enter locked"])
        #expect(await !lock.isLocked)
        await #expect(throws: Failure.self) {
            try await trait.provideScope(for: test, testCase: testCase) { throw Failure() }
        }
        #expect(await !lock.isLocked)
    }
}
