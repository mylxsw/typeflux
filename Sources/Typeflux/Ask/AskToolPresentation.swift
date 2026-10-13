import Foundation

/// Localized titles for tool activity, independent of UI appearance.
enum AskToolPresentation {
    /// A readable title for a tool call; raw tool names never reach the transcript.
    /// `mcpServer` names the server of an MCP tool when the caller knows it.
    // This existing title router mirrors the supported tool families.
    // swiftlint:disable:next cyclomatic_complexity
    static func toolTitle(_ call: AskToolCall, mcpServer: String? = nil) -> String {
        let name = call.function.name
        if ["workflow_start", "workflow_list", "workflow_read", "workflow_environment", "workflow_check_keyword",
            "workflow_propose", "workflow_test", "workflow_save"].contains(name) {
            return L("ask.tool." + name)
        }
        if name == "web_search" || name == "web_fetch" {
            let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any]
            let detail = name == "web_search"
                ? args?["query"] as? String
                : (args?["url"] as? String).flatMap { URL(string: $0)?.host }
            let title = L(name == "web_search" ? "ask.tool.webSearch" : "ask.tool.webFetch")
            return detail.map { title + " · " + $0 } ?? title
        }
        let args = (try? AskLocalTools.jsonArguments(call.function.arguments)) ?? [:]
        switch name {
        case "generate_image": return L("imagegen.title")
        case "artifact": return L("ask.artifact.title")
        case "project_files": return L("ask.project.title") + " · " + (args["action"] as? String ?? "")
        case "update_plan": return L("ask.tool.update_plan")
        case "research":
            let question = (args["question"] as? String).map { String($0.prefix(60)) }
            return question.map { L("ask.tool.research") + " · " + $0 } ?? L("ask.tool.research")
        case "files":
            // Files actions carry their own verbs: "read" is shared with the browser's "read page".
            let action = args["action"] as? String ?? ""
            let title = ["list", "read", "search", "write", "edit"]
                .contains(action) ? L("ask.files.action." + action) : L("ask.tool.files")
            let target = action == "search" ? args["query"] as? String : (args["path"] as? String)
                .map { ($0 as NSString).lastPathComponent }
            return target.flatMap { $0.isEmpty ? nil : title + " · " + $0 } ?? title
        default: break
        }
        if name.hasPrefix("mcp_") {
            return (mcpServer ?? "MCP") + " · " + String(name.dropFirst(4))
        }
        if name == AskNotebookTool.name { return notebookToolTitle(args) }
        if ["memory", "run_code", "skill"].contains(name) {
            let title = L("ask.tool." + name)
            if name == "skill", let skill = args["name"] as? String { return title + " · " + skill }
            if name == "run_code", let language = args["language"] as? String { return title + " · " + language }
            if let action = args["action"] as? String,
               !action.isEmpty { return title + " · " + L("ask.action." + action) }
            return title
        }
        guard name == "computer" || name == "browser" else { return name }
        let action = (try? AskLocalTools.arguments(call.function.arguments)["action"] as? String) ?? ""
        let title = L("ask.tool." + name)
        return action.isEmpty ? title : title + " · " + L("ask.action." + action)
    }

    private static func notebookToolTitle(_ args: [String: Any]) -> String {
        let action = args["action"] as? String ?? ""
        let title = L("ask.tool.notebook")
        let detail = action == "search" ? args["query"] as? String : args["title"] as? String
        let verb = ["search", "read", "list", "create", "append", "update", "tag", "delete"].contains(action)
            ? " · " + L("ask.notebook.action." + action) : ""
        return title + verb + (detail.flatMap { $0.isEmpty ? nil : " · " + String($0.prefix(60)) } ?? "")
    }
}
