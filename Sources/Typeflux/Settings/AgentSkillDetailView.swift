import SwiftUI

/// Everything known about one skill, with its enable switch and maintenance actions.
struct AgentSkillDetailView: View {
    let skill: AskSkill
    let badge: (text: String, accent: Bool)
    let source: AskSkillSource?
    @Binding var enabled: Bool
    let canRollback: Bool
    let onRollback: () -> Void
    let onReveal: (() -> Void)?
    let onRemove: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        TypefluxSheet(title: skill.name, cancelTitle: L("common.cancel"), confirmTitle: L("common.done"),
                      cancel: onClose, confirm: onClose) {
            TypefluxForm {
                Section {
                    TypefluxSettingsRow(badge.text, description: skill.displayDescription) {
                        Toggle(skill.name, isOn: $enabled).labelsHidden().toggleStyle(.switch)
                    }
                    Text(L(enabled ? "agent.skills.enabledHint" : "agent.skills.disabledHint"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    if let source {
                        detailRow(L("agent.skills.repository"), source.repository)
                        detailRow(L("agent.skills.version"),
                                  "\(source.ref) · \(source.commit.map { String($0.prefix(7)) } ?? L("ask.settings.skills.unverifiedVersion"))")
                        detailRow(L("agent.skills.path"), source.path.isEmpty ? "/" : source.path)
                    } else if skill.directory == nil {
                        detailRow(L("agent.skills.source"), L("agent.skills.builtinSource"))
                    } else if let directory = skill.directory {
                        detailRow(L("agent.skills.path"), directory.path)
                    }
                }
                if let declared = source?.declaredPermissions, !declared.isEmpty {
                    TypefluxFormSection(L("agent.skills.declared"), footer: L("agent.skills.declaredHint")) {
                        ForEach(declared, id: \.self) { Text($0).font(.body).textSelection(.enabled) }
                    }
                }
                Section {
                    if canRollback {
                        Button(action: onRollback) {
                            Label(L("ask.settings.skills.rollback"), systemImage: "arrow.uturn.backward")
                        }
                    }
                    if let onReveal {
                        Button(L("agent.skills.reveal"), action: onReveal)
                    }
                    if let onRemove {
                        Button(L("ask.remove"), role: .destructive, action: onRemove)
                    }
                }
            }.frame(height: 440)
        }.frame(width: 520)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        TypefluxSettingsRow(title) {
            Text(value).font(.body.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
