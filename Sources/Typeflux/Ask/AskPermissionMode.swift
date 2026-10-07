import Foundation

/// UI-owned authority, kept in memory only. Never decoded from model or server data.
enum AskPermissionMode: String, CaseIterable, Sendable {
    case strict, standard, yolo

    var title: String { L("ask.mode." + rawValue) }
    var detail: String { L("ask.mode." + rawValue + ".detail") }
    var symbol: String {
        switch self {
        case .strict: "lock.shield"
        case .standard: "checkmark.shield"
        case .yolo: "bolt.shield.fill"
        }
    }

    func automaticallyAllows(_ risk: AskToolRisk) -> Bool {
        switch self {
        case .strict: false
        case .standard: risk == .none || risk == .read
        case .yolo: true
        }
    }

    /// Only a complete, explicit command changes authority. Invalid arguments stay local.
    static func command(_ text: String) -> (recognized: Bool, mode: Self?) {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.first == "/mode" else { return (false, nil) }
        return (true, words.count == 2 ? Self(rawValue: String(words[1])) : nil)
    }
}

extension AskConversationModel {
    func permissionMode(launcher: Bool) -> AskPermissionMode {
        launcher ? launcherPermissionMode : selectedId.map { permissionModes[$0] ?? .standard } ?? draftPermissionMode
    }

    func permissionMode(conversationId: String) -> AskPermissionMode {
        permissionModes[conversationId] ?? .standard
    }

    /// Called only by the local menu or command handler, including while approval is pending.
    func setPermissionMode(_ mode: AskPermissionMode, launcher: Bool) {
        guard let current = session(), launcher || !isLoadingSelection else { return }
        if owner != current.owner {
            // A fresh model has no authority to revoke; keep its unsent draft intact.
            if !owner.isEmpty { resetSession() }
            owner = current.owner
        }
        if launcher {
            launcherPermissionMode = mode
        } else if let id = selectedId {
            guard permissionModes[id] != mode else { return }
            permissionModes[id] = mode
            approvalStore.revoke(conversation: id)
            resumeAutomaticallyApprovedTool(id)
        } else {
            draftPermissionMode = mode
        }
        confirm(L("ask.mode.changed", mode.title))
    }

    @discardableResult
    func consumeModeCommand(launcher: Bool) -> Bool {
        let parsed = AskPermissionMode.command(launcher ? launcherDraft.text : draft.text)
        guard parsed.recognized else { return false }
        guard let mode = parsed.mode else {
            confirm(L("ask.mode.usage")); return true
        }
        setPermissionMode(mode, launcher: launcher)
        if launcher { launcherDraft.text = "" } else { draft.text = "" }
        persistDrafts()
        return true
    }
}

extension AskConversationModel {
    func toolRisk(_ call: AskToolCall, cloudDefinition: AskToolDefinition?) -> AskToolRisk {
        guard cloudDefinition != nil else { return tools.risk(of: call) }
        switch call.function.name {
        case "web_search", "web_fetch", "web_research": return .read
        case "update_plan": return .none
        default: return .destructive
        }
    }

    func preparedToolBinding(_ call: AskToolCall, conversationId: String,
                             cloudDefinition: AskToolDefinition?) async throws -> AskToolBinding {
        guard let definition = cloudDefinition else {
            return try await tools.preparedBinding(for: call, conversationId: conversationId)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(target: .init(kind: "network_origin", id: "engine:" + conversationId),
                     toolVersion: AskToolPolicy.digest(try encoder.encode(definition)), summary: definition.name)
    }
}
