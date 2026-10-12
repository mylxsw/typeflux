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

extension StudioViewModel {
    var personaStoreDiffersFromPublishedState: Bool {
        let store = askToolSettings
        return activePersonaID != store.activePersonaID
            || personaRewriteEnabled != store.personaRewriteEnabled
            || auxiliaryPersonaID != store.auxiliaryPersona.id.uuidString
            || personaAppBindings != store.personaAppBindings
            || personaAppBindingsEnabled != store.personaAppBindingsEnabled
    }

    func openPersonaShortcutSettings() {
        settingsPaneRequest = .hotkeys
        navigate(to: .settings)
    }

    func personaTitle(_ id: UUID?) -> String {
        guard let id else { return L("personas.redesign.none") }
        return personas.first { $0.id == id }?.name ?? L("settings.personaAppBindings.missingPersona")
    }

    var personaDraftTemplateTitle: String {
        personaDraftTemplateID.map { personaTitle($0) } ?? L("personas.redesign.blank")
    }

    var pausedPersonaAppRuleCount: Int {
        personaAppBindings.filter { !personaAppBindingsEnabled || !$0.isEnabled }.count
    }

    func hasPersonaAppRule(_ identifier: String) -> Bool {
        let normalized = PersonaAppBinding.normalize(identifier)
        return personaAppBindings.contains { PersonaAppBinding.normalize($0.appIdentifier) == normalized }
    }

    func hasPersonaAppRule(for candidate: PersonaAppCandidate) -> Bool {
        hasPersonaAppRule(candidate.preferredIdentifier) || hasPersonaAppRule(candidate.displayName)
    }

    func openPersonaAppRules(adding: Bool = false, preset: UUID? = nil) {
        isPersonaRulesDrawerPresented = true
        isAddingPersonaAppRule = adding
        personaAppBindingDraftIdentifier = ""
        personaAppBindingDraftPersonaID = preset.flatMap { id in personas.contains { $0.id == id } ? id : nil }
            ?? defaultPersonaSelectionID
    }

    func closePersonaAppRules() {
        isPersonaRulesDrawerPresented = false
        isAddingPersonaAppRule = false
        personaAppBindingDraftIdentifier = ""
    }

    func toggleDefaultPersona(_ id: UUID) {
        guard personas.contains(where: { $0.id == id }) else { return }
        setDefaultPersonaSelection(isDefaultPersona(id) ? nil : id)
    }

    func useAuxiliaryPersona(_ id: UUID) {
        guard personas.contains(where: { $0.id == id }) else { return }
        if auxiliaryPersonaID == id.uuidString {
            showToast(L("personas.redesign.auxiliaryRequired"))
        } else {
            setAuxiliaryPersona(id.uuidString)
        }
    }

    func selectPersonaGuardingDraft(_ id: UUID?) {
        guard isCreatingPersonaDraft || selectedPersonaID != id else { return }
        guard id == nil || personas.contains(where: { $0.id == id }) else { return }
        requestPersonaNavigation(.select(id))
    }

    func beginCreatingPersona(template: UUID? = nil, name: String = "") {
        requestPersonaNavigation(.create(name: name, template: template))
    }

    func duplicatePersona(_ persona: PersonaProfile) {
        guard personas.contains(where: { $0.id == persona.id }) else { return }
        requestPersonaNavigation(.duplicate(persona.id))
    }

    private func requestPersonaNavigation(_ action: PersonaDraftNavigation) {
        if hasPersonaDraftChanges {
            pendingPersonaNavigation = action
        } else {
            performPersonaNavigation(action)
        }
    }

    func resolvePersonaDraftGuard(_ decision: PersonaDraftDecision) {
        guard let action = pendingPersonaNavigation else { return }
        switch decision {
        case .cancel:
            pendingPersonaNavigation = nil
            return
        case .save:
            guard canSavePersonaDraft else { return }
            savePersonaDraft()
        case .discard:
            break
        }
        pendingPersonaNavigation = nil
        performPersonaNavigation(action)
    }

    private func performPersonaNavigation(_ action: PersonaDraftNavigation) {
        // Template undo belongs to the current creation editor only.
        if case .template = personaUndoAction {
            dismissPersonaUndo()
        }
        switch action {
        case let .select(id):
            selectPersona(id)
        case let .create(name, template):
            startPersonaDraft(name: name, template: template)
        case let .duplicate(id):
            guard let source = personas.first(where: { $0.id == id }) else { return }
            startPersonaDraft(name: L("personas.redesign.copyName", source.name), template: id)
            personaDraftPrompt = personaDisplayPrompt(for: source)
        }
    }

    private func startPersonaDraft(name: String, template: UUID?) {
        searchQuery = ""
        personaDraftCreationID = UUID()
        isCreatingPersonaDraft = true
        selectedPersonaID = nil
        personaDraftName = name
        personaDraftPrompt = ""
        personaDraftTemplateID = nil
        applyPersonaDraftTemplate(template)
    }

    func applyPersonaDraftTemplate(_ id: UUID?) {
        guard isCreatingPersonaDraft else { return }
        let source = personas.first { $0.id == id }
        guard id == nil || source != nil else { return }
        let previousPrompt = personaDraftPrompt
        let previousSource = personaDraftTemplateID
        var prompt = source.map { personaDisplayPrompt(for: $0) } ?? ""
        if source?.isSystem == true {
            prompt += "\n\n" + L("personas.redesign.additionalRequirements") + "\n- "
        }
        guard prompt != personaDraftPrompt || id != personaDraftTemplateID else { return }
        dismissPersonaUndo()
        personaDraftPrompt = prompt
        personaDraftTemplateID = id
        if !previousPrompt.isEmpty {
            registerPersonaUndo(.template(prompt: previousPrompt, source: previousSource),
                                message: L("personas.redesign.templateChanged"))
        }
    }

    func personaDeletionImpacts(for persona: PersonaProfile) -> PersonaDeletionImpacts {
        PersonaDeletionImpacts(resetsDefault: isDefaultPersona(persona.id),
                               resetsAuxiliary: auxiliaryPersonaID == persona.id.uuidString,
                               rules: personaAppBindings.filter { $0.personaID == persona.id })
    }

    func personaDeletionMessage(for persona: PersonaProfile) -> String {
        let impacts = personaDeletionImpacts(for: persona)
        var lines = [L("personas.redesign.deleteMessage", persona.name)]
        if impacts.resetsDefault {
            lines.append(L("personas.redesign.deleteDefault"))
        }
        if impacts.resetsAuxiliary {
            lines.append(L("personas.redesign.deleteAuxiliary"))
        }
        for rule in impacts.rules {
            lines.append(L("personas.redesign.deleteRule", rule.appIdentifier))
        }
        return lines.joined(separator: "\n")
    }

    func deletePersona(id: UUID) {
        guard let persona = personas.first(where: { $0.id == id }), !persona.isSystem else { return }
        let store = askToolSettings
        let snapshot = PersonaDeletionSnapshot(personas: personas, defaultID: store.activePersonaID,
                                               rewriteEnabled: store.personaRewriteEnabled,
                                               selectionExplicit: store.personaSelectionIsExplicit,
                                               auxiliaryID: store.auxiliaryPersonaID, rules: personaAppBindings,
                                               selectedID: selectedPersonaID, name: personaDraftName,
                                               prompt: personaDraftPrompt,
                                               wasCreating: isCreatingPersonaDraft, templateID: personaDraftTemplateID,
                                               ruleDraftPersonaID: personaAppBindingDraftPersonaID)
        let impacts = personaDeletionImpacts(for: persona)
        personas.removeAll { $0.id == id }
        persistPersonas()
        store.personaAppBindings = personaAppBindings.filter { $0.personaID != id }
        if store.activePersonaID == id.uuidString {
            store.activePersonaID = SettingsStore.defaultPersonaID.uuidString
        }
        if impacts.resetsAuxiliary {
            store.auxiliaryPersonaID = SettingsStore.englishPersonaID.uuidString
        }
        syncPersonaSelectionFromStore(preservingEditor: true)
        if personaAppBindingDraftPersonaID == id {
            personaAppBindingDraftPersonaID = defaultPersonaSelectionID
        }
        if selectedPersonaID == id {
            selectPersona(SettingsStore.defaultPersonaID)
        }
        NotificationCenter.default.post(name: .personaSelectionDidChange, object: store)
        registerPersonaUndo(.deletion(snapshot), message: L("personas.redesign.deleted", persona.name))
    }

    func registerPersonaUndo(_ action: PersonaUndoAction, message: String) {
        toastMessage = nil
        personaUndoAction = action
        personaUndoScope = CloudDataLocalScope.key
        personaUndoMessage = message
    }

    func dismissPersonaUndo() {
        personaUndoAction = nil
        personaUndoScope = nil
        personaUndoMessage = nil
    }

    func undoPersonaChange() {
        guard let action = personaUndoAction, let scope = personaUndoScope else { return }
        dismissPersonaUndo()
        let store = askToolSettings
        // A sync notification can still be queued when the user clicks Undo.
        guard scope == CloudDataLocalScope.key, !personaStoreDiffersFromPublishedState,
              personas.sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == store.personas.sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            syncPersonaSelectionFromStore(preservingEditor: true)
            return
        }
        switch action {
        case let .defaultSelection(id, enabled, explicit):
            store.activePersonaID = id
            store.personaRewriteEnabled = enabled
            store.personaSelectionIsExplicit = explicit
        case let .auxiliary(id):
            store.auxiliaryPersonaID = id
        case let .rules(rules):
            store.personaAppBindings = rules
        case let .template(prompt, source):
            guard isCreatingPersonaDraft else { return }
            personaDraftPrompt = prompt
            personaDraftTemplateID = source
        case let .deletion(snapshot):
            personas = snapshot.personas
            persistPersonas()
            store.activePersonaID = snapshot.defaultID
            store.personaRewriteEnabled = snapshot.rewriteEnabled
            store.personaSelectionIsExplicit = snapshot.selectionExplicit
            store.auxiliaryPersonaID = snapshot.auxiliaryID
            store.personaAppBindings = snapshot.rules
            // Restore the removed editor only if the user has not started another edit.
            if !hasPersonaDraftChanges {
                selectedPersonaID = snapshot.selectedID
                isCreatingPersonaDraft = snapshot.wasCreating
                personaDraftName = snapshot.name
                personaDraftPrompt = snapshot.prompt
                personaDraftTemplateID = snapshot.templateID
            }
            personaAppBindingDraftPersonaID = snapshot.ruleDraftPersonaID
        }
        syncPersonaSelectionFromStore(preservingEditor: true)
        NotificationCenter.default.post(name: .personaSelectionDidChange, object: store)
    }
}
