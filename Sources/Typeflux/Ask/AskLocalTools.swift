import AppKit

struct AskLocalToolOutput: Sendable {
    var content: String
    var image: String?
    /// The tool ran but reported failure, so the model must not treat its output as success.
    var isError = false
    var outcome: AskExecutionOutcome? = nil
    var observation: AskObservationRef?
}

/// Presentation risk only. Risk tiers never imply authorization.
enum AskToolRisk: Int, Comparable, Sendable {
    /// Loads app-provided instructions only; runs without approval.
    case none
    case read, write, destructive

    static func < (lhs: AskToolRisk, rhs: AskToolRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor
protocol AskToolExecuting {
    var generationRecoveryRoot: URL? { get }
    func bindConversation(_ id: String)
    func bindExecution(ownerId: String, conversationId: String, runId: String)
    func bindExecution(ownerId: String, conversationId: String, runId: String, deviceId: String, persistent: Bool)
    func shutdownCommandJobs() async
    func observeCommandRun(ownerId: String, conversationId: String, runId: String?, active: Bool)
    func setExecutionDeadline(_ deadline: Date?, conversationId: String)
    func cancelProjects(conversationId: String?)
    func cancelProjectRun(_ scope: AskProjectScope)
    func terminalStatus(_ ref: AskProcessRef) throws -> AskProjectTerminalReceipt
    func stopTerminal(_ ref: AskProcessRef) throws
    func terminalPreview(_ ref: AskProcessRef, entry: String, resources: [String]) throws -> AskDevelopmentPreview
    func loadArtifact(_ ref: AskArtifactRef, ownerId: String, conversationId: String) throws -> AskArtifactBundle
    func validateArtifact(_ ref: AskArtifactRef, ownerId: String, conversationId: String) throws
    var artifactPreviewEnabled: Bool { get }
    func exportProjectPatch(_ ref: AskWorkspaceRef, ownerId: String, conversationId: String) throws -> Data
    func risk(of call: AskToolCall) -> AskToolRisk
    /// Tools usable from this conversation; tools that need an unavailable target are omitted.
    func definitions(conversationId: String?) async -> [AskToolDefinition]
    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput
    func approvalBinding(for call: AskToolCall, conversationId: String) async throws -> AskToolBinding
    func executeApproved(_ call: AskToolCall, conversationId: String, binding: AskToolBinding,
                         authorize: () throws -> Void) async throws -> AskLocalToolOutput
    /// The MCP server behind a tool call, for approvals; nil for built-in tools.
    func mcpServerName(of call: AskToolCall) -> String?
    func stageFolders(_ paths: [String], lifetime: AskFolderGrants.Lifetime, ownerId: String,
                      deviceId: String, conversationId: String, messageID: String, generation: UUID) throws
    func admitFolders(messageID: String, conversationId: String, runId: String) throws
    func discardFolderSubmission(messageID: String)
    func temporaryFolders(conversationId: String) -> [AskFolderGrants.Grant]
    func revokeFolder(_ id: UUID?, conversationId: String)
    func revokeTaskFolders(conversationId: String, runId: String?)
    func resetFolderSession()
    func deleteArtifacts(ownerId: String, conversationId: String) throws
    /// Typeflux's own browser panel, when this executor offers the `web_browser` tool.
    var browserWorkspace: AskBrowserWorkspace? { get }
}

extension AskToolExecuting {
    func bindExecution(ownerId: String, conversationId: String, runId: String, deviceId: String, persistent: Bool) {
        bindExecution(ownerId: ownerId, conversationId: conversationId, runId: runId)
    }
    func shutdownCommandJobs() async {}
    func observeCommandRun(ownerId: String, conversationId: String, runId: String?, active: Bool) {}
    var generationRecoveryRoot: URL? { nil }
    var browserWorkspace: AskBrowserWorkspace? { nil }
    func setExecutionDeadline(_: Date?, conversationId _: String) {}
    func deleteArtifacts(ownerId _: String, conversationId _: String) throws {}
    func cancelProjects(conversationId _: String?) {}
    func cancelProjectRun(_: AskProjectScope) {}
    func terminalStatus(_: AskProcessRef) throws -> AskProjectTerminalReceipt { throw AskProjectRuntimeError.disabled }
    func stopTerminal(_: AskProcessRef) throws { throw AskProjectRuntimeError.disabled }
    func terminalPreview(_: AskProcessRef, entry _: String, resources _: [String]) throws -> AskDevelopmentPreview {
        throw AskProjectRuntimeError.disabled
    }
    func validateArtifact(_ ref: AskArtifactRef, ownerId: String, conversationId: String) throws {
        _ = try loadArtifact(ref, ownerId: ownerId, conversationId: conversationId)
    }
    var artifactPreviewEnabled: Bool { false }
    func loadArtifact(_: AskArtifactRef, ownerId _: String, conversationId _: String) throws -> AskArtifactBundle {
        throw AskArtifactError.unavailable
    }
    func bindExecution(ownerId _: String, conversationId _: String, runId _: String) {}
    func exportProjectPatch(_: AskWorkspaceRef, ownerId _: String, conversationId _: String) throws -> Data { throw AskProjectError.unavailable }
    func mcpServerName(of _: AskToolCall) -> String? { nil }
    func stageFolders(_: [String], lifetime _: AskFolderGrants.Lifetime, ownerId _: String,
                      deviceId _: String, conversationId _: String, messageID _: String, generation _: UUID) throws {}
    func admitFolders(messageID _: String, conversationId _: String, runId _: String) throws {}
    func discardFolderSubmission(messageID _: String) {}
    func temporaryFolders(conversationId _: String) -> [AskFolderGrants.Grant] {
        []
    }

    func revokeFolder(_: UUID?, conversationId _: String) {}
    func revokeTaskFolders(conversationId _: String, runId _: String? = nil) {}
    func resetFolderSession() {}
    func executeApproved(_ call: AskToolCall, conversationId: String, binding: AskToolBinding,
                         authorize: () throws -> Void) async throws -> AskLocalToolOutput {
        let current = try await approvalBinding(for: call, conversationId: conversationId)
        try Task.checkCancellation()
        guard current == binding else { throw AskLocalError.message(L("ask.approval.changed")) }
        try authorize()
        return try await execute(call, conversationId: conversationId)
    }
}

/// Calls require conversation approval or screenshot consent from the submitted draft.
/// All calls pass through the persistent execution journal before reaching this executor.
@MainActor
final class AskLocalTools: AskToolExecuting {
    let registry: MCPRegistry
    private var mcpTools: [String: MCPToolAdapter] = [:]
    private var mcpServers: [String: String] = [:]
    var mcpIdentities: [String: UUID] = [:]
    var targetApplication: NSRunningApplication?
    var targets: [String: NSRunningApplication] = [:]
    let settings: SettingsStore?
    let sandbox: AskCodeSandbox
    let skills: AskSkillLibrary
    private let notes: AskMemoryNoteStore
    var fileOperationHooks = AskFileTools.Hooks()
    let folderGrants: AskFolderGrants
    var folderSubmissions: [String: AskFolderGrants.Scope] = [:]
    var folderExecutions: [String: AskFolderGrants.Scope] = [:]
    let artifactStore: AskArtifactStore
    var imageGenerator: any AskImageGenerating = AskImageGenerationService()
    var executionDeadlines: [String: Date] = [:]
    /// Injectable configuration for tests; production reads the user's settings and Keychain.
    var imageConfigurationOverride: (() -> (AskImageConfiguration, String)?)?
    let artifactCreationEnabled: Bool
    let artifactPreviewEnabled: Bool
    let projects: AskProjectWorkspace
    /// Independent rollout gate; production composition leaves this disabled.
    let projectModeEnabled: Bool
    let workspaces: AskConversationWorkspaceStore?
    var projectScopes: [String: AskProjectScope] = [:]
    let commandJobs: AskCommandJobStore?
    var commandDeviceId: String
    var commandPersistence: [String: Bool] = [:]
    let projectRuntime: AskProjectRuntime?
    var projectLeases: [String: AskProjectRuntimeLease] = [:]
    var projectOutputBuffers: [String: AskTerminalTextBuffer] = [:]
    let owner: @MainActor () -> String
    let observationStore: AskObservationStore
    let browserExecutor: AskBrowserExecutor
    let computerExecutor: AskComputerExecutor
    let computerProbe = AskComputerTargetProbe()
    let screenObservation: AskScreenObservation
    /// The `web_browser` tool; nil leaves the tool out.
    var embeddedBrowser: AskEmbeddedBrowserTool?
    var browserWorkspace: AskBrowserWorkspace? { embeddedBrowser?.workspace }
    var conversationEpochs: [String: UUID] = [:]
    /// Native environment override for controlled integration tests.
    var computerEnvironment: ((NSRunningApplication?) -> AskComputerExecutor.Environment)?
    /// Running apps, injectable for tests.
    var runningBundleIdentifiers: () -> [String] = { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }

    init(registry: MCPRegistry, runner: any ProcessCommandRunning = AskAutomationScriptRunner(), settings: SettingsStore? = nil,
         sandbox: AskCodeSandbox? = nil, skills: AskSkillLibrary = AskSkillLibrary(), notes: AskMemoryNoteStore = .shared,
         folderGrants: AskFolderGrants = AskFolderGrants(),
         projects: AskProjectWorkspace = AskProjectWorkspace(), projectModeEnabled: Bool = false,
         workspaces: AskConversationWorkspaceStore? = nil,
         artifactStore: AskArtifactStore = AskArtifactStore(), artifactCreationEnabled: Bool = false,
         artifactPreviewEnabled: Bool = false,
         projectRuntime: AskProjectRuntime? = nil,
         commandJobs: AskCommandJobStore? = nil,
         screenObservation: AskScreenObservation? = nil,
         owner: @escaping @MainActor () -> String = { GlobalSoulOwner.currentID }) {
        self.commandJobs = commandJobs
        commandDeviceId = settings?.defaults.string(forKey: "ask.deviceId") ?? UUID().uuidString
        self.registry = registry; self.settings = settings
        self.screenObservation = screenObservation ?? AskScreenObservation()
        let store = AskObservationStore()
        observationStore = store
        browserExecutor = AskBrowserExecutor(store: store, runner: runner)
        computerExecutor = AskComputerExecutor(store: store)
        self.skills = skills; self.notes = notes; self.folderGrants = folderGrants; self.owner = owner
        self.artifactStore = artifactStore
        self.artifactCreationEnabled = artifactCreationEnabled
        self.artifactPreviewEnabled = artifactPreviewEnabled
        self.projects = projects; self.projectModeEnabled = projectModeEnabled; self.workspaces = workspaces
        self.projectRuntime = projectRuntime
        self.sandbox = sandbox ?? AskCodeSandbox(readableDirectories: [skills.userDirectory])
    }

    func bindConversation(_ id: String) {
        targets[id] = targetApplication
        conversationEpochs[id] = UUID()
        for tool in ["browser", "computer"] {
            observationStore.invalidate(scope: observationScope(tool, conversationId: id))
        }
    }

    func workspaceURL(conversationId: String) -> URL? {
        workspaces?.url(owner: owner(), conversationId: conversationId)
    }

    /// The user's notes, for the `notebook` tool; nil leaves the tool and its skill out.
    var notebook: (any AskNoteStoring)?

    /// The notebook is set and the user lets the agent use it: neither the notes window's
    /// switch nor the `notebook` skill in Settings › Skills is off.
    var notebookAvailable: Bool {
        notebook != nil && settings?.askNotebookAgentEnabled != false
            && settings?.askDisabledSkills.contains(AskNotebookSkill.name) != true
    }

    var notebookTool: AskNotebookTool? {
        guard notebookAvailable, let notebook else { return nil }
        let hiddenTags = settings?.askNotebookHiddenTags ?? SettingsStore.defaultNotebookHiddenTags
        return AskNotebookTool(store: notebook, hiddenTags: hiddenTags, validateAccess: { [weak self] in
            guard let self, self.notebookAvailable, self.notebook === notebook,
                  (self.settings?.askNotebookHiddenTags ?? SettingsStore.defaultNotebookHiddenTags) == hiddenTags else {
                throw AskLocalError.message(L("ask.approval.changed"))
            }
        })
    }

    var workflowAuthoring: AskWorkflowAuthoringStore?
    var workflowEnvironmentProbe = AskWorkflowEnvironmentProbe()

    /// Skills the user has not turned off in settings.
    var enabledSkills: [AskSkill] {
        var disabled = settings?.askDisabledSkills ?? []
        if !notebookAvailable { disabled.insert(AskNotebookSkill.name) }
        return skills.skills().filter { !disabled.contains($0.name) }
    }

    /// The bound browser, or a running Safari/Chrome when the question started elsewhere.
    func browserBundle(conversationId: String?) -> String? {
        // An existing conversation only controls the app it was bound to, which is gone after a restart.
        let target = conversationId.map { targets[$0] } ?? targetApplication
        if let bundle = target?.bundleIdentifier, Self.isSupportedBrowser(bundle) { return bundle }
        let running = runningBundleIdentifiers()
        return ["com.apple.Safari", "com.google.Chrome"].first(where: running.contains)
    }

    func definitions(conversationId: String?) async -> [AskToolDefinition] {
        await registry.connectAutoConnectServers()
        var result = automationDefinitions
            .filter { $0.name != "browser" || browserBundle(conversationId: conversationId) != nil }
        let metadataRoots = fileTools(conversationId: conversationId)
            .roots + (conversationId.map(folderMetadataRoots) ?? [])
        if let files = AskFileTools.definition(roots: Array(Set(metadataRoots)).sorted()) {
            result.append(files)
        }
        if projectModeEnabled, !fileTools(conversationId: conversationId).roots.isEmpty,
           let project = try? Self.projectDefinition(roots: fileTools(conversationId: conversationId).roots) {
            result.append(project)
            if artifactCreationEnabled { result.append(Self.artifactDefinition) }
            if projectRuntime != nil { result.append(Self.terminalDefinition) }
        }
        if settings?.askCodeExecutionEnabled == true, let code = sandbox.definition() { result.append(code) }
        if settings?.askCodeExecutionEnabled == true { result.append(AskHostCommand.definition) }
        if commandJobs != nil { result.append(AskCommandJobRequest.definition(allowStart: settings?.askCodeExecutionEnabled == true)) }
        if let skill = skills.definition(enabledSkills) { result.append(skill) }
        if workflowAuthoringEnabled { result += Self.workflowChatDefinitions }
        result.append(AskMemoryNoteStore.definition)
        if embeddedBrowser != nil { result.append(AskEmbeddedBrowserTool.definition) }
        if notebookAvailable { result.append(AskNotebookTool.definition) }
        if imageConfiguration != nil { result.append(Self.imageGenerationDefinition) }
        mcpTools = [:]
        mcpServers = [:]
        mcpIdentities = [:]
        var schemaBytes = result.reduce(0) { $0 + $1.parameters.data.count }
        for (name, entry) in Self.mcpToolNames(await registry.registeredTools()) {
            let tool = entry.tool
            guard mcpTools[name] == nil,
                  let schema = try? JSONSerialization.data(withJSONObject: tool.definition.inputSchema.jsonObject, options: .sortedKeys),
                  schema.count <= 32000, schemaBytes + schema.count <= 500000 else { continue }
            schemaBytes += schema.count
            mcpTools[name] = tool
            mcpServers[name] = entry.serverName
            mcpIdentities[name] = entry.serverId
            result.append(.init(name: name, description: String(tool.definition.description.prefix(2000)), parameters: JSONValue(data: schema)))
            if result.count == 64 { break }
        }
        settings?.registerToolPermissions(result, identities: await registry.authorizationIdentities())
        return result
    }

    func mcpServerName(of call: AskToolCall) -> String? { mcpServers[call.function.name] }

    /// External annotations are hints, never evidence of a trusted read-only tool.
    func risk(of call: AskToolCall) -> AskToolRisk {
        AskToolAuthorization.entry(for: call, discovered: settings?.discoveredToolPermissions ?? []).risk
    }

    nonisolated static func builtinRisk(_ call: AskToolCall) -> AskToolRisk {
        AskToolAuthorization.entry(for: call).risk
    }

    nonisolated static func isSupportedBrowser(_ bundleIdentifier: String?) -> Bool {
        ["com.apple.Safari", "com.google.Chrome"].contains(bundleIdentifier ?? "")
    }

    /// `mcp_<tool>` when the tool name is unique; otherwise the server name qualifies it.
    /// Names that are invalid or still collide are skipped rather than shadowing another tool.
    nonisolated static func mcpToolNames(_ tools: [MCPRegisteredTool]) -> [(String, MCPRegisteredTool)] {
        var counts: [String: Int] = [:]
        for entry in tools { counts[entry.tool.toolDef.name, default: 0] += 1 }
        var used = Set<String>()
        var result: [(String, MCPRegisteredTool)] = []
        for entry in tools {
            let toolName = entry.tool.toolDef.name
            let name = counts[toolName] == 1
                ? "mcp_" + toolName
                : "mcp_" + serverSlug(entry.serverName, id: entry.serverId) + "_" + toolName
            guard name.count <= 64, name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  used.insert(name).inserted else { continue }
            result.append((name, entry))
        }
        return result
    }

    nonisolated static func serverSlug(_ name: String, id: UUID) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let slug = mapped.split(separator: "_").joined(separator: "_").prefix(20)
        return slug.isEmpty ? String(id.uuidString.prefix(8)).lowercased() : String(slug)
    }

    static let builtins = builtinDefinitions(computerWrites: false, browserWrites: false)

    var automationDefinitions: [AskToolDefinition] {
        Self.builtinDefinitions(computerWrites: computerExecutor.writesEnabled,
                                browserWrites: browserExecutor.writesEnabled)
    }

    private static func builtinDefinitions(computerWrites: Bool, browserWrites: Bool) -> [AskToolDefinition] {
        [definition("computer", description: computerWrites ? """
        Observe or control the user's desktop after approval, one action per call. Start with screenshot or inspect \
        (inspect lists the target app's accessibility elements with click coordinates). Every write requires a fresh \
        observation_id from this conversation; observe again after every action or needs-observation error. Coordinates \
        are fractions (0...1) of the observed display and must fall inside the observed window. Actions: click, double_click, right_click, drag (x,y to to_x,to_y), type, \
        key (return, tab, escape, backspace, delete, arrows, home, end, pageup, pagedown, space, f1-f12), hotkey \
        (e.g. "cmd+c", "cmd+shift+t"), scroll (requires x,y and amount), wait (seconds up to 5). Event dispatch does \
        not prove the business effect.
        """ : """
        Observe the user's desktop after approval, one action per call. screenshot captures the screen; inspect lists \
        the target app's accessibility elements; wait pauses for up to 5 seconds. Only observation is available. \
        Desktop control is unavailable; do not request click, typing, keyboard, drag or scroll actions.
        """, properties: [
            "observation_id": ["type": "string"],
            "action": ["type": "string", "enum": computerWrites
                ? ["screenshot", "inspect", "click", "double_click", "right_click", "drag", "type", "key", "hotkey", "scroll", "wait"]
                : ["screenshot", "inspect", "wait"]],
            "x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1],
            "to_x": ["type": "number", "minimum": 0, "maximum": 1], "to_y": ["type": "number", "minimum": 0, "maximum": 1],
            "text": ["type": "string"], "key": ["type": "string"], "keys": ["type": "string"],
            "amount": ["type": "integer", "minimum": -10, "maximum": 10], "seconds": ["type": "number", "minimum": 0, "maximum": 5]
        ]),
        definition("browser", description: browserWrites ? """
        Read or interact with the front Safari or Chrome tab after approval, one action per call. read returns URL, \
        visible text and links; snapshot lists interactive elements with versioned string refs. Every write requires \
        observation_id from the latest read/snapshot in this conversation. click/fill take an observed ref (or an \
        observed CSS selector); open navigates to an http(s) URL; back goes back; scroll moves by screens. Observe \
        again after every action or needs-observation error. Event dispatch does not prove the business effect.
        """ : """
        Read the front Safari or Chrome tab after approval, one action per call. read returns URL, visible text and \
        links; snapshot lists interactive elements with versioned string refs. Only observation is available. \
        Browser interaction is unavailable; do not request navigation, click, fill, back or scroll actions.
        """, properties: [
            "observation_id": ["type": "string"],
            "action": ["type": "string", "enum": browserWrites
                ? ["read", "snapshot", "open", "click", "fill", "back", "scroll"] : ["read", "snapshot"]], "url": ["type": "string"],
            "selector": ["type": "string"], "ref": ["type": "string"], "text": ["type": "string"],
            "amount": ["type": "integer", "minimum": -10, "maximum": 10]
        ])
        ]
    }

    private static func definition(_ name: String, description: String, properties: [String: Any]) -> AskToolDefinition {
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": ["action"], "additionalProperties": false]
        return .init(name: name, description: description, parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }

    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput {
        try Task.checkCancellation()
        if Self.workflowChatNames.contains(call.function.name) {
            guard call.function.name != AskWorkflowAuthorTools.test else {
                throw AskLocalError.message(L("ask.tool.unavailable"))
            }
            return try await executeWorkflow(call, conversationId: conversationId)
        }
        if let tool = mcpTools[call.function.name] {
            let output = try await tool.call(arguments: call.function.arguments)
            try Task.checkCancellation()
            // Decoding and re-encoding a tool image must not block the main actor.
            return await Self.output(from: output)
        }
        let args = try Self.jsonArguments(call.function.arguments)
        switch call.function.name {
        case "artifact", "project_files", "project_terminal", "generate_image", "run_command", "command_job":
            throw AskProjectError.denied // Requires the approved dispatch entry point.
        case "computer", "browser":
            return try await executeAutomation(call.function.name, args: args, conversationId: conversationId)
        case AskEmbeddedBrowserTool.name:
            guard let embeddedBrowser else { throw AskLocalError.message(L("ask.tool.unavailable")) }
            try validateBrowserLocalFile(args, conversationId: conversationId)
            return try await embeddedBrowser.execute(args, conversationId: conversationId)
        case "files":
            return try await executeFiles(args, conversationId: conversationId)
        case "run_code":
            guard settings?.askCodeExecutionEnabled == true,
                  let language = (args["language"] as? String).flatMap(AskCodeSandbox.Language.init(rawValue:)),
                  let code = args["code"] as? String, !code.isEmpty else { throw AskLocalError.message(L("ask.tool.invalid")) }
            let sandbox = sandbox
            let timeout = args["timeout_seconds"] as? Int ?? AskCodeSandbox.defaultTimeout
            let execution = try await sandbox.run(language, code: code, conversationId: conversationId, timeout: timeout)
            let workspace = try sandbox.workspace(for: conversationId).path
            let status: AskExecutionStatus = execution.timedOut ? .timeout
                : execution.outcomeUnknown || execution.imageIncomplete ? .unknown
                : execution.exitCode == 0 ? .ok : .failed
            return .init(content: AskCodeSandbox.report(execution, workspace: workspace), image: execution.image,
                         isError: status != .ok, outcome: .init(status: status.rawValue))
        case "skill":
            guard let name = args["name"] as? String else { throw AskLocalError.message(L("ask.tool.invalid")) }
            guard enabledSkills.contains(where: { $0.name == name }) else {
                throw AskLocalError.message(L("ask.skills.missing"))
            }
            return .init(content: try skills.load(name))
        case "memory":
            return .init(content: try notes.execute(args, owner: owner()))
        case AskNotebookTool.name:
            guard let tool = notebookTool else { throw AskLocalError.message(L("ask.tool.unavailable")) }
            guard AskNotebookTool.readActions.contains(args["action"] as? String ?? "") else {
                // Writes require the approved dispatch entry point.
                throw AskLocalError.message(L("ask.tool.unavailable"))
            }
            return .init(content: try await tool.execute(args))
        default: throw AskLocalError.message(L("ask.tool.unavailable"))
        }
    }

    /// Retains ordered typed content, with a conservative legacy projection.
    nonisolated static func output(from result: MCPToolsCallResult) async -> AskLocalToolOutput {
        await AskTypedContent.output(from: result)
    }

    nonisolated static func jsonArguments(_ value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8), let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        return args
    }

    nonisolated static func arguments(_ value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = args["action"] as? String, !action.isEmpty else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        return args
    }

    nonisolated static func javascriptLiteral(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }
    nonisolated static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

}
