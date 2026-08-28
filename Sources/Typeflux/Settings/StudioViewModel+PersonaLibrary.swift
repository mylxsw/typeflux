import Foundation

extension StudioViewModel {
    var filteredBuiltInPersonas: [PersonaProfile] {
        filteredPersonas.filter(\.isSystem)
    }

    var filteredCustomPersonas: [PersonaProfile] {
        filteredPersonas.filter { !$0.isSystem }
    }

    /// Editing selection and the active default are deliberately independent.
    func isDefaultPersona(_ id: UUID?) -> Bool {
        guard let id else { return !personaRewriteEnabled || activePersonaID.isEmpty }
        return personaRewriteEnabled && UUID(uuidString: activePersonaID) == id
    }

    var isEditingDefaultPersona: Bool {
        !isCreatingPersonaDraft && isDefaultPersona(selectedPersonaID)
    }

    func personaListSubtitle(for persona: PersonaProfile) -> String {
        if persona.isSystem {
            if persona.id == SettingsStore.defaultPersonaID {
                return L("settings.personas.summary.typeflux")
            }
            if persona.id == UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA002") {
                return L("settings.personas.summary.translator")
            }
        }

        // Custom definitions have no summary field. Preview their real content without inventing one.
        let preview = personaDisplayPrompt(for: persona)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return preview.map { String($0.prefix(160)) } ?? L("settings.personas.customPersona")
    }
}
