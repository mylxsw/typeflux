import Foundation

/// Skill 注册表 — 管理 Skills 及其关联工具
actor AgentSkillRegistry {
    private var skills: [String: AgentSkill] = [:]
    private var skillTools: [String: [any AgentTool]] = [:]

    /// 注册 Skill 及其工具
    func register(skill: AgentSkill, tools: [any AgentTool]) {
        skills[skill.name] = skill
        skillTools[skill.name] = tools
    }

    /// 移除 Skill
    func unregister(name: String) {
        skills.removeValue(forKey: name)
        skillTools.removeValue(forKey: name)
    }

    /// 获取所有已启用 Skills 的工具
    func enabledTools() -> [any AgentTool] {
        skills.values
            .filter(\.enabled)
            .flatMap { skill in skillTools[skill.name] ?? [] }
    }

    /// 获取所有已启用 Skills 的系统提示词补充
    func enabledPromptSupplements() -> [String] {
        skills.values
            .filter(\.enabled)
            .map(\.systemPromptSupplement)
            .filter { !$0.isEmpty }
    }

    /// 获取所有已注册的 Skills
    var allSkills: [AgentSkill] {
        Array(skills.values)
    }

    /// 获取已启用的 Skills
    var enabledSkills: [AgentSkill] {
        skills.values.filter(\.enabled)
    }

    /// 更新 Skill 的启用状态
    func setEnabled(name: String, enabled: Bool) {
        guard var skill = skills[name] else { return }
        skill.enabled = enabled
        skills[name] = skill
    }

    /// 检查 Skill 是否存在
    func hasSkill(name: String) -> Bool {
        skills[name] != nil
    }

    /// 获取指定 Skill
    func skill(named name: String) -> AgentSkill? {
        skills[name]
    }
}
