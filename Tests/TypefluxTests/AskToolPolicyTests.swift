import Foundation
import Testing
@testable import Typeflux

@Suite("Scoped tool policy")
@MainActor
struct AskToolPolicyTests {
    let time = Date(timeIntervalSince1970: 1_800_000_000)

    func request(name: String = "browser", action: String = "open", arguments: String? = nil,
                 reusable: Bool = true) -> AskApprovalRequest {
        let call = AskToolCall(id: "call", function: .init(name: name, arguments: arguments ?? "{\"action\":\"\(action)\",\"url\":\"https://example.invalid/\"}"))
        return AskToolPolicy.request(call: call, owner: "owner", conversation: "conversation", run: "run", step: "step",
                                     binding: .init(target: .init(kind: "browser_tab", id: "window:tab", version: "document-1", domain: "example.invalid"),
                                                    toolVersion: "schema-1", summary: "Example", allowsReuse: true),
                                     risk: .read, reuseEnabled: reusable, now: time)
    }

    func store() -> AskApprovalStore { let store = AskApprovalStore(); store.now = { time }; return store }

    @Test func hashesOriginalUTF8Bytes() {
        #expect(AskToolPolicy.digest("abc") == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(request(arguments: "{\"x\":1}").context.argumentsHash != request(arguments: "{ \"x\":1}").context.argumentsHash)
        #expect(request(arguments: "{\"x\":1,\"y\":2}").context.argumentsHash != request(arguments: "{\"y\":2,\"x\":1}").context.argumentsHash)
        #expect(AskToolPolicy.digest("é") != AskToolPolicy.digest("e\u{301}"))
        #expect(AskToolPolicy.action(.init(id: "x", function: .init(name: "run_code", arguments: "invalid"))) == "run_code:invoke")
    }

    @Test(arguments: ["pay", "publish", "send", "delete", "click", "fill", "key", "hotkey", "unknown"])
    func navigationCannotAuthorizeEffects(_ action: String) throws {
        let store = store(), navigation = request()
        let id = try #require(store.issue(navigation, reusable: true))
        let effect = request(action: action)
        #expect(!effect.reusable)
        #expect(store.issue(effect, reusable: true) == nil)
        #expect(!store.consume(id, for: effect))
        #expect(store.consume(id, for: navigation))
    }

    @Test(arguments: ["run_code", "mcp_read", "mcp_send", "memory", "computer", "files"])
    func unknownOrWriteOperationsCannotReuse(_ name: String) {
        let request = request(name: name, action: "write")
        #expect(!request.reusable)
        #expect(store().issue(request, reusable: true) == nil)
    }

    @Test func singleUseIsAtomicAcrossContenders() async throws {
        let store = store(), request = request(name: "run_code")
        let id = try #require(store.issue(request))
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 { group.addTask { await store.consume(id, for: request) } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(!store.consume("unknown", for: request))
    }

    @Test(arguments: ["owner", "conversation", "run", "step", "call", "action", "arguments", "tool", "schema", "target", "version", "path", "domain", "risk", "summary"])
    func changedEvidenceCannotConsume(_ field: String) throws {
        let store = store(), original = request()
        let id = try #require(store.issue(original))
        var changed = original
        switch field {
        case "owner": changed.context.ownerId = "other"
        case "conversation": changed.context.conversationId = "other"
        case "run": changed.context.runId = "other"
        case "step": changed.context.stepId = "other"
        case "call": changed.context.toolCallId = "other"
        case "action": changed.action = "browser:send"
        case "arguments": changed.context.argumentsHash = AskToolPolicy.digest("different")
        case "tool": changed.context.toolName = "computer"
        case "schema": changed.context.toolVersion = "v2"; changed.binding.toolVersion = "v2"
        case "target": changed.context.target.id = "other"
        case "version": changed.context.target.version = "other"
        case "path": changed.context.target.path = "/other"
        case "domain": changed.context.target.domain = "other.invalid"
        case "risk": changed.risk = .destructive
        default: changed.binding.summary = "different target label"
        }
        changed.binding.target = changed.context.target
        #expect(!store.consume(id, for: changed))
        #expect(store.consume(id, for: original))
    }

    @Test func reuseIsExactAndRequiresNegotiation() throws {
        let store = store(), original = request()
        let id = try #require(store.issue(original, reusable: true))
        var next = original; next.context.toolCallId = "next"; next.context.runId = "next-run"
        #expect(store.reusableGrant(for: next) == id)
        #expect(store.consume(id, for: next)); #expect(store.consume(id, for: next))
        next.reusable = false
        #expect(store.reusableGrant(for: next) == nil); #expect(!store.consume(id, for: next))
        #expect(!request(reusable: false).reusable)
        store.revoke(conversation: "unrelated")
        #expect(store.consume(id, for: original))
        store.revoke(conversation: "conversation")
        #expect(!store.consume(id, for: original))
        _ = store.issue(original); store.reset()
        #expect(store.reusableGrant(for: original) == nil)
    }

    @Test func expiryAndUnknownConstraintsDeny() throws {
        let store = store(), request = request()
        let id = try #require(store.issue(request))
        store.now = { time.addingTimeInterval(300) }
        #expect(!store.consume(id, for: request)); #expect(store.issue(request) == nil)
        var scope = AskApprovalScope(id: "scope", ownerId: "owner", conversationId: "conversation",
                                     action: request.action, target: request.context.target,
                                     expiresAt: time.addingTimeInterval(300), singleUse: true,
                                     argumentsHash: request.context.argumentsHash)
        func matches() -> Bool { AskApprovalStore.matches(.init(scope: scope, request: request), request, now: time) }
        #expect(matches())
        scope.allowedArguments = .init(data: Data("{\"future_range\":true}".utf8)); #expect(!matches())
        scope.allowedArguments = nil; scope.argumentsHash = nil; #expect(!matches())
        scope.argumentsHash = request.context.argumentsHash; scope.revokedAt = time; #expect(!matches())
        scope.revokedAt = nil; scope.consumedAt = time; #expect(!matches())
        scope.consumedAt = nil; scope.expiresAt = time; #expect(!matches())
    }

    @Test func invalidContextAndMCPIdentityFailClosed() throws {
        var request = request()
        request.context.ownerId = ""; #expect(store().issue(request) == nil)
        request.context.ownerId = "owner"; request.context.argumentsHash = "not-a-hash"
        #expect(store().issue(request) == nil)
        request.context.argumentsHash = AskToolPolicy.digest("{}")
        request.context.target.kind = "future"; request.binding.target = request.context.target
        #expect(store().issue(request) == nil)
        request.context.target.kind = "mcp_server"; request.binding.target = request.context.target
        #expect(store().issue(request) == nil)
        request.context.serverId = "server"; request.binding.serverId = "server"
        #expect(store().issue(request) == nil)
        request.context.serverVersion = "connection-1"; request.binding.serverVersion = "connection-1"
        let store = store(), id = try #require(store.issue(request))
        var changed = request; changed.context.serverId = "replacement"; changed.binding.serverId = "replacement"
        #expect(!store.consume(id, for: changed))
        changed = request; changed.context.serverVersion = "connection-2"; changed.binding.serverVersion = "connection-2"
        #expect(!store.consume(id, for: changed))
        #expect(store.consume(id, for: request))
        request.context.target.kind = "workspace"; request.binding.target = request.context.target
        #expect(store.issue(request) == nil)
    }
}
