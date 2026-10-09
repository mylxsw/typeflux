import Foundation
import Testing
@testable import Typeflux

/// `L()` reads the process-wide `AppLocalization.shared.language`, and tests that switch it hold
/// `.exclusiveUIState`. A test that reads localized text without the trait can run while a writer
/// holds the lock and see the other language, whatever `interface:` value it passes elsewhere.
@Suite("Global language isolation", .serialized, .exclusiveUIState)
struct ExclusiveUIStateLanguageTests {
    /// A one-way signal whose `wait()` throws when the waiting task is cancelled, so no exit of a
    /// test can hang on it.
    private actor Gate {
        private(set) var isOpen = false
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

        func signal() {
            isOpen = true
            let parked = waiters.values
            waiters.removeAll()
            parked.forEach { $0.resume() }
        }

        func wait() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if isOpen {
                        continuation.resume()
                    } else if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    /// Records reads and task completions synchronously, so a task's `defer` can report it.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var values: [String] { lock.withLock { stored } }
        func append(_ value: String) { lock.withLock { stored.append(value) } }
        /// The reads without the completion markers.
        var texts: [String] { values.filter { !$0.hasSuffix(" done") } }
    }

    private struct Failure: Error {}
    private struct ReaderNeverQueued: Error {}
    private let key = "ask.voice.input"

    /// The key's text in both languages, leaving the global language as it was.
    private func texts(original: AppLanguage, switched: AppLanguage) -> (original: String, switched: String) {
        defer { AppLocalization.shared.setLanguage(original) }
        let originalText = L(key)
        AppLocalization.shared.setLanguage(switched)
        return (originalText, L(key))
    }

    /// A writer switches the language while holding `lock`, then a reader queues behind it.
    /// `whileQueued` runs once the reader waits for the lock. Every exit (normal, a throwing
    /// `whileQueued`, or cancellation of the calling task) lets the writer restore the language
    /// and joins both tasks before this returns or rethrows.
    private func raceWriterAndReader(
        on lock: ExclusiveUIStateLock, original: AppLanguage, switched: AppLanguage, reads: Reads,
        whileQueued: () async throws -> Void
    ) async throws {
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        let trait = ExclusiveUIStateTrait(lock: lock)
        let key = key
        let writerSwitched = Gate(), writerMayRestore = Gate()
        var tasks: [Task<Void, Error>] = []
        do {
            tasks.append(Task {
                defer { reads.append("writer done") }
                try await trait.provideScope(for: test, testCase: testCase) {
                    AppLocalization.shared.setLanguage(switched)
                    defer { AppLocalization.shared.setLanguage(original) }
                    await writerSwitched.signal()
                    try await writerMayRestore.wait()
                }
            })
            try await writerSwitched.wait()
            reads.append("unlocked: " + L(key))
            tasks.append(Task {
                defer { reads.append("reader done") }
                try await trait.provideScope(for: test, testCase: testCase) {
                    reads.append("locked: " + L(key))
                }
            })
            var polls = 0
            while await lock.waiterCount == 0 {
                guard polls < 1000 else { throw ReaderNeverQueued() }
                polls += 1
                try await Task.sleep(for: .milliseconds(1))
            }
            try await whileQueued()
            await writerMayRestore.signal()
            for task in tasks { try await task.value }
        } catch {
            await writerMayRestore.signal()
            tasks.forEach { $0.cancel() }
            for task in tasks { _ = await task.result }
            throw error
        }
    }

    /// After any exit both tasks have finished, the lock is free with nobody queued, and the
    /// global language is back to `original`.
    private func expectCleanedUp(_ lock: ExclusiveUIStateLock, _ reads: Reads, original: AppLanguage) async {
        #expect(Set(reads.values.filter { $0.hasSuffix(" done") }) == ["writer done", "reader done"])
        #expect(await !lock.isLocked)
        #expect(await lock.waiterCount == 0)
        #expect(AppLocalization.shared.language == original)
    }

    @Test func aLockedReaderWaitsForTheLanguageWriterWhileAnUnlockedReaderSeesTheSwitch() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        let switched: AppLanguage = original == .english ? .simplifiedChinese : .english
        let text = texts(original: original, switched: switched)
        #expect(text.switched != text.original)

        // A private lock stands in for the shared one, which this suite already holds.
        let lock = ExclusiveUIStateLock()
        let reads = Reads()
        try await raceWriterAndReader(on: lock, original: original, switched: switched, reads: reads) {
            #expect(await lock.isLocked)
            #expect(await lock.waiterCount == 1)
            #expect(reads.texts == ["unlocked: " + text.switched])
        }
        #expect(reads.texts == ["unlocked: " + text.switched, "locked: " + text.original])
        await expectCleanedUp(lock, reads, original: original)
    }

    @Test func aFailureWhileTheReaderIsQueuedStillRestoresTheLanguageAndJoinsBothTasks() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        let switched: AppLanguage = original == .english ? .simplifiedChinese : .english
        let text = texts(original: original, switched: switched)
        let lock = ExclusiveUIStateLock()
        let reads = Reads()

        await #expect(throws: Failure.self) {
            try await raceWriterAndReader(on: lock, original: original, switched: switched, reads: reads) {
                #expect(await lock.isLocked)
                #expect(await lock.waiterCount == 1)
                throw Failure()
            }
        }
        #expect(reads.texts == ["unlocked: " + text.switched, "locked: " + text.original])
        await expectCleanedUp(lock, reads, original: original)
    }

    /// Runs the race in its own task, so a cancel can arrive from outside it, and waits until the
    /// reader is queued. `beforeQueued` runs inside the race just before it reports that, and
    /// `whileQueued` runs here once it has; then the race is cancelled and its result returned.
    /// Every exit of this function (normal, a throwing `whileQueued`, cancellation of the caller,
    /// or a race that ends before the reader queues, which also ends the wait) cancels the race if
    /// it is still running and joins it first.
    private func cancelRaceOnceQueued(
        on lock: ExclusiveUIStateLock, original: AppLanguage, switched: AppLanguage, reads: Reads,
        beforeQueued: @escaping @Sendable () async throws -> Void = {},
        whileQueued: () async throws -> Void = {}
    ) async throws -> Result<Void, Error> {
        let queued = Gate(), raceEnded = Gate()
        let race = Task {
            do {
                try await raceWriterAndReader(on: lock, original: original, switched: switched, reads: reads) {
                    try await beforeQueued()
                    await queued.signal()
                    try await Task.sleep(for: .seconds(60))
                }
            } catch {
                await raceEnded.signal()
                await queued.signal()
                throw error
            }
        }
        do {
            try await queued.wait()
            if await raceEnded.isOpen { return await race.result }
            try await whileQueued()
        } catch {
            race.cancel()
            _ = await race.result
            throw error
        }
        race.cancel()
        return await race.result
    }

    @Test func cancellingTheTestWhileTheReaderIsQueuedStillRestoresTheLanguageAndJoinsBothTasks() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        let switched: AppLanguage = original == .english ? .simplifiedChinese : .english
        let text = texts(original: original, switched: switched)
        let lock = ExclusiveUIStateLock()
        let reads = Reads()

        let result = try await cancelRaceOnceQueued(
            on: lock, original: original, switched: switched, reads: reads,
            whileQueued: {
                // The writer still holds the lock and the reader still waits when the cancel arrives.
                #expect(await lock.isLocked)
                #expect(await lock.waiterCount == 1)
                #expect(AppLocalization.shared.language == switched)
            }
        )
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(reads.texts == ["unlocked: " + text.switched, "locked: " + text.original])
        await expectCleanedUp(lock, reads, original: original)
    }

    @Test func cancellingTheCallerWhileItWaitsForTheQueuedReaderCancelsAndJoinsTheRace() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        let switched: AppLanguage = original == .english ? .simplifiedChinese : .english
        let text = texts(original: original, switched: switched)
        let lock = ExclusiveUIStateLock()
        let reads = Reads()
        let held = Gate()

        // The race queues the reader but never reports it, so the caller is still waiting for
        // readiness (or about to) when it is cancelled; either way its wait throws.
        let caller = Task {
            try await cancelRaceOnceQueued(
                on: lock, original: original, switched: switched, reads: reads,
                beforeQueued: {
                    await held.signal()
                    try await Task.sleep(for: .seconds(60))
                },
                whileQueued: { Issue.record("The caller must not get past the readiness wait") }
            )
        }
        try await held.wait()
        #expect(await lock.isLocked)
        #expect(await lock.waiterCount == 1)
        #expect(AppLocalization.shared.language == switched)
        caller.cancel()
        let result = await caller.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(reads.texts == ["unlocked: " + text.switched, "locked: " + text.original])
        await expectCleanedUp(lock, reads, original: original)
    }

    @Test func aFailureWhileTheCallerWaitsForTheQueuedReaderCancelsAndJoinsTheRace() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        let switched: AppLanguage = original == .english ? .simplifiedChinese : .english
        let text = texts(original: original, switched: switched)
        let lock = ExclusiveUIStateLock()
        let reads = Reads()

        await #expect(throws: Failure.self) {
            _ = try await cancelRaceOnceQueued(
                on: lock, original: original, switched: switched, reads: reads,
                whileQueued: {
                    #expect(await lock.isLocked)
                    #expect(await lock.waiterCount == 1)
                    throw Failure()
                }
            )
        }
        #expect(reads.texts == ["unlocked: " + text.switched, "locked: " + text.original])
        await expectCleanedUp(lock, reads, original: original)
    }

    @Test func aRaceThatFailsBeforeTheReaderIsReportedQueuedEndsTheCallersWait() async throws {
        let original = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(original) }
        let switched: AppLanguage = original == .english ? .simplifiedChinese : .english
        let text = texts(original: original, switched: switched)
        let lock = ExclusiveUIStateLock()
        let reads = Reads()

        let result = try await cancelRaceOnceQueued(
            on: lock, original: original, switched: switched, reads: reads,
            beforeQueued: { throw Failure() },
            whileQueued: { Issue.record("A failed race must not be reported queued") }
        )
        #expect(throws: Failure.self) { try result.get() }
        #expect(reads.texts == ["unlocked: " + text.switched, "locked: " + text.original])
        await expectCleanedUp(lock, reads, original: original)
    }
}

extension ExclusiveUIStateLanguageTests {
    /// Every Swift Testing suite that reads localized text, switches the language, or runs on the
    /// main actor must share the lock. Extensions in other files count toward the suite they extend.
    @Test func everySuiteThatReadsTheGlobalLanguageIsExclusive() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var sources: [String: [String]] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            if lines.contains("import Testing") { sources[file.lastPathComponent] = lines }
        }
        #expect(sources.count > 100, "The audit must see the Swift Testing sources")

        let readsLanguage = try NSRegularExpression(pattern: #"\bL\(|AppLocalization|\binterface:\s*\."#)
        let testAttribute = try NSRegularExpression(pattern: #"(?m)^\s+@Test\b"#)
        let modifiers = #"(?:(?:private|fileprivate|internal|public|final)\s+)*"#
        let declaration = try NSRegularExpression(
            pattern: #"^(?:@MainActor\s+)?"# + modifiers + #"(?:struct|class|enum|actor)\s+(\w+)"#)
        let extensionHeader = try NSRegularExpression(pattern: #"^(?:private\s+)?extension\s+(\w+)"#)
        func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        func name(_ expression: NSRegularExpression, _ line: String) -> String? {
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range])
        }
        func body(_ lines: [String], after index: Int) -> String {
            lines[(index + 1)...].prefix { !$0.hasPrefix("}") }.joined(separator: "\n")
        }

        var extensionBodies: [String: [String]] = [:]
        for lines in sources.values {
            for (index, line) in lines.enumerated() {
                if let extended = name(extensionHeader, line) {
                    extensionBodies[extended, default: []].append(body(lines, after: index))
                }
            }
        }
        var missing: [String] = []
        for (file, lines) in sources {
            for (index, line) in lines.enumerated() {
                guard let type = name(declaration, line) else { continue }
                let attributes = lines[..<index].reversed().prefix { $0.hasPrefix("@") || $0.hasPrefix("//") }
                let suiteLines = attributes.filter { $0.hasPrefix("@Suite") }
                let bodies = [body(lines, after: index)] + extensionBodies[type, default: []]
                let isSuite = !suiteLines.isEmpty || bodies.contains { matches(testAttribute, $0) }
                let isMainActor = line.hasPrefix("@MainActor") || attributes.contains { $0.hasPrefix("@MainActor") }
                guard isSuite, isMainActor || bodies.contains(where: { matches(readsLanguage, $0) }) else { continue }
                if !suiteLines.contains(where: { $0.contains(".exclusiveUIState") }) {
                    missing.append("\(file): \(type)")
                }
            }
        }
        #expect(missing.sorted() == [], "Add .exclusiveUIState to these suites")
    }
}
