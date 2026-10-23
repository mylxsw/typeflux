import Darwin
import Foundation
import Testing
@testable import Typeflux
import TypefluxMediaProtocol

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureProcessConsolidationTests {
    @Test func `logical destinations have exactly five owners`() {
        #expect(Set(FeatureRole.allCases.map(\.processOwner)) == Set(FeatureRole.processRoles))
        for role in [
            FeatureRole.launcher,
            .clipboard,
            .shortcuts,
            .settings,
            .ring,
            .notes,
            .wordBook,
            .monitor,
            .help,
            .translation
        ] {
            #expect(role.processOwner == .host)
        }
        #expect(FeatureRole.background.modules.contains(.fileIndex))
        #expect(FeatureRole.background.modules.contains(.semanticIndexInference))
        #expect(!FeatureRole.host.modules.contains(.fileIndex))
        #expect(!FeatureRole.chat.modules.contains(.whisperInference))
        #expect(FeatureRole.voice.modules == [.whisperInference])
    }

    @Test func `merged commands keep their logical destination and payload without spawning`() async throws {
        let previous = FeatureProcess.handle
        defer { FeatureProcess.handle = previous }
        var received: [FeatureCommand] = []
        FeatureProcess.handle = { received.append($0); return $0.payload }
        let cache = try AskConversationCache.inMemory()
        let supervisor = FeatureSupervisor(api: AskTestAPI(), cache: cache, auth: FeatureAuth.capture(),
                                           executableURL: URL(
                                               fileURLWithPath: "/nonexistent/typeflux-must-never-launch"
                                           ))
        for role in [
            FeatureRole.launcher,
            .clipboard,
            .ring,
            .translation,
            .notes,
            .wordBook,
            .settings,
            .help,
            .monitor
        ] {
            let command = FeatureCommand(destination: role, action: "fixture", payload: Data(role.rawValue.utf8))
            #expect(try await supervisor.route(command) == command.payload)
        }
        #expect(received.map(\.destination) == [
            .launcher,
            .clipboard,
            .ring,
            .translation,
            .notes,
            .wordBook,
            .settings,
            .help,
            .monitor
        ])
        await supervisor.shutdown()
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await supervisor.route(.init(
            destination: .launcher,
            action: "fixture"
        )) }
    }

    @Test func `idle policy never retires voice and restarts its clock when work returns`() {
        var policy = FeatureIdlePolicy()
        func retire(role: FeatureRole, blocked: Bool, uptime: TimeInterval) -> Bool {
            policy.shouldRetire(role: role, blocked: blocked, uptime: uptime)
        }
        #expect(!retire(role: .chat, blocked: false, uptime: 10))
        #expect(!retire(role: .chat, blocked: false, uptime: 129))
        #expect(retire(role: .chat, blocked: false, uptime: 130))
        #expect(!retire(role: .chat, blocked: true, uptime: 140))
        #expect(!retire(role: .chat, blocked: false, uptime: 200))
        #expect(!retire(role: .chat, blocked: false, uptime: 319))
        #expect(retire(role: .chat, blocked: false, uptime: 320))
        for role in [FeatureRole.voice, .host] {
            #expect(!retire(role: role, blocked: false, uptime: 10000))
        }
        #expect(!retire(role: .screenshot, blocked: false, uptime: 10000))
        #expect(retire(role: .screenshot, blocked: false, uptime: 10180))
    }

    @Test func `CPU requires matching process lifetime and handles missing counters`() throws {
        let a = FeatureResourceSnapshot(role: .host, pid: 2, startedAt: 10, uptime: 20, footprintBytes: 4,
                                        cpuNanoseconds: 1_000_000_000, managedOperations: 0, helperSlots: 0)
        let b = FeatureResourceSnapshot(role: .host, pid: 2, startedAt: 10, uptime: 22, footprintBytes: 4,
                                        cpuNanoseconds: 2_000_000_000, managedOperations: 0, helperSlots: 0)
        #expect(b.cpuPercent(since: a) == 50)
        #expect(a.cpuPercent(since: b) == nil)
        let reused = FeatureResourceSnapshot(role: .host, pid: 2, startedAt: 11, uptime: 22, footprintBytes: nil,
                                             cpuNanoseconds: nil, managedOperations: 0, helperSlots: 0)
        #expect(reused.cpuPercent(since: a) == nil)
        let captured = FeatureResourceSnapshot.capture(role: .host)
        #expect(captured.pid == getpid())
        #expect(captured.footprintBytes != nil)
        #expect(try JSONDecoder()
            .decode(FeatureResourceSnapshot.self, from: JSONEncoder().encode(captured)) == captured)
    }

    @Test func `health migration preserves quarantine and does not undo later explicit reset`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("features/launcher")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModuleHealthStore.Record(attempts: 4, quarantined: true, automaticRecoveryUsed: true))
            .write(to: old.appendingPathComponent("fileIndex.json"))
        try FeatureHealthMigration.migrate(root: root, owner: .background)
        let migrated = root.appendingPathComponent("features/background/fileIndex.json")
        let record = try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: migrated))
        #expect(record.quarantined && record.attempts == 4 && record.automaticRecoveryUsed == true)
        try JSONEncoder().encode(ModuleHealthStore.Record()).write(to: migrated)
        try FeatureHealthMigration.migrate(root: root, owner: .background)
        #expect(try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: migrated)).attempts == 0)
    }

    @Test func `corrupt legacy health fails closed`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("features/clipboard")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: old.appendingPathComponent("clipboardOCR.json"))
        try FeatureHealthMigration.migrate(root: root, owner: .host)
        let record = try JSONDecoder().decode(
            ModuleHealthStore.Record.self,
            from: Data(contentsOf: root.appendingPathComponent("clipboardOCR.json"))
        )
        #expect(record.quarantined && record.attempts == 4)
    }

    @Test func `media jobs reject foreign directories symlinks and unbounded requests`() throws {
        let request = MediaRequest(operation: .image)
        let data = try JSONEncoder().encode(request)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-media-" + request.id.uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FeatureMediaJobs.validate(.init(
            id: request.id,
            directory: directory.path,
            input: data,
            timeout: 3,
            outputLimit: 1024
        ))
        for (path, timeout) in [("/tmp", 3.0), (directory.path, Double.infinity), (directory.path, 601.0)] {
            #expect(throws: (any Error).self) {
                try FeatureMediaJobs.validate(.init(
                    id: request.id,
                    directory: path,
                    input: data,
                    timeout: timeout,
                    outputLimit: 1024
                ))
            }
        }
        let jobs = FeatureMediaJobs()
        #expect(throws: (any Error).self) { try jobs.handle(.init(
            destination: .background,
            action: "media.poll",
            payload: JSONEncoder().encode(UUID())
        )) }
        jobs.stop()
        #expect(throws: FeatureRPC.Failure.busy) {
            try jobs.handle(.init(
                destination: .background,
                action: "media.submit",
                payload: JSONEncoder().encode(FeatureMediaJob(
                    id: request.id,
                    directory: directory.path,
                    input: data,
                    timeout: 3,
                    outputLimit: 1024
                ))
            ))
        }
    }
}

@Suite(.serialized)
struct FeatureHelperBudgetTests {
    @Test func `reservations stay bounded and double release is harmless`() throws {
        let budget = FeatureHelperBudget(limit: 1)
        let lease = try budget.acquire(deadline: Date().addingTimeInterval(1), cancelled: { false })
        #expect(budget.activeCount == 1)
        #expect(throws: CancellationError.self) { try budget.acquire(
            deadline: Date().addingTimeInterval(0.03),
            cancelled: { false }
        ) }
        lease.finish(); lease.finish()
        #expect(budget.activeCount == 0)
        let next = try budget.acquire(deadline: Date().addingTimeInterval(1), cancelled: { false })
        #expect(budget.activeCount == 1)
        next.finish()
        #expect(throws: CancellationError.self) { try budget.acquire(
            deadline: Date().addingTimeInterval(1),
            cancelled: { true }
        ) }
    }
}


extension FeatureProcessConsolidationTests {
    @Test func routedDeadlinesSurviveBothHopsAndInvalidBudgetsFailBeforeSpawning() async throws {
        let command = FeatureCommand(destination: .voice, action: "fixture")
        let value = FeatureRoutedCommand(command: command, timeout: .milliseconds(45001))
        let decoded = try JSONDecoder().decode(FeatureRoutedCommand.self, from: JSONEncoder().encode(value))
        #expect(decoded.timeoutMilliseconds == 45001 && decoded.command.destination == .voice)
        await #expect(throws: FeatureRPC.Failure.invalidMessage) { try await FeatureProcess.route(command, timeout: .seconds(181)) }
        await #expect(throws: FeatureRPC.Failure.invalidMessage) { try await FeatureProcess.route(command, timeout: .zero) }
    }
}
