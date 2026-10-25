import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureProcessFreezeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_FEATURE_FREEZE_TEST"] == "1"))
    func failedBootstrapStillAllowsBackgroundToShutDown() async throws {
        let fixture = try makeFixture()
        // The child's bootstrap RPC expires after ten seconds. Keep host
        // preparation pending beyond that deadline to reproduce a poisoned ready task.
        var resumePreparation: CheckedContinuation<Void, Never>?
        let preparation = Task<Void, Never> {
            await withCheckedContinuation { resumePreparation = $0 }
        }
        defer { resumePreparation?.resume(); preparation.cancel() }
        let supervisor = FeatureSupervisor(api: AskTestAPI(), cache: try AskConversationCache.inMemory(),
            auth: FeatureAuth.capture(), preparation: preparation,
            executableURL: fixture.executable, environment: fixture.environment)
        do {
            await #expect(throws: FeatureRPC.Failure.timedOut) {
                _ = try await supervisor.route(.init(destination: .background, action: "ping"), timeout: .seconds(20))
            }
            #expect(await supervisor.shutdown())
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            _ = await supervisor.shutdown()
            throw error
        }
    }

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
            let roles: [FeatureRole] = [.chat, .voice, .screenshot, .background]
            var processes = Set<Int32>()
            for role in roles {
                let reply = try await supervisor.route(.init(destination: role, action: "probeExercise"), timeout: .seconds(60))
                processes.insert(try JSONDecoder().decode(Int32.self, from: reply))
            }
            #expect(processes.count == roles.count)
            for frozen in roles {
                let freeze = Task {
                    try await supervisor.route(.init(destination: frozen, action: "probeFreeze", payload: JSONEncoder().encode(2.0)), timeout: .seconds(5))
                }
                try await Task.sleep(for: .milliseconds(100))
                await #expect(throws: FeatureRPC.Failure.timedOut) {
                    try await supervisor.route(.init(destination: frozen, action: "ping"), timeout: .milliseconds(50))
                }
                for working in roles where working != frozen {
                    _ = try await supervisor.route(.init(destination: working, action: "ping"), timeout: .seconds(1))
                }
                _ = try await freeze.value
            }
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
