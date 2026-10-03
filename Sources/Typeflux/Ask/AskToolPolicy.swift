import CryptoKit
import Foundation

/// Local executor evidence. Never construct this from a conversation envelope or annotations.
struct AskToolBinding: Equatable, Sendable {
    var target: AskExecutionTarget
    var toolVersion: String
    var serverId: String? = nil
    var serverVersion: String? = nil
    var summary: String
    var allowsReuse = false
}

struct AskApprovalRequest: Equatable, Sendable {
    var context: AskExecutionContext
    var action: String
    var binding: AskToolBinding
    var risk: AskToolRisk
    var reusable: Bool
}

enum AskToolPolicy {
    static func digest(_ raw: String) -> String { digest(Data(raw.utf8)) }
    static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func action(_ call: AskToolCall) -> String {
        let arguments = try? AskLocalTools.jsonArguments(call.function.arguments)
        return call.function.name + ":" + (arguments?["action"] as? String ?? "invoke")
    }

    /// Only known read/navigation operations are candidates. Exact arguments still apply.
    static func mayReuse(_ call: AskToolCall) -> Bool {
        switch action(call) {
        case "files:read", "files:list", "files:search", "memory:list",
             "browser:read", "browser:snapshot", "browser:open", "browser:scroll",
             "computer:inspect", "computer:scroll", "computer:wait": return true
        default: return false
        }
    }

    static func request(call: AskToolCall, owner: String, conversation: String, run: String,
                        step: String, binding: AskToolBinding, risk: AskToolRisk,
                        reuseEnabled: Bool = false, now: Date = .now) -> AskApprovalRequest {
        .init(context: .init(ownerId: owner, conversationId: conversation, runId: run, stepId: step,
                            toolCallId: call.id, toolName: call.function.name, toolVersion: binding.toolVersion,
                            argumentsHash: digest(call.function.arguments), target: binding.target,
                            deadline: now.addingTimeInterval(300), serverId: binding.serverId,
                            serverVersion: binding.serverVersion),
              action: action(call), binding: binding, risk: risk,
              reusable: reuseEnabled && binding.allowsReuse && mayReuse(call) && risk < .destructive)
    }

    static func valid(_ request: AskApprovalRequest, now: Date) -> Bool {
        let c = request.context
        guard ![c.ownerId, c.conversationId, c.runId, c.stepId, c.toolCallId, c.toolName,
                c.toolVersion, c.target.id, request.action].contains(where: \.isEmpty),
              c.deadline > now, c.target == request.binding.target,
              c.toolVersion == request.binding.toolVersion,
              c.serverId == request.binding.serverId, c.serverVersion == request.binding.serverVersion,
              c.argumentsHash.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
              ["workspace", "browser_tab", "desktop_window", "mcp_server", "network_origin"].contains(c.target.kind)
        else { return false }
        if c.target.kind == "mcp_server" {
            return c.serverId?.isEmpty == false && c.serverVersion?.isEmpty == false
        }
        return c.serverId == nil && c.serverVersion == nil
    }
}

/// In-memory trusted grants; there is deliberately no decoder/import path.
/// Main-actor isolation makes validation and single-use consumption atomic.
@MainActor
final class AskApprovalStore {
    struct Grant {
        var scope: AskApprovalScope
        let request: AskApprovalRequest
    }
    private var grants: [String: Grant] = [:]
    var now: () -> Date = { .now }

    func issue(_ request: AskApprovalRequest, reusable: Bool = false) -> String? {
        let time = now()
        guard AskToolPolicy.valid(request, now: time), !reusable || request.reusable else { return nil }
        grants = grants.filter { $0.value.scope.expiresAt > time && $0.value.scope.revokedAt == nil }
        let id = UUID().uuidString
        grants[id] = .init(scope: .init(id: id, ownerId: request.context.ownerId,
                                       conversationId: request.context.conversationId, action: request.action,
                                       target: request.context.target, expiresAt: request.context.deadline,
                                       singleUse: !reusable, argumentsHash: request.context.argumentsHash), request: request)
        return id
    }

    func reusableGrant(for request: AskApprovalRequest) -> String? {
        guard request.reusable else { return nil }
        return grants.first { !$0.value.scope.singleUse && Self.matches($0.value, request, now: now()) }?.key
    }

    func consume(_ id: String, for request: AskApprovalRequest) -> Bool {
        guard var grant = grants[id], Self.matches(grant, request, now: now()) else { return false }
        if grant.scope.singleUse { grant.scope.consumedAt = now(); grants[id] = grant }
        return true
    }

    /// A consumed grant remains revocable while the executor prepares dispatch.
    func validateDispatch(_ id: String, for request: AskApprovalRequest) -> Bool {
        guard var grant = grants[id], !grant.scope.singleUse || grant.scope.consumedAt != nil else { return false }
        grant.scope.consumedAt = nil
        return Self.matches(grant, request, now: now())
    }

    static func matches(_ grant: Grant, _ request: AskApprovalRequest, now: Date) -> Bool {
        let s = grant.scope, old = grant.request.context, c = request.context
        guard AskToolPolicy.valid(request, now: now), s.expiresAt > now, s.revokedAt == nil,
              !s.singleUse || s.consumedAt == nil,
              s.ownerId == c.ownerId, s.conversationId == c.conversationId,
              s.action == request.action, s.target == c.target,
              s.argumentsHash == c.argumentsHash,
              // No parameter constraint language is negotiated yet: unknown constraints deny,
              // even if a matching hash is also present.
              s.allowedArguments == nil,
              old.toolName == c.toolName, old.toolVersion == c.toolVersion,
              old.serverId == c.serverId, old.serverVersion == c.serverVersion,
              grant.request.binding == request.binding, grant.request.risk == request.risk
        else { return false }
        if s.singleUse {
            return old.runId == c.runId && old.stepId == c.stepId && old.toolCallId == c.toolCallId
        }
        return grant.request.reusable && request.reusable
    }

    func revoke(conversation: String) { grants = grants.filter { $0.value.scope.conversationId != conversation } }
    func reset() { grants.removeAll() }
}
