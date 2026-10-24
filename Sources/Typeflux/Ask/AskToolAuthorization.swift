import Foundation

enum AskToolAuthorizationError: LocalizedError {
    case denied
    var errorDescription: String? { L("agent.permissions.denied") }
}

/// The registry shared by execution and Agent settings. Unknown operations never inherit read access.
enum AskToolPermission: String, CaseIterable, Codable, Sendable {
    case allow, ask, deny
    var title: String { L("agent.permissions." + rawValue) }
}

struct AskToolAuthorizationEntry: Codable, Equatable, Identifiable, Sendable {
    let tool: String
    let action: String
    let effect: Effect
    var fingerprint: String = "builtin"
    enum Effect: String, Codable, Sendable { case read, internalState, write, execute, unknown }
    var id: String { tool + ":" + action }
    var title: String {
        let key = "agent.permissions.action." + action
        let localized = L(key)
        return localized == key ? (action == "*" ? L("agent.permissions.invoke") : action) : localized
    }
    var toolTitle: String {
        let key = "agent.permissions.tool." + tool
        let localized = L(key)
        return localized == key ? tool : localized
    }
    var risk: AskToolRisk {
        switch effect {
        case .read: .read
        case .internalState: .none
        case .write: .write
        case .execute, .unknown: .destructive
        }
    }
    func defaultPermission(_ mode: AskPermissionMode) -> AskToolPermission {
        if effect == .unknown { return .ask }
        if tool == "web_browser", ["read", "snapshot", "screenshot"].contains(action) { return .allow }
        switch mode {
        case .strict: return .ask
        case .standard: return effect == .read || effect == .internalState ? .allow : .ask
        case .yolo: return .allow
        }
    }
}

enum AskToolAuthorization {
    typealias Entry = AskToolAuthorizationEntry
    static let builtins: [Entry] = {
        var entries: [Entry] = []
        func add(_ tool: String, _ effect: Entry.Effect, _ actions: String = "*") {
            entries += actions.split(separator: " ").map { Entry(tool: tool, action: String($0), effect: effect) }
        }
        add("web_browser", .read, "read snapshot screenshot tabs")
        add("web_browser", .internalState, "select_tab wait handoff scroll new_tab_blank")
        add("web_browser", .write, "open back new_tab close_tab")
        add("web_browser", .execute, "open_file click fill")
        add("browser", .read, "read snapshot")
        add("browser", .write, "open back scroll click fill")
        add("computer", .read, "screenshot inspect")
        add("computer", .internalState, "wait")
        add("computer", .write, "click double_click right_click drag type key hotkey scroll")
        add("files", .read, "list read search")
        add("files", .write, "write edit")
        add("project_files", .internalState, "open")
        add("project_files", .read, "list read review export")
        add("project_files", .write, "write edit revert")
        add("project_terminal", .read, "status output")
        add("project_terminal", .execute, "start input stop preview")
        add("command_job", .read, "status logs")
        add("command_job", .execute, "start stop")
        add("run_code", .execute); add("run_command", .execute)
        add("artifact", .write); add("generate_image", .write)
        add("memory", .read, "list"); add("memory", .write, "remember correct forget")
        add("notebook", .read, "search read list")
        add("notebook", .write, "create append update tag delete")
        add("skill", .read)
        for name in ["web_search", "web_fetch", "web_research", "read_conversation_history",
                     "workflow_list", "workflow_read", "workflow_check_keyword"] { add(name, .read) }
        add("update_plan", .internalState); add("complete_recovery", .internalState)
        add("workflow_environment", .read)
        add("workflow_environment_versions", .execute)
        add("workflow_start", .write); add("workflow_propose", .write)
        add("workflow_save", .internalState); add("workflow_test", .execute)
        return entries
    }()

    static func action(_ call: AskToolCall) -> String {
        let args = (try? AskLocalTools.jsonArguments(call.function.arguments)) ?? [:]
        if call.function.name == "web_browser", args["action"] as? String == "new_tab", args["url"] == nil {
            return "new_tab_blank"
        }
        return args["action"] as? String ?? "*"
    }

    static func entry(for call: AskToolCall, discovered: [Entry] = []) -> Entry {
        let action = action(call)
        let candidates = (builtins + discovered).filter { $0.tool == call.function.name }
        return candidates.first { $0.action == action } ?? candidates.first { $0.action == "*" }
            ?? Entry(tool: call.function.name, action: action, effect: .unknown)
    }
}

extension Notification.Name {
    static let askToolPermissionsDidChange = Notification.Name("ask.toolPermissionsDidChange")
    static let askToolCatalogDidChange = Notification.Name("ask.toolCatalogDidChange")
}

extension SettingsStore {
    private static let permissionKey = "ask.toolPermissions.v1"
    private static let catalogKey = "ask.toolCatalog.v1"

    var discoveredToolPermissions: [AskToolAuthorizationEntry] {
        guard let data = defaults.data(forKey: Self.catalogKey) else { return [] }
        return (try? JSONDecoder().decode([AskToolAuthorizationEntry].self, from: data)) ?? []
    }
    var toolPermissionEntries: [AskToolAuthorizationEntry] {
        AskToolAuthorization.builtins + discoveredToolPermissions
    }
    var toolPermissionRevision: String {
        defaults.synchronize()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AskToolPolicy.digest(((try? encoder.encode(toolPermissionOverrides)) ?? Data()) +
                                   (defaults.data(forKey: Self.catalogKey) ?? Data()))
    }
    private var toolPermissionOverrides: [String: String] {
        defaults.dictionary(forKey: Self.permissionKey) as? [String: String] ?? [:]
    }
    private func permissionKey(_ entry: AskToolAuthorizationEntry, _ mode: AskPermissionMode) -> String {
        mode.rawValue + ":" + entry.id + ":" + entry.fingerprint
    }
    func toolPermission(_ entry: AskToolAuthorizationEntry, mode: AskPermissionMode) -> AskToolPermission {
        toolPermissionOverrides[permissionKey(entry, mode)].flatMap(AskToolPermission.init(rawValue:))
            ?? entry.defaultPermission(mode)
    }
    func toolPermission(_ call: AskToolCall, mode: AskPermissionMode) -> AskToolPermission {
        toolPermission(AskToolAuthorization.entry(for: call, discovered: discoveredToolPermissions), mode: mode)
    }
    func setToolPermission(_ permission: AskToolPermission, entry: AskToolAuthorizationEntry, mode: AskPermissionMode) {
        var values = toolPermissionOverrides
        values[permissionKey(entry, mode)] = permission == entry.defaultPermission(mode) ? nil : permission.rawValue
        defaults.set(values, forKey: Self.permissionKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: .askToolPermissionsDidChange, object: self)
        DistributedNotificationCenter.default().postNotificationName(.askToolPermissionsDidChange, object: nil,
                                                                      userInfo: nil, deliverImmediately: true)
    }
    func resetToolPermissions(mode: AskPermissionMode) {
        defaults.set(toolPermissionOverrides.filter { !$0.key.hasPrefix(mode.rawValue + ":") }, forKey: Self.permissionKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: .askToolPermissionsDidChange, object: self)
        DistributedNotificationCenter.default().postNotificationName(.askToolPermissionsDidChange, object: nil,
                                                                      userInfo: nil, deliverImmediately: true)
    }

    /// Registration is mandatory at the tool offering boundary, including tools added by future releases.
    /// External declarations are inventory, never trusted evidence of read-only behavior.
    func registerToolPermissions(_ definitions: [AskToolDefinition], identities: [String: String] = [:]) {
        var entries = discoveredToolPermissions
        for definition in definitions {
            let schema = (try? JSONSerialization.jsonObject(with: definition.parameters.data)) as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            let action = properties?["action"] as? [String: Any]
            let actions = action?["enum"] as? [String] ?? ["*"]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fingerprint = AskToolPolicy.digest((identities[definition.name] ?? "") +
                String(decoding: (try? encoder.encode(definition)) ?? Data(), as: UTF8.self))
            let known = AskToolAuthorization.builtins.filter { $0.tool == definition.name }
            // Replacing a dynamic schema invalidates its old grants and removes obsolete action rows.
            entries.removeAll { $0.tool == definition.name }
            for action in actions where !known.contains(where: { $0.action == action || $0.action == "*" }) {
                entries.append(.init(tool: definition.name, action: action, effect: .unknown, fingerprint: fingerprint))
            }
        }
        entries.sort { $0.id < $1.id }
        guard entries != discoveredToolPermissions, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.catalogKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: .askToolCatalogDidChange, object: self)
        DistributedNotificationCenter.default().postNotificationName(.askToolCatalogDidChange, object: nil,
                                                                      userInfo: nil, deliverImmediately: true)
    }
}
