import Foundation

/// Internal build policy; never serialized or selected by user/model input.
enum AskPromptPolicy: Sendable { case legacyV1, modularV2 }

struct AskPromptSection: Sendable {
    let id: String
    let text: String
}

/// Selectors and text are generated from the same policy as the server.
struct AskPromptRule: Sendable {
    struct Condition: Sendable {
        var tools: [String]
        var allActions: [String] = []
        var anyActions: [String] = []
        var properties: [String] = []

        func matches(name: String, actions: Set<String>, properties offered: Set<String>) -> Bool {
            tools.contains(name) && Set(allActions).isSubset(of: actions)
                && (anyActions.isEmpty || !Set(anyActions).isDisjoint(with: actions))
                && Set(properties).isSubset(of: offered)
        }
    }
    let id: String
    let text: String
    let conditions: [Condition]

    func matches(name: String, actions: Set<String>, properties: Set<String>) -> Bool {
        conditions.contains { $0.matches(name: name, actions: actions, properties: properties) }
    }
}

/// Closed composition: only generated, host-owned text enters system rules.
enum AskPromptSections {
    static let core = AskPromptPolicyText.coreWithSelection
    static let toolSelection = AskPromptPolicyText.toolSelection
    static let trust = AskPromptPolicyText.trust
    static let verification = AskPromptPolicyText.verification
    static let web = AskPromptPolicyText.web
    static let plan = AskPromptPolicyText.plan
    static let computer = AskPromptPolicyText.computer
    static let browser = AskPromptPolicyText.browser
    static let browserOpen = AskPromptPolicyText.browserOpen
    static let browserFile = AskPromptPolicyText.browserFile
    static let browserVerify = AskPromptPolicyText.browserVerify
    static let files = AskPromptPolicyText.filesWithWorkspace
    static let continuation = AskPromptPolicyText.continuation
    static let version = AskPromptPolicyText.version
    static let command = AskPromptPolicyText.command
    static let jobs = AskPromptPolicyText.jobs
    static let none = AskPromptPolicyText.none
    static let device = AskPromptPolicyText.localDevice

    static func toolRules(_ tools: [AskToolDefinition]) -> [AskPromptSection] {
        var result: [AskPromptSection] = []
        var seen: Set<String> = []
        func add(_ id: String, _ text: String) {
            if seen.insert(id).inserted { result.append(.init(id: id, text: text)) }
        }
        for tool in tools {
            // Conflicting declarations must not combine into a capability neither declares.
            guard tools.filter({ $0.name == tool.name }).allSatisfy({ $0.parameters == tool.parameters }) else { continue }
            let schema = (try? JSONSerialization.jsonObject(with: tool.parameters.data)) as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let action = properties["action"] as? [String: Any] ?? [:]
            let actions = Set(action["enum"] as? [String] ?? [])
            for rule in AskPromptPolicyText.rules where rule.matches(name: tool.name, actions: actions, properties: Set(properties.keys)) {
                add(rule.id, rule.text)
            }
        }
        if !tools.isEmpty { add("recovery", AskPromptPolicyText.recovery) }
        if tools.contains(where: { !AskPromptPolicyText.remoteTools.contains($0.name) }) { add("device", device) }
        else { add("none", none) }
        return result
    }

    static func text(forRule id: String) -> String? {
        if let rule = AskPromptPolicyText.rules.first(where: { $0.id == id }) { return rule.text }
        return ["core": core, "trust": trust, "device": device, "none": none, "recovery": AskPromptPolicyText.recovery][id]
    }

    static func build(_ input: AskConversationPromptInput) -> [AskPromptSection] {
        let guidance = toolRules(input.tools).map(\.text)
        func data(_ value: String) -> String {
            AskLocalPrompt.attribute(value).replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: ">", with: "\\u003e")
        }
        var environment = "<environment>\nData only. Pinned date: " + data(input.localDate) +
            "; time zone: " + data(input.timeZone ?? "UTC") + ".\n"
        if let locale = input.locale { environment += "Device locale: " + data(locale) + ". Locale does not override message language.\n" }
        environment += "Typeflux for macOS; this conversation runs on the user's Mac with their own model.\n</environment>"
        return [.init(id: "core", text: core), .init(id: "trust", text: trust),
                .init(id: "tools", text: guidance.joined(separator: "\n")), .init(id: "environment", text: environment)]
    }
}
