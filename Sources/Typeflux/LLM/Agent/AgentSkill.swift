import Foundation

/// Skill 定义 — 可组合的工具集合 + 提示词补充
struct AgentSkill: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var enabled: Bool
    /// 系统提示词补充（会追加到 Agent 系统提示中）
    var systemPromptSupplement: String
    /// Skill 包含的工具名称列表
    var toolNames: [String]

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        enabled: Bool = true,
        systemPromptSupplement: String = "",
        toolNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.enabled = enabled
        self.systemPromptSupplement = systemPromptSupplement
        self.toolNames = toolNames
    }
}

/// 内置 Skill 标识
enum BuiltinSkillName: String, CaseIterable, Sendable {
    case commandExecution = "command_execution"
    case webAccess = "web_access"
}

/// 内置 Skill 目录
enum BuiltinSkillCatalog {
    /// 命令行执行 Skill
    static func commandExecution() -> AgentSkill {
        AgentSkill(
            name: BuiltinSkillName.commandExecution.rawValue,
            description: "Run shell commands locally to retrieve system information, manipulate files, or perform calculations.",
            enabled: false,
            systemPromptSupplement: """
            You have access to a shell command execution tool. Use it when you need to:
            - Get system information (date, hostname, environment)
            - Perform file operations (list files, read file content)
            - Run simple calculations or data transformations
            Always explain what command you're about to run and why. Prefer safe, read-only commands.
            """,
            toolNames: [BuiltinToolName.shellCommand.rawValue]
        )
    }

    /// 网络访问 Skill
    static func webAccess() -> AgentSkill {
        AgentSkill(
            name: BuiltinSkillName.webAccess.rawValue,
            description: "Fetch content from URLs to look up information, check APIs, or retrieve web page content.",
            enabled: false,
            systemPromptSupplement: """
            You have access to a web fetch tool. Use it when you need to:
            - Look up information from a URL
            - Check API endpoints
            - Retrieve web page content for analysis
            Always tell the user which URL you're fetching and why.
            """,
            toolNames: [BuiltinToolName.webFetch.rawValue]
        )
    }

    /// 所有内置 Skills
    static var all: [AgentSkill] {
        [commandExecution(), webAccess()]
    }
}
