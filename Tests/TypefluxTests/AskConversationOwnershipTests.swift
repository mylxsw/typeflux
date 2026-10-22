import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskConversationOwnershipTests {
    private func environment(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func request() -> AskSendRequest {
        .init(id: UUID().uuidString, deviceId: "device", text: "Question", tools: [], modelRef: "custom:test")
    }

    private func childProbe(_ directory: URL) async throws -> ManagedProcess.Result {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        defer { close(descriptor) }
        // A real second process opens the same inode; no application data or network.
        return try await ManagedProcess().run(.init(executable: "/usr/bin/perl",
            arguments: ["-MFcntl=:flock,:DEFAULT", "-e",
                "sysopen(my $f, $ARGV[0], O_RDWR) or die $!; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 23);",
                directory.appendingPathComponent(AskConversationDirectoryLease.filename).path],
            environment: ["PATH": "/usr/bin:/bin"], directoryDescriptor: descriptor,
            timeout: 3, outputLimit: 1024))
    }

    @Test func directoryLeaseRejectsOtherProcessesAndAliasesThenReleasesWithoutUnlinking() async throws {
        try await environment { root in
            let directory = root.appendingPathComponent("state")
            var lease: AskConversationDirectoryLease? = try .init(directory: directory)
            #expect(lease != nil)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            #expect(throws: AskConversationOwnershipError.inUse) { try AskConversationDirectoryLease(directory: alias) }
            let independent = try AskConversationDirectoryLease(directory: root.appendingPathComponent("other"))
            withExtendedLifetime(independent) {}
            let blocked = try await childProbe(directory)
            #expect(blocked.termination == .exited(23))
            let file = directory.appendingPathComponent(AskConversationDirectoryLease.filename)
            let metadata = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            lease = nil
            #expect(FileManager.default.fileExists(atPath: file.path))
            let admitted = try await childProbe(directory)
            #expect(admitted.termination == .exited(0))
            let next = try AskConversationDirectoryLease(directory: alias)
            withExtendedLifetime(next) {}
            #expect(AskConversationOwnershipError.inUse.localizedDescription == L("ask.storage.inUse"))
        }
    }

    @Test func rejectsInvalidDirectoriesAndUnsafeLockFiles() async throws {
        try await environment { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent(AskConversationDirectoryLease.filename)
            let target = root.appendingPathComponent("target")
            try Data("unchanged".utf8).write(to: target)
            #expect(throws: (any Error).self) { try AskConversationDirectoryLease(directory: target) }
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            #expect(throws: POSIXError.self) { try AskConversationDirectoryLease(directory: root) }
            #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.linkItem(at: target, to: file)
            #expect(throws: POSIXError.self) { try AskConversationDirectoryLease(directory: root) }
            try FileManager.default.removeItem(at: file)
            #expect(mkfifo(file.path, 0o600) == 0)
            #expect(throws: POSIXError.self) { try AskConversationDirectoryLease(directory: root) }
            try FileManager.default.removeItem(at: file)
            let recovered = try AskConversationDirectoryLease(directory: root)
            withExtendedLifetime(recovered) {}
        }
    }

    @Test func deniedEngineCannotReadModifyDeleteOrDispatchAndRetriesFreshAfterRelease() async throws {
        try await environment { root in
            var owner: AskLocalEngine? = .init(directory: root, requiresExclusiveAccess: true)
            let initial = try await owner!.send(conversationId: "chat", request: request(), token: "")
            let run = try #require(initial.run)
            let contender = AskLocalEngine(directory: root, requiresExclusiveAccess: true)
            let operations: [() async throws -> Void] = [
                { _ = try await contender.list(token: "", offset: 0) },
                { _ = try await contender.send(conversationId: "new", request: request(), token: "") },
                { _ = try await contender.conversation(id: "chat", token: "") },
                { _ = try await contender.updateTitle(id: "chat", request: .init(action: "rename", title: "Lost"), token: "") },
                { try await contender.delete(conversationId: "chat", token: "") },
                { try await contender.purgeMemory(token: "") },
                { try await contender.purgeMemory(owner: "owner", token: "") },
                { _ = try await contender.keep(conversationId: "chat", token: "") },
                { _ = try await contender.cancel(conversationId: "chat", runId: run.id, token: "") },
                { _ = try await contender.resume(conversationId: "chat", runId: run.id, token: "") },
                { _ = try await contender.retry(conversationId: "chat", runId: run.id, deviceId: "device", modelRef: nil, token: "") },
                { _ = try await contender.usage(id: "chat", runId: nil, cursor: nil, token: "") },
                { _ = try await contender.runRoute(conversationId: "chat", runId: run.id) },
                { try await contender.importLegacy(.init(id: "legacy", title: "Legacy", revision: 1, updatedAt: Date(), messages: [])) },
                { try await contender.persist(.init(conversation: initial)) },
                { _ = try await contender.budgetJournal(.init(conversation: initial), { _ in }) }
            ]
            for operation in operations {
                await #expect(throws: AskConversationOwnershipError.inUse) { try await operation() }
            }
            #expect(try await owner!.conversation(id: "chat", token: "").revision == initial.revision)
            let cancelled = try await owner!.cancel(conversationId: "chat", runId: run.id, token: "")
            weak var oldOwner = owner
            owner = nil
            #expect(oldOwner == nil)
            // A denied first read must not set `loaded`, retaining an empty/stale cache.
            let recovered = try await contender.conversation(id: "chat", token: "")
            #expect(recovered.revision == cancelled.revision)
            #expect(recovered.run?.status == "cancelled")
            try await contender.delete(conversationId: "chat", token: "")
            #expect(try await contender.list(token: "", offset: 0).isEmpty)
        }
    }

    @Test func temporaryStateHasOneOwnerAndCancellationDoesNotReleaseTheStore() async throws {
        try await environment { root in
            let owner = AskLocalEngine(directory: root, requiresExclusiveAccess: true)
            var send = request(); send.temporary = true
            let value = try await owner.send(conversationId: "temporary", request: send, token: "")
            #expect(await owner.isTemporary(value.id))
            #expect(try await owner.list(token: "", offset: 0).isEmpty)
            let task = Task { try await owner.cancel(conversationId: value.id, runId: value.run!.id, token: "") }
            _ = try await task.value
            let contender = AskLocalEngine(directory: root, requiresExclusiveAccess: true)
            await #expect(throws: AskConversationOwnershipError.inUse) {
                _ = try await contender.send(conversationId: value.id, request: send, token: "")
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(value.id + ".json").path))
            let kept = try await owner.keep(conversationId: value.id, token: "")
            #expect(kept.id == value.id)
            #expect(try await owner.list(token: "", offset: 0).map(\.id) == [value.id])
        }
    }

    @Test func applicationServiceReusesTheSameRuntimeHistoryAndCatalog() async throws {
        let owner = AskApplicationService(), backend = AskTestAPI()
        var creations = 0
        let first = owner.resolve {
            creations += 1
            return .init(runtime: backend, conversations: backend, modelAccess: backend)
        }
        let second = owner.resolve {
            creations += 1
            let wrong = AskTestAPI()
            return .init(runtime: wrong, conversations: wrong, modelAccess: wrong)
        }
        #expect(creations == 1)
        #expect(first.runtime as? AskTestAPI === backend)
        #expect(second.runtime as? AskTestAPI === backend)
        #expect(second.conversations as? AskTestAPI === backend)
        #expect(second.modelAccess as? AskTestAPI === backend)
    }

    @Test func conversationAndFallbackWorkflowFactoriesShareProductionEngines() throws {
        let suite = "owner-factories-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AskApplicationService(), settings = SettingsStore(defaults: defaults)
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let first = AskConversationWindowController.makeAPI(settings: settings, modelLibrary: library, service: service)
        let fallback = AskWorkflowEditorWindowController.fallbackDependencies(settings: settings, service: service)
        let second = try #require(fallback.api as? AskApplicationAPI)
        let firstRoute = try #require(first.runtime as? AskRoutedAPI)
        let secondRoute = try #require(second.runtime as? AskRoutedAPI)
        #expect(firstRoute.cloud as? AskDeviceAPI === secondRoute.cloud as? AskDeviceAPI)
        let firstLocal = try #require(firstRoute.local as? AskApplicationAPI)
        let secondLocal = try #require(secondRoute.local as? AskApplicationAPI)
        #expect(firstLocal.runtime as? AskLocalEngine === secondLocal.runtime as? AskLocalEngine)
        #expect(fallback.deviceId == defaults.string(forKey: "ask.deviceId"))
    }

}
