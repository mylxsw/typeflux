import Foundation
import Testing
@testable import Typeflux

private struct RegistryFixture: Decodable {
    struct Entry: Decodable { let binding: AskAgentBinding; let operations: Set<AskAgentOperation> }
    struct Run: Decodable { let agentBinding: AskAgentBinding? }
    let id: String
    let registrations: [Entry]
    let defaultBinding: AskAgentBinding
    let run: Run
    let requiredOperations: Set<AskAgentOperation>
    let selectDefault: Bool
    let setupError: Bool
    let expectedBinding: AskAgentBinding?
}

extension AskApplicationAPITests {
    private var registrySend: AskSendRequest {
        .init(id: "message", deviceId: "device", text: "question", tools: [])
    }
    @Test func registrySharedFixtures() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/harness/fixtures/agent-registry.json"))
        for fixture in try AskCoding.decoder().decode([RegistryFixture].self, from: data) {
            let recorder = BoundaryRecorder()
            let runtime = BoundaryRuntime(recorder: recorder)
            let entries = fixture.registrations.map { AskAgentRegistration(
                descriptor: .init(binding: $0.binding, operations: $0.operations), runtime: runtime)
            }
            if fixture.setupError {
                #expect(throws: AskAgentRegistrySetupError.self) {
                    _ = try AskAgentRegistry(registrations: entries, defaultBinding: fixture.defaultBinding)
                }
                #expect(await recorder.calls.isEmpty)
                continue
            }
            let registry = try AskAgentRegistry(registrations: entries, defaultBinding: fixture.defaultBinding)
            func resolve() throws -> AskAgentRegistration {
                if fixture.selectDefault {
                    return try registry.selectDefault(requiredOperations: fixture.requiredOperations)
                }
                return try registry.resolvePersisted(fixture.run.agentBinding,
                    requiredOperations: fixture.requiredOperations)
            }
            if let expected = fixture.expectedBinding {
                let selected = try resolve()
                #expect(selected.descriptor.binding == expected, "\(fixture.id)")
                #expect(await recorder.calls.isEmpty)
                if expected != .default {
                    _ = try await selected.runtime.send(conversationId: "test", request: registrySend, token: "")
                    #expect(await recorder.calls.count == 1)
                    #expect(throws: (any Error).self) { _ = try AskAgentBinding.resolve(expected) }
                }
            } else {
                do {
                    _ = try resolve()
                    Issue.record("Expected implementation-unavailable for \(fixture.id)")
                } catch let error as AskLocalError {
                    #expect(error.code == AskAgentBinding.errorCode)
                }
                #expect(await recorder.calls.isEmpty)
            }
        }
    }
    @Test func registryValuesRemainImmutableAndCompositionRejectsMissingOperations() async throws {
        let recorder = BoundaryRecorder()
        let runtime = BoundaryRuntime(recorder: recorder)
        var binding = AskAgentBinding.default
        var operations = Set(AskAgentOperation.allCases)
        let descriptor = AskAgentDescriptor(binding: binding, operations: operations)
        var registrations = [AskAgentRegistration(descriptor: descriptor, runtime: runtime)]
        let registry = try AskAgentRegistry(registrations: registrations, defaultBinding: binding)
        binding.id = "mutated"
        operations.remove(.send)
        registrations.removeAll()
        let selected = try registry.selectDefault(requiredOperations: Set(AskAgentOperation.allCases))
        #expect(selected.descriptor.binding == .default)
        let limited = try AskAgentRegistry(registrations: [.init(
            descriptor: .init(binding: .default, operations: [.send]), runtime: runtime
        )], defaultBinding: .default)
        #expect(throws: (any Error).self) {
            _ = try AskApplicationAPI(registry: limited, conversations: BoundaryHistory(recorder: recorder),
                                      modelAccess: BoundaryModels(recorder: recorder))
        }
        #expect(await recorder.calls.isEmpty)
        // The injectable composition uses the same runtime interface as production.
        let alternate = AskAgentBinding(id: "test.alternate", version: 2)
        let alternateRegistry = try AskAgentRegistry(registrations: [.init(
            descriptor: .init(binding: alternate, operations: Set(AskAgentOperation.allCases)), runtime: runtime
        )], defaultBinding: alternate)
        let api = try AskApplicationAPI(registry: alternateRegistry, conversations: BoundaryHistory(recorder: recorder),
                                        modelAccess: BoundaryModels(recorder: recorder))
        _ = try await api.send(conversationId: "test", request: registrySend, token: "")
        #expect(await recorder.calls.count == 1)
    }
    @Test func routedDefaultSharesLocalEngineStateAndHostAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AskLocalEngine(directory: directory)
        let cloud = BoundaryRecorder()
        let api = AskApplicationAPI.routed(cloud: BoundaryLegacyAPI(recorder: cloud), local: engine)
        let request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Question",
            tools: [], modelRef: "custom:model")
        let initial = try await api.send(conversationId: "shared-state", request: request, token: "")
        let run = try #require(initial.run)
        #expect(run.agentBinding == .default)
        let completed = try await api.inferenceResult(conversationId: initial.id, request: .init(
            runId: run.id, deviceId: "device", inferenceId: try #require(run.inference).id, content: "Answer"
        ), token: "")
        #expect(completed.run?.status == "completed")
        #expect(try await engine.conversation(id: initial.id, token: "").revision == completed.revision)
        #expect(try await api.conversation(id: initial.id, token: "").revision == completed.revision)
        #expect(try await api.list(token: "", offset: 0).contains { $0.id == initial.id })
        let expectedModels = try await engine.models(token: "")
        #expect(try await api.models(token: "").map(\.id) == expectedModels.map(\.id))
        _ = try await api.cancel(conversationId: "remote", runId: "run", token: "account")
        #expect(await cloud.calls.last?.method == "cancel")
        // A registered alternate still cannot execute against the default engine's state.
        var record = try AskCoding.decoder().decode(AskLocalRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent(initial.id + ".json")))
        record.conversation.run?.agentBinding = .init(id: "test.alternate", version: 2)
        try AskCoding.encoder().encode(record).write(to: directory.appendingPathComponent(initial.id + ".json"))
        let reopened = AskLocalEngine(directory: directory)
        await #expect(throws: (any Error).self) {
            _ = try await reopened.send(conversationId: initial.id, request: request, token: "")
        }
    }
}
extension AskApplicationAPITests {
    @Test func productionCallerFactoriesRetainLocalStateAndCloudRoute() async throws {
        let suite = "registry-callers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        for caller in ["conversation", "workflow"] {
            let engine = AskLocalEngine(directory: root.appendingPathComponent(caller))
            let cloud = BoundaryRecorder()
            let remote = BoundaryLegacyAPI(recorder: cloud)
            let api: any AskAPI
            if caller == "conversation" {
                api = AskConversationWindowController.makeAPI(settings: settings, modelLibrary: .shared,
                    cloud: remote, local: engine)
            } else {
                api = AskWorkflowEditorWindowController.fallbackDependencies(settings: settings,
                    cloud: remote, local: engine).api
                #expect(defaults.string(forKey: "ask.deviceId") != nil)
            }
            let request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Question",
                tools: [], modelRef: "custom:model")
            let initial = try await api.send(conversationId: caller, request: request, token: "")
            let run = try #require(initial.run)
            #expect(run.agentBinding == .default)
            let cancelled = try await api.cancel(conversationId: caller, runId: run.id, token: "")
            #expect(cancelled.run?.status == "cancelled")
            #expect(try await engine.conversation(id: caller, token: "").revision == cancelled.revision)
            #expect(try await api.conversation(id: caller, token: "").revision == cancelled.revision)
            #expect(try await api.list(token: "", offset: 0).contains { $0.id == caller })
            let expectedModels = try await engine.models(token: "")
            #expect(try await api.models(token: "").map(\.id) == expectedModels.map(\.id))
            _ = try await api.cancel(conversationId: "remote", runId: "remote", token: "account")
            #expect(await cloud.calls.last?.method == "cancel")
        }
    }
}

extension AskApplicationAPITests {
    @Test func productionConversationFactoryBuildsConfiguredDefaultEngine() async throws {
        let suite = "registry-default-factory-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let api = AskConversationWindowController.makeAPI(settings: settings, modelLibrary: library,
            cloud: BoundaryLegacyAPI(recorder: BoundaryRecorder()))
        let routed = try #require(api.runtime as? AskRoutedAPI)
        let local = try #require(routed.local as? AskApplicationAPI)
        let engine = try #require(local.runtime as? AskLocalEngine)
        let limits = await engine.contextLimits("custom:model")
        #expect(limits.window == 32768)
        #expect(limits.maxOutput == 4096)
        #expect(!limits.known)
        #expect(await engine.budgetEnabled == settings.defaults.bool(forKey: "ask.budgetEnabled"))
        let host = try #require(Mirror(reflecting: engine).children.first { $0.label == "builtinTools" }?.value as? DefaultAskBuiltinToolHost)
        #expect(host.definitions() == [AskBuiltinPlan.definition] + host.webTools.definitions())
    }
}
