import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureProcessFreezeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_FEATURE_FREEZE_TEST"] == "1"))
    func realFeatureWindowsRemainUsableWhenAnotherMainThreadIsFrozen() async throws {
        let fixture = try makeFixture()
        let api = AskTestAPI(), cache = try AskConversationCache.inMemory()
        let supervisor = FeatureSupervisor(api: api, cache: cache,
            auth: .init(generation: 0, token: "isolation-fixture-token", expiresAt: Int(Date().timeIntervalSince1970) + 3600,
                profile: .init(id: "fixture-owner", email: "fixture@example.invalid", name: "Fixture", status: 1, provider: "password", createdAt: "", updatedAt: ""),
                subscription: .init(planCode: nil, status: nil, currentPeriodStart: nil, currentPeriodEnd: nil,
                                    cancelAtPeriodEnd: false, entitled: false)),
            executableURL: fixture.executable, environment: fixture.environment)
        do {
            let roles: [FeatureRole] = [.chat, .launcher, .clipboard, .screenshot, .settings]
            var processes: Set<Int32> = []
            var processIDs: [FeatureRole: Int32] = [:]
            let all: [FeatureRole] = roles + [.shortcuts, .voice, .ring, .notes, .wordBook, .monitor, .help, .translation]
            for role in all {
                print("FEATURE_START role=\(role.rawValue)")
                let reply = try await supervisor.route(.init(destination: role, action: "probeExercise"), timeout: .seconds(60))
                let pid = try JSONDecoder().decode(Int32.self, from: reply)
                processIDs[role] = pid; processes.insert(pid)
            }
            #expect(processes.count == all.count)
            let noteID = Data(UUID().uuidString.utf8)
            for role in [FeatureRole.notes, .launcher, .chat, .wordBook] {
                let reply = try await supervisor.route(.init(destination: role, action: "probeStorage", payload: noteID))
                #expect(try JSONDecoder().decode(String?.self, from: reply) == "Cross-process note")
            }
            let draft = AskDraft(text: "Fixture question", includeScreenshot: false, modelRef: "cloud:default",
                attachments: [.init(kind: .file, name: "fixture.txt", text: "Fixture attachment")], storesLocally: false)
            let handoff = FeatureChatHandoff(id: UUID().uuidString, owner: "fixture-owner", generation: 0,
                draft: draft, permission: AskPermissionMode.standard.rawValue,
                reasoning: AskReasoningEffort.providerDefault.rawValue, submit: true)
            let ack = try await supervisor.route(.init(destination: .chat, action: "handoff", payload: JSONEncoder().encode(handoff)))
            #expect(try JSONDecoder().decode(Bool.self, from: ack))
            for _ in 0..<200 {
                if await !api.sends.isEmpty { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            if await api.sends.count != 1 {
                let diagnostic = try await supervisor.route(.init(destination: .chat, action: "probeChatState"))
                print("FEATURE_CHAT_FAILED " + String(decoding: diagnostic, as: UTF8.self))
                Issue.record("The native composer did not send the accepted draft")
                throw FeatureRPC.Failure.unavailable
            }
            #expect(await api.sends.first?.text == draft.text)
            #expect(await api.sends.first?.attachments == draft.attachments)
            let duplicate = try await supervisor.route(.init(destination: .chat, action: "handoff", payload: JSONEncoder().encode(handoff)))
            #expect(try JSONDecoder().decode(Bool.self, from: duplicate))
            #expect(await api.sends.count == 1)
            for frozen in all where frozen != .shortcuts {
                let freeze = Task {
                    try await supervisor.route(.init(destination: frozen, action: "probeFreeze",
                        payload: JSONEncoder().encode(4.0)), timeout: .seconds(10))
                }
                try await Task.sleep(for: .milliseconds(150))
                await #expect(throws: FeatureRPC.Failure.timedOut) {
                    try await supervisor.route(.init(destination: frozen, action: "ping"), timeout: .milliseconds(50))
                }
                let started = ContinuousClock.now
                for working in roles where working != frozen {
                    let request = FeatureCommand(destination: working, action: "probeExercise")
                    _ = try await supervisor.route(.init(destination: .shortcuts, action: "probeRoute",
                        payload: JSONEncoder().encode(request)), timeout: .seconds(2))
                }
                let elapsed = started.duration(to: .now)
                #expect(elapsed < .seconds(3))
                print("FEATURE_ISOLATION frozen=\(frozen.rawValue) independent_windows=\(roles.filter { $0 != frozen }.count) elapsed=\(elapsed)")
                _ = try await freeze.value
            }
            let oldShortcuts = try #require(processIDs[.shortcuts])
            await #expect(throws: (any Error).self) {
                try await supervisor.route(.init(destination: .shortcuts, action: "probeFreeze"), timeout: .seconds(15))
            }
            try await Task.sleep(for: .milliseconds(500))
            let replacement = try await supervisor.route(.init(destination: .shortcuts, action: "probeExercise"), timeout: .seconds(15))
            let newShortcuts = try JSONDecoder().decode(Int32.self, from: replacement)
            #expect(newShortcuts != oldShortcuts)
            processes.insert(newShortcuts)
            let healthData = try await supervisor.route(.init(destination: .host, action: "moduleHealth"))
            let health = try JSONDecoder().decode([FeatureRole: [ModuleID: ModuleHealth]].self, from: healthData)
            #expect(health[.notes]?[.notebook]?.state == .ready)
            let hostBlocked = Task.detached {
                try await Task.sleep(for: .milliseconds(100))
                let started = ContinuousClock.now
                for role in roles {
                    _ = try await supervisor.route(.init(destination: role, action: "probeExercise"), timeout: .seconds(2))
                }
                return started.duration(to: .now)
            }
            FeatureIsolationProbe.blockMainThread(seconds: 4)
            #expect(try await hostBlocked.value < .seconds(3))
            let cleanup = try await supervisor.route(.init(destination: .chat, action: "probeProcessCleanup"))
            #expect(try JSONDecoder().decode(Bool.self, from: cleanup))
            await supervisor.shutdown()
            for pid in processes { #expect(kill(pid, 0) != 0) }
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            await supervisor.shutdown()
            print("FEATURE_FIXTURE_FAILED root=\(fixture.root.path) error=\(error)")
            throw error
        }
    }

    private func makeFixture() throws -> (root: URL, executable: URL, environment: [String: String]) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("typeflux-feature-test-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("Isolation Fixture.app")
        let contents = bundle.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Typeflux")
        let resources = contents.appendingPathComponent("Resources")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = repository.appendingPathComponent(".build/debug").resolvingSymlinksInPath()
        try manager.copyItem(at: build.appendingPathComponent("Typeflux"), to: executable)
        for item in try manager.contentsOfDirectory(at: build, includingPropertiesForKeys: nil) where item.pathExtension == "bundle" {
            try manager.copyItem(at: item, to: resources.appendingPathComponent(item.lastPathComponent))
        }
        let info: [String: Any] = ["CFBundleIdentifier": "ai.gulu.typeflux.isolation-test." + UUID().uuidString.lowercased(),
            "CFBundleExecutable": "Typeflux", "CFBundleName": "Isolation Fixture", "CFBundlePackageType": "APPL",
            "LSUIElement": true, "NSHighResolutionCapable": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--deep", "--sign", "-", bundle.path]
        signing.standardOutput = FileHandle.nullDevice; signing.standardError = FileHandle.nullDevice
        try signing.run(); signing.waitUntilExit()
        #expect(signing.terminationStatus == 0)
        var environment = ["PATH": "/usr/bin:/bin", "HOME": root.path,
                           "TYPEFLUX_FEATURE_FIXTURE": "1", "TMPDIR": root.path + "/"]
        for name in ["DATA", "WORKSPACES", "CACHE"] {
            environment["TYPEFLUX_FEATURE_" + name] = root.appendingPathComponent(name.lowercased()).path
        }
        environment["LLVM_PROFILE_FILE"] = build.appendingPathComponent("codecov/feature-%p.profraw").path
        return (root, executable, environment)
    }
}
