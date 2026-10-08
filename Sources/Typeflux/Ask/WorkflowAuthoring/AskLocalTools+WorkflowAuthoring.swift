import Foundation

extension AskLocalTools {
    var workflowAuthoringEnabled: Bool {
        workflowAuthoring != nil && enabledSkills.contains { $0.name == AskWorkflowAuthorSkill.name }
    }

    static var workflowChatDefinitions: [AskToolDefinition] {
        func definition(_ name: String, _ description: String, _ properties: [String: Any]) -> AskToolDefinition {
            let schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
            return .init(name: name, description: description,
                         parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema)))
        }
        return AskWorkflowAuthorTools.definitions + [
            definition("workflow_list", "Find installed reusable launcher tools and load workflow authoring instructions. Listing does not open a draft. To create or edit, call workflow_start next, then workflow_read.", [:]),
            definition("workflow_start", "Start a new draft with name, or open an installed workflow by workflow_id. Required before proposing, testing or saving. Check workflow_read for an existing draft first; never replace unsaved work.",
                       ["name": ["type": "string"], "workflow_id": ["type": "string"]]),
            definition("workflow_save", "Request saving the current draft to the launcher. The user must explicitly choose Save in the preview panel; this tool never installs automatically.", [:])
        ]
    }

    static var workflowChatNames: Set<String> {
        AskWorkflowAuthorTools.names.union(["workflow_start", "workflow_list", "workflow_save"])
    }

    func workflowBinding(_ call: AskToolCall, conversationId: String) throws -> AskToolBinding {
        guard workflowAuthoringEnabled, let authoring = workflowAuthoring,
              let definition = Self.workflowChatDefinitions.first(where: { $0.name == call.function.name }) else {
            throw AskLocalError.message(L("ask.tool.unavailable"))
        }
        let session = authoring.session(conversationId)
        let stamp = (session?.revision.uuidString ?? "empty") + ":" + (session?.expectedHash ?? "new")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(target: .init(kind: "workspace", id: "workflow:" + authoring.owner() + ":" + conversationId,
                                  version: stamp),
                     toolVersion: AskToolPolicy.digest(try encoder.encode(definition)),
                     summary: (session?.draft.manifest?.name ?? L("ask.workflow.chat.title"))
                        + (call.function.name == AskWorkflowAuthorTools.test ? " — " + L("ask.workflow.chat.runNotice") : ""),
                     allowsReuse: false)
    }

    func executeWorkflow(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput {
        guard workflowAuthoringEnabled, let authoring = workflowAuthoring else {
            throw AskLocalError.message(L("ask.tool.unavailable"))
        }
        let args = try Self.jsonArguments(call.function.arguments)
        let instructions = enabledSkills.first { $0.name == AskWorkflowAuthorSkill.name }?.body
            ?? AskWorkflowAuthorSkill.chatInstructions
        if call.function.name == "workflow_list" {
            authoring.workflows.reload()
            let values = authoring.workflows.workflows.map {
                ["id": $0.id, "name": $0.manifest?.name ?? $0.id,
                 "keywords": $0.manifest?.keywords.map(\.keyword).joined(separator: ", ") ?? ""]
            }
            return .init(content: AskWorkflowAuthorTools.json([
                "workflows": values,
                "hasDraft": authoring.session(conversationId) != nil,
                "nextStep": "Listing does not open a draft. Read an existing draft, or call workflow_start with name (new tool) or workflow_id (installed tool), then workflow_read.",
                "instructions": instructions
            ]))
        }
        if call.function.name == "workflow_start" {
            let name = String((args["name"] as? String ?? L("ask.workflow.chat.title")).prefix(200))
            _ = try authoring.start(conversationId, name: name, workflowID: args["workflow_id"] as? String)
            return .init(content: AskWorkflowAuthorTools.json([
                "hasDraft": true,
                "nextStep": "Draft opened. Use workflow_read, check the environment and keyword, then workflow_propose.",
                "instructions": instructions
            ]))
        }
        if call.function.name == AskWorkflowAuthorTools.environment {
            var tools = AskWorkflowAuthorTools()
            tools.probe = workflowEnvironmentProbe
            let output = await tools.environment(args)
            var report = (try? JSONSerialization.jsonObject(with: Data(output.content.utf8))) as? [String: Any] ?? [:]
            report["hasDraft"] = authoring.session(conversationId) != nil
            report["nextStep"] = "For a reusable tool, use workflow_list for authoring instructions and existing tools, then workflow_start if there is no draft. URLs and domains are websites, not executable commands."
            return .init(content: AskWorkflowAuthorTools.json(report), isError: output.isError)
        }
        guard let session = authoring.session(conversationId) else {
            let state: [String: Any] = [
                "hasDraft": false,
                "nextStep": "Call workflow_start with name (new tool) or workflow_id (installed tool), then workflow_read. workflow_list only lists tools; it does not open a draft. Do not retry draft operations before workflow_start succeeds.",
                "instructions": instructions
            ]
            // An absent draft is normal discovery state, not a failed read.
            return .init(content: AskWorkflowAuthorTools.json(state),
                         isError: call.function.name != AskWorkflowAuthorTools.read)
        }
        if call.function.name == "workflow_save" {
            session.isPresented = true
            authoring.onChange?()
            guard session.problems.isEmpty else {
                return .init(content: AskWorkflowAuthorTools.json([
                    "status": "invalid_draft", "saved": false,
                    "problems": session.problems,
                    "nextStep": "Submit a valid workflow_propose before asking the user to save. The preview still shows the current draft."
                ]), isError: true)
            }
            return .init(content: "Not saved yet. Ask the user to choose Save in the workflow preview panel.")
        }
        let output = await AskWorkflowAuthorTools().execute(call, host: session)
        if call.function.name == AskWorkflowAuthorTools.read, args["path"] == nil,
           var object = try JSONSerialization.jsonObject(with: Data(output.content.utf8)) as? [String: Any] {
            object["hasUnsavedChanges"] = session.isDirty
            object["hasDraft"] = true
            object["revision"] = session.revision.uuidString
            return .init(content: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self),
                         isError: output.isError)
        }
        return .init(content: output.content, isError: output.isError)
    }
}
