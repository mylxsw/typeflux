import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class OwnedOCRActions: ClipboardContentActing {
    var bindings = 0, calls = 0, permitChecks = 0
    var onBinding: @MainActor () -> Void = {}
    var current: @MainActor () -> Bool = { true }
    var read: @MainActor () async throws -> String? = { "owned" }
    @MainActor func textRecognition(in url: URL) -> ClipboardTextRecognition {
        bindings += 1; onBinding()
        return .init(recognize: { self.calls += 1; return try await self.read() }, isCurrent: {
            self.permitChecks += 1; return self.current()
        })
    }
    func recognizeText(in imageURL: URL) async throws -> String? { Issue.record("Unbound recognition"); return nil }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool { Issue.record("Unexpected image write"); return false }
    func sendPasteShortcut() { Issue.record("Unexpected paste") }
    func revealInFinder(_ urls: [URL]) { Issue.record("Unexpected reveal") }
    func saveToDownloads(_ url: URL) -> URL? { Issue.record("Unexpected export"); return nil }
}

@Suite("Clipboard OCR source callback ownership", .exclusiveUIState)
@MainActor struct ClipboardOCRSourceOwnershipTests {
    private func file(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("private-input"); try Data([1, 2, 3]).write(to: url); return url
    }
    private func wait(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preCanceledAndRetiredEntryCallbacksNeverBindRecognition() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root)
        for mode in ["preCanceled", "owner", "task", "shutdown"] {
            let action = ClipboardContentAction(), actions = OwnedOCRActions(); var checks = 0, commits = 0, failures = 0
            let pending = Task {
                if mode == "preCanceled" { withUnsafeCurrentTask { $0?.cancel() } }
                return action.startText(url: url, actions: actions, authorized: {
                    checks += 1
                    if mode == "owner" { action.cancel() }
                    if mode == "task" { withUnsafeCurrentTask { $0?.cancel() } }
                    if mode == "shutdown" { action.preventNewWork() }
                    return true
                }, commit: { _ in commits += 1 }, failed: { failures += 1 })
            }
            #expect(await pending.value == false)
            #expect(checks == (mode == "preCanceled" ? 0 : 1))
            #expect(!action.isRunning && actions.bindings == 0 && actions.calls == 0 && commits == 0 && failures == 0)
            if mode != "shutdown" {
                #expect(action.startText(url: url, actions: actions, authorized: { true },
                    commit: { _ in commits += 1 }, failed: { failures += 1 }))
                await wait { !action.isRunning }; #expect(commits == 1 && failures == 0)
            }
        }
    }

    @Test(arguments: ["authorization", "factory", "permit"])
    func nestedAcceptedRequestCannotBeOverwrittenByOldEntry(_ stage: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), action = ClipboardContentAction(), old = OwnedOCRActions(), fresh = OwnedOCRActions()
        var oldCommits = 0, newCommits = 0, failures = 0, nestedAccepted = false
        func replace() {
            nestedAccepted = action.startText(url: url, actions: fresh, authorized: { true },
                commit: { _ in newCommits += 1 }, failed: { failures += 1 })
        }
        if stage == "factory" { old.onBinding = replace }
        if stage == "permit" { old.current = { replace(); return true } }
        let accepted = action.startText(url: url, actions: old, authorized: {
            if stage == "authorization" { replace() }; return true
        }, commit: { _ in oldCommits += 1 }, failed: { failures += 1 })
        #expect(!accepted && nestedAccepted && action.isRunning)
        await wait { !action.isRunning }
        #expect(old.calls == 0 && oldCommits == 0 && fresh.bindings == 1 && fresh.calls == 1 && newCommits == 1 && failures == 0)
    }

    @Test(arguments: ["factory", "permit"])
    func canceledBindingCannotPrepareSourceOrQueueRecognition(_ stage: String) async throws {
        // Missing source distinguishes rejection at the callback from an admitted IO failure.
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let action = ClipboardContentAction(), actions = OwnedOCRActions(); var commits = 0, failures = 0
        if stage == "factory" { actions.onBinding = { action.cancel() } }
        else { actions.current = { action.cancel(); return true } }
        #expect(!action.startText(url: root.appendingPathComponent("missing"), actions: actions, authorized: { true },
            commit: { _ in commits += 1 }, failed: { failures += 1 }))
        #expect(!action.isRunning && actions.bindings == 1 && actions.calls == 0 && commits == 0 && failures == 0)
        #expect(actions.permitChecks == (stage == "factory" ? 0 : 1))
    }

    @Test func canceledQueuedRequestCannotRecognizeAndFreshRequestStillCommits() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), action = ClipboardContentAction(), actions = OwnedOCRActions(); var values: [String?] = [], failures = 0
        func start() -> Bool { action.startText(url: url, actions: actions, authorized: { true },
            commit: { values.append($0) }, failed: { failures += 1 }) }
        #expect(start()); action.cancel(); #expect(!start() && action.isRunning)
        await wait { !action.isRunning }
        #expect(actions.bindings == 1 && actions.calls == 0 && values.isEmpty && failures == 0)
        #expect(start()); await wait { !action.isRunning }
        #expect(values == ["owned"] && actions.calls == 1 && failures == 0)
    }

    @Test(arguments: ["owner", "task", "shutdown"])
    func finalAuthorizationRetirementCannotCommitValidText(_ mode: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), action = ClipboardContentAction(), actions = OwnedOCRActions()
        var checks = 0, commits = 0, failures = 0
        let accepted = action.startText(url: url, actions: actions, authorized: {
            checks += 1
            if checks == 2 {
                #expect(actions.calls == 1 && actions.permitChecks == 1)
                if mode == "owner" { action.cancel() }
                if mode == "task" { withUnsafeCurrentTask { $0?.cancel() } }
                if mode == "shutdown" { action.preventNewWork() }
            }
            return true
        }, commit: { _ in commits += 1 }, failed: { failures += 1 })
        #expect(accepted); await wait { !action.isRunning }
        #expect(commits == 0 && failures == 0 && actions.calls == 1 && actions.permitChecks == 1)
    }

    @Test(arguments: [false, true]) func terminalPermitCallbackCannotRestoreRetiredCommit(_ available: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), action = ClipboardContentAction(), actions = OwnedOCRActions(); var values: [String?] = [], failures = 0
        actions.current = {
            if actions.permitChecks == 2 { #expect(actions.calls == 1); action.cancel(); return available }
            return true
        }
        #expect(action.startText(url: url, actions: actions, authorized: { true },
            commit: { values.append($0) }, failed: { failures += 1 }))
        await wait { !action.isRunning }
        #expect(values.isEmpty && failures == 0 && actions.permitChecks == 2)
    }

    @Test(arguments: [false, true]) func failureAuthorizationCannotReportRetiredFailure(_ cancelTask: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), action = ClipboardContentAction(), actions = OwnedOCRActions(); var checks = 0, commits = 0, failures = 0
        actions.read = { throw MediaFailure.unreadable }
        #expect(action.startText(url: url, actions: actions, authorized: {
            checks += 1
            if checks == 2 {
                if cancelTask { withUnsafeCurrentTask { $0?.cancel() } } else { action.cancel() }
            }
            return true
        }, commit: { _ in commits += 1 }, failed: { failures += 1 }))
        await wait { !action.isRunning }
        #expect(commits == 0 && failures == 0 && actions.calls == 1)
    }

    @Test func heldCanceledRecognitionRetainsOwnerSlotAndEnteredCommitIsNeverReplayed() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), action = ClipboardContentAction(), actions = OwnedOCRActions()
        var release: CheckedContinuation<Void, Never>?, values: [String?] = [], failures = 0
        actions.read = { await withCheckedContinuation { release = $0 }; return "late" }
        #expect(action.startText(url: url, actions: actions, authorized: { true },
            commit: { values.append($0) }, failed: { failures += 1 }))
        await wait { release != nil }; action.cancel()
        #expect(!action.startText(url: url, actions: actions, authorized: { true }, commit: { _ in }, failed: {}))
        #expect(action.isRunning && actions.calls == 1)
        release?.resume(); await wait { !action.isRunning }
        #expect(values.isEmpty && failures == 0)
        actions.read = { nil }
        #expect(action.startText(url: url, actions: actions, authorized: { true }, commit: {
            values.append($0); action.cancel()
        }, failed: { failures += 1 }))
        await wait { !action.isRunning }
        #expect(values.count == 1 && values[0] == nil && failures == 0 && actions.calls == 2)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }
}
