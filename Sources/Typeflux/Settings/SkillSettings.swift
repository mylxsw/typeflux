import Foundation

/// Skill 设置存储
final class SkillSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let skillsKey = "agent.skills"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var skills: [AgentSkill] {
        get {
            guard let data = defaults.data(forKey: skillsKey),
                  let saved = try? JSONDecoder().decode([AgentSkill].self, from: data) else {
                return BuiltinSkillCatalog.all
            }
            return mergeWithBuiltins(saved)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: skillsKey)
            }
        }
    }

    func updateSkillEnabled(name: String, enabled: Bool) {
        var current = skills
        if let idx = current.firstIndex(where: { $0.name == name }) {
            current[idx].enabled = enabled
            skills = current
        }
    }

    func addSkill(_ skill: AgentSkill) {
        var current = skills
        current.append(skill)
        skills = current
    }

    func removeSkill(id: UUID) {
        skills = skills.filter { $0.id != id }
    }

    func resetToDefaults() {
        defaults.removeObject(forKey: skillsKey)
    }

    // MARK: - Private

    /// 确保内置 Skill 始终存在
    private func mergeWithBuiltins(_ saved: [AgentSkill]) -> [AgentSkill] {
        var result = saved
        let savedNames = Set(saved.map(\.name))
        for builtin in BuiltinSkillCatalog.all where !savedNames.contains(builtin.name) {
            result.append(builtin)
        }
        return result
    }
}
