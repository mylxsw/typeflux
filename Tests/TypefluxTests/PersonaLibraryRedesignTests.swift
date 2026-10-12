import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Persona library redesign", .serialized, .exclusiveUIState)
@MainActor
struct PersonaLibraryRedesignTests {
    @Test func `shortcut badge opens hotkey settings`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.model.openPersonaShortcutSettings()
        #expect(fixture.model.currentSection == .settings)
        #expect(fixture.model.settingsPaneRequest == .hotkeys)
    }

    @Test func `default and auxiliary undo preserve unsaved editor`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.selectPersona(fixture.custom.id)
        model.personaDraftPrompt = "Unsaved"
        model.setDefaultPersonaSelection(fixture.custom.id)
        #expect(model.defaultPersonaSelectionID == fixture.custom.id)
        #expect(model.personaUndoMessage != nil)
        model.undoPersonaChange()
        #expect(model.defaultPersonaSelectionID == SettingsStore.defaultPersonaID)
        #expect(model.personaDraftPrompt == "Unsaved")
        model.toggleDefaultPersona(fixture.custom.id)
        model.toggleDefaultPersona(fixture.custom.id)
        #expect(model.defaultPersonaSelectionID == nil)
        model.undoPersonaChange()
        #expect(model.defaultPersonaSelectionID == fixture.custom.id)
        model.useAuxiliaryPersona(fixture.custom.id)
        #expect(model.auxiliaryPersonaID == fixture.custom.id.uuidString)
        model.undoPersonaChange()
        #expect(model.auxiliaryPersonaID == SettingsStore.englishPersonaID.uuidString)
        model.useAuxiliaryPersona(SettingsStore.englishPersonaID)
        #expect(model.toastMessage != nil)
        let previous = model.auxiliaryPersonaID
        model.setAuxiliaryPersona(UUID().uuidString)
        model.useAuxiliaryPersona(UUID())
        model.toggleDefaultPersona(UUID())
        model.setDefaultPersonaSelection(UUID())
        #expect(model.auxiliaryPersonaID == previous)
        model.setDefaultPersonaSelection(fixture.custom.id)
        model.dismissPersonaUndo()
        model.setDefaultPersonaSelection(fixture.custom.id)
        #expect(model.personaUndoMessage == nil)
        model.setAuxiliaryPersona(previous)
        #expect(model.personaUndoMessage == nil)
    }

    @Test func `disabled default undo restores remembered ID and explicit choice`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.store.activePersonaID = fixture.custom.id.uuidString
        fixture.store.personaRewriteEnabled = false
        fixture.store.personaSelectionIsExplicit = false
        fixture.model.syncPersonaSelectionFromStore(preservingEditor: true)
        fixture.model.setDefaultPersonaSelection(SettingsStore.defaultPersonaID)
        fixture.model.undoPersonaChange()
        #expect(!fixture.model.personaRewriteEnabled)
        #expect(fixture.store.activePersonaID == fixture.custom.id.uuidString)
        #expect(!fixture.store.personaSelectionIsExplicit)
        fixture.model.undoPersonaChange()
        #expect(fixture.model.personaUndoMessage == nil)
    }

    @Test func `deletion impacts and undo restore all state`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.selectPersona(fixture.custom.id)
        model.personaDraftPrompt = "Edited before deletion"
        model.setDefaultPersonaSelection(fixture.custom.id)
        model.setAuxiliaryPersona(fixture.custom.id.uuidString)
        fixture.store.savePersonaAppBinding(appIdentifier: "com.apple.mail", personaID: fixture.custom.id)
        fixture.store.savePersonaAppBinding(appIdentifier: "com.apple.Notes", personaID: nil)
        model.syncPersonaSelectionFromStore(preservingEditor: true)
        model.personaAppBindingDraftPersonaID = fixture.custom.id
        try model.setPersonaAppBindingEnabled(
            id: #require(model.personaAppBindings.first { $0.personaID == fixture.custom.id }).id,
            isEnabled: false
        )
        let rules = model.personaAppBindings
        let impacts = model.personaDeletionImpacts(for: fixture.custom)
        #expect(impacts.resetsDefault && impacts.resetsAuxiliary)
        #expect(impacts.rules.count == 1)
        #expect(model.personaDeletionMessage(for: fixture.custom).contains("com.apple.mail"))
        model.deletePersona(id: fixture.custom.id)
        #expect(!model.personas.contains { $0.id == fixture.custom.id })
        #expect(model.defaultPersonaSelectionID == SettingsStore.defaultPersonaID)
        #expect(model.auxiliaryPersonaID == SettingsStore.englishPersonaID.uuidString)
        #expect(model.personaAppBindings.count == 1)
        #expect(model.selectedPersonaID == SettingsStore.defaultPersonaID)
        #expect(model.personaAppBindingDraftPersonaID == SettingsStore.defaultPersonaID)
        model.undoPersonaChange()
        #expect(model.personas.contains { $0.id == fixture.custom.id })
        #expect(model.defaultPersonaSelectionID == fixture.custom.id)
        #expect(model.auxiliaryPersonaID == fixture.custom.id.uuidString)
        #expect(model.personaAppBindings == rules)
        #expect(model.selectedPersonaID == fixture.custom.id)
        #expect(model.personaDraftPrompt == "Edited before deletion")
        #expect(model.personaAppBindingDraftPersonaID == fixture.custom.id)
        #expect(fixture.store.personas.contains { $0.id == fixture.custom.id })
    }

    @Test(arguments: [false, true]) func `delete unselected persona preserves another draft`(creating: Bool) throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let other = PersonaProfile(name: "Other", prompt: "Other prompt")
        fixture.store.personas += [other]
        fixture.model.personas = fixture.store.personas
        let model = fixture.model
        if creating {
            model.beginCreatingPersona()
        } else {
            model.selectPersona(other.id)
        }
        model.personaDraftName = "Keep this name"
        model.personaDraftPrompt = "Keep this prompt"
        #expect(!model.personaDeletionImpacts(for: fixture.custom).resetsDefault)
        #expect(!model.personaDeletionImpacts(for: fixture.custom).resetsAuxiliary)
        model.deletePersona(id: fixture.custom.id)
        #expect(model.personaDraftPrompt == "Keep this prompt")
        model.undoPersonaChange()
        #expect(model.personaDraftName == "Keep this name")
        #expect(model.isCreatingPersonaDraft == creating)
        let count = model.personas.count
        model.deletePersona(id: SettingsStore.defaultPersonaID)
        model.deletePersona(id: UUID())
        #expect(model.personas.count == count)
    }

    @Test func `deleted remembered default stays disabled`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.store.personaRewriteEnabled = false
        fixture.store.activePersonaID = fixture.custom.id.uuidString
        fixture.model.syncPersonaSelectionFromStore(preservingEditor: true)
        fixture.model.deletePersona(id: fixture.custom.id)
        #expect(!fixture.model.personaRewriteEnabled)
        #expect(fixture.store.activePersonaID == SettingsStore.defaultPersonaID.uuidString)
        fixture.model.undoPersonaChange()
        #expect(fixture.store.activePersonaID == fixture.custom.id.uuidString)
    }

    @Test(arguments: [PersonaDraftDecision.save, .discard, .cancel])
    func `dirty switch requires decision`(decision: PersonaDraftDecision) throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.selectPersona(fixture.custom.id)
        model.personaDraftPrompt = "Modified"
        model.selectPersonaGuardingDraft(fixture.custom.id)
        #expect(model.pendingPersonaNavigation == nil)
        model.selectPersonaGuardingDraft(UUID())
        #expect(model.pendingPersonaNavigation == nil)
        model.selectPersonaGuardingDraft(SettingsStore.defaultPersonaID)
        #expect(model.selectedPersonaID == fixture.custom.id)
        #expect(model.pendingPersonaNavigation == .select(SettingsStore.defaultPersonaID))
        model.resolvePersonaDraftGuard(decision)
        #expect(model.pendingPersonaNavigation == nil)
        if case .cancel = decision {
            #expect(model.personaDraftPrompt == "Modified")
            #expect(model.selectedPersonaID == fixture.custom.id)
        } else {
            #expect(model.selectedPersonaID == SettingsStore.defaultPersonaID)
            #expect(fixture.store.personas.first { $0.id == fixture.custom.id }?
                .prompt == (decision == .save ? "Modified" : fixture.custom.prompt))
        }
    }

    @Test func `invalid dirty draft cannot save or leave via save`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.selectPersona(fixture.custom.id)
        model.personaDraftPrompt = " \n "
        #expect(!model.canSavePersonaDraft)
        model.selectPersonaGuardingDraft(nil)
        model.resolvePersonaDraftGuard(.save)
        #expect(model.pendingPersonaNavigation != nil)
        #expect(model.selectedPersonaID == fixture.custom.id)
        model.savePersonaDraft()
        #expect(fixture.store.personas.first { $0.id == fixture.custom.id }?.prompt == fixture.custom.prompt)
        model.resolvePersonaDraftGuard(.discard)
        #expect(model.selectedPersonaID == nil)
        model.resolvePersonaDraftGuard(.save)
        #expect(model.pendingPersonaNavigation == nil)
    }

    @Test func `dirty create and duplicate use guard and saved source`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.selectPersona(fixture.custom.id)
        model.personaDraftName = "Updated"
        model.personaDraftPrompt = "Updated prompt"
        model.beginCreatingPersona(name: "Search result")
        #expect(!model.isCreatingPersonaDraft)
        model.resolvePersonaDraftGuard(.cancel)
        model.duplicatePersona(fixture.custom)
        #expect(model.pendingPersonaNavigation == .duplicate(fixture.custom.id))
        model.resolvePersonaDraftGuard(.save)
        #expect(model.isCreatingPersonaDraft)
        #expect(model.personaDraftName.contains("Updated"))
        #expect(model.personaDraftPrompt == "Updated prompt")
        #expect(model.personaDraftTemplateID == fixture.custom.id)
        model.beginCreatingPersona(name: "Search result")
        #expect(model.pendingPersonaNavigation == .create(name: "Search result", template: nil))
        model.resolvePersonaDraftGuard(.discard)
        #expect(model.personaDraftName == "Search result")
        #expect(model.personaDraftPrompt.isEmpty)
        model.selectPersonaGuardingDraft(SettingsStore.defaultPersonaID)
        model.resolvePersonaDraftGuard(.discard)
        #expect(!model.isCreatingPersonaDraft)
        model.duplicatePersona(PersonaProfile(name: "Missing", prompt: "Missing"))
        #expect(!model.isCreatingPersonaDraft)
    }

    @Test func `templates prefill definitions and undo replacement`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.applyPersonaDraftTemplate(SettingsStore.defaultPersonaID)
        #expect(!model.isCreatingPersonaDraft)
        model.searchQuery = "unmatched"
        model.beginCreatingPersona(template: SettingsStore.defaultPersonaID)
        #expect(model.searchQuery.isEmpty)
        #expect(model.personaDraftTemplateID == SettingsStore.defaultPersonaID)
        #expect(try model.personaDraftPrompt
            .contains(model
                .personaDisplayPrompt(for: #require(model.personas.first { $0.id == SettingsStore.defaultPersonaID }))))
        #expect(model.personaDraftPrompt.contains(L("personas.redesign.additionalRequirements")))
        #expect(!model.canSavePersonaDraft)
        model.personaDraftName = "New"
        #expect(model.canSavePersonaDraft)
        model.personaDraftPrompt = "Typed text"
        model.applyPersonaDraftTemplate(fixture.custom.id)
        #expect(model.personaDraftPrompt == fixture.custom.prompt)
        model.undoPersonaChange()
        #expect(model.personaDraftPrompt == "Typed text")
        #expect(model.personaDraftTemplateID == SettingsStore.defaultPersonaID)
        model.applyPersonaDraftTemplate(SettingsStore.englishPersonaID)
        #expect(model.personaDraftTemplateTitle == "English Translator")
        model.applyPersonaDraftTemplate(nil)
        #expect(model.personaDraftPrompt.isEmpty)
        #expect(!model.canSavePersonaDraft)
        model.undoPersonaChange()
        #expect(model.personaDraftTemplateID == SettingsStore.englishPersonaID)
        let previous = model.personaDraftPrompt
        model.applyPersonaDraftTemplate(UUID())
        #expect(model.personaDraftPrompt == previous)
        model.applyPersonaDraftTemplate(SettingsStore.englishPersonaID)
        #expect(model.personaDraftPrompt == previous)
        model.cancelPersonaEditing()
        #expect(model.personaUndoMessage == nil)
        #expect(model.selectedPersonaID == SettingsStore.defaultPersonaID)
    }

    @Test func `duplication and creation require name and definition`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let builtIn = try #require(model.personas.first { $0.id == SettingsStore.defaultPersonaID })
        model.selectPersona(builtIn.id)
        model.duplicatePersona(builtIn)
        #expect(model.personaDraftPrompt == model.personaDisplayPrompt(for: builtIn))
        #expect(model.personaDraftTemplateID == builtIn.id)
        #expect(model.canSavePersonaDraft)
        model.personaDraftName = " \n "
        #expect(!model.canSavePersonaDraft)
        model.savePersonaDraft()
        #expect(model.isCreatingPersonaDraft)
        model.personaDraftName = " Copy "
        model.savePersonaDraft()
        #expect(!model.isCreatingPersonaDraft)
        #expect(model.selectedPersona?.name == "Copy")
        #expect(!model.hasPersonaDraftChanges)
        #expect(model.defaultPersonaSelectionID == SettingsStore.defaultPersonaID)
        model.beginCreatingPersona(template: UUID())
        #expect(model.personaDraftPrompt.isEmpty)
        #expect(model.personaDraftTemplateTitle == L("personas.redesign.blank"))
        model.cancelPersonaEditing()
    }

    @Test func `rule add uses default or preset and prevents duplicates`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.openPersonaAppRules(adding: true)
        #expect(model.isPersonaRulesDrawerPresented && model.isAddingPersonaAppRule)
        #expect(model.personaAppBindingDraftPersonaID == SettingsStore.defaultPersonaID)
        model.personaAppBindingDraftIdentifier = "  com.apple.mail  "
        #expect(model.canSavePersonaAppBinding)
        model.savePersonaAppBinding()
        #expect(model.personaAppBindings.first?.appIdentifier == "com.apple.mail")
        #expect(!model.isAddingPersonaAppRule)
        model.personaAppBindingDraftIdentifier = "COM.APPLE.MAIL"
        #expect(!model.canSavePersonaAppBinding)
        model.savePersonaAppBinding()
        #expect(model.personaAppBindings.count == 1)
        model.openPersonaAppRules(adding: true, preset: fixture.custom.id)
        #expect(model.personaAppBindingDraftPersonaID == fixture.custom.id)
        model.personaAppBindingDraftIdentifier = "Notes"
        model.savePersonaAppBinding()
        #expect(model.personaAppBindings.first { $0.appIdentifier == "Notes" }?.personaID == fixture.custom.id)
        model.setDefaultPersonaSelection(nil)
        model.openPersonaAppRules(adding: true, preset: UUID())
        #expect(model.personaAppBindingDraftPersonaID == nil)
        model.personaAppBindingDraftIdentifier = " "
        model.savePersonaAppBinding()
        #expect(model.personaAppBindings.count == 2)
        model.personaAppBindingDraftIdentifier = "Safari"
        model.personaAppBindingDraftPersonaID = UUID()
        #expect(!model.canSavePersonaAppBinding)
        model.savePersonaAppBinding()
        #expect(model.personaAppBindings.count == 2)
        model.closePersonaAppRules()
        #expect(!model.isPersonaRulesDrawerPresented && !model.isAddingPersonaAppRule)
        #expect(model.personaAppBindingDraftIdentifier.isEmpty)
    }

    @Test func `rule pause delete undo and missing persona`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.openPersonaAppRules(adding: true)
        model.personaAppBindingDraftIdentifier = "Notes"
        model.savePersonaAppBinding()
        let binding = try #require(model.personaAppBindings.first)
        #expect(model.personaName(for: binding) == "Typeflux")
        model.setPersonaAppBindingEnabled(id: binding.id, isEnabled: false)
        #expect(model.pausedPersonaAppRuleCount == 1)
        model.setPersonaAppBindingsEnabled(false)
        #expect(!fixture.store.personaAppBindingsEnabled)
        model.setPersonaAppBindingEnabled(id: binding.id, isEnabled: true)
        #expect(model.pausedPersonaAppRuleCount == 1)
        model.setPersonaAppBindingsEnabled(true)
        #expect(model.pausedPersonaAppRuleCount == 0)
        model.updatePersonaAppBindingPersona(id: binding.id, personaID: fixture.custom.id)
        #expect(model.personaName(for: model.personaAppBindings[0]) == fixture.custom.name)
        model.updatePersonaAppBindingPersona(id: binding.id, personaID: UUID())
        #expect(model.personaAppBindings[0].personaID == fixture.custom.id)
        model.updatePersonaAppBindingPersona(id: binding.id, personaID: nil)
        #expect(model.personaAppBindings[0].personaID == nil)
        model.removePersonaAppBinding(id: binding.id)
        #expect(model.personaAppBindings.isEmpty)
        model.undoPersonaChange()
        #expect(model.personaAppBindings[0].id == binding.id)
        #expect(model.personaAppBindings[0].personaID == nil)
        model.removePersonaAppBinding(id: UUID())
        #expect(model.personaUndoMessage == nil)
        let missing = PersonaAppBinding(appIdentifier: "Missing", personaID: UUID())
        #expect(model.personaName(for: missing) == L("settings.personaAppBindings.missingPersona"))
        #expect(model.personaTitle(missing.personaID) == L("settings.personaAppBindings.missingPersona"))
        #expect(model.personaTitle(nil) == L("personas.redesign.none"))
    }

    @Test func `search matches name definition and localized summary`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.searchQuery = "  REPORT  "
        #expect(model.filteredCustomPersonas.map(\.id) == [fixture.custom.id])
        model.searchQuery = "summarize"
        #expect(model.filteredCustomPersonas.map(\.id) == [fixture.custom.id])
        model.searchQuery = try model
            .personaListSubtitle(for: #require(model.personas.first { $0.id == SettingsStore.defaultPersonaID }))
        #expect(model.filteredBuiltInPersonas.map(\.id) == [SettingsStore.defaultPersonaID])
        model.searchQuery = "Not Found"
        #expect(model.filteredPersonas.isEmpty)
        model.beginCreatingPersona(name: model.searchQuery)
        #expect(model.personaDraftName == "Not Found")
        #expect(model.searchQuery.isEmpty)
        model.personaDraftPrompt = "Summarize."
        model.savePersonaDraft()
        #expect(model.filteredCustomPersonas.contains { $0.name == "Not Found" })
    }

    @Test func `store notifications do not overwrite new or edited draft`() async throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.selectPersona(fixture.custom.id)
        model.personaDraftPrompt = "Unsaved"
        fixture.store.personas = fixture.store.personas
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.personaDraftPrompt == "Unsaved")
        model.beginCreatingPersona()
        model.resolvePersonaDraftGuard(.discard)
        model.personaDraftName = "Draft"
        model.personaDraftPrompt = "Draft content"
        fixture.store.personas = fixture.store.personas
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.isCreatingPersonaDraft)
        #expect(model.personaDraftPrompt == "Draft content")
    }

    @Test func `every redesign string exists with matching placeholders`() throws {
        let english = try table("en")
        let keys = english.keys.filter { $0.hasPrefix("personas.redesign.") }
        #expect(keys.count >= 45)
        for language in ["zh-Hans", "zh-Hant", "ja", "ko"] {
            let localized = try table(language)
            for key in keys {
                let value = try #require(localized[key], "Missing \(key) in \(language)")
                #expect(!value.isEmpty)
                for placeholder in ["%@", "%d"] {
                    #expect(value.components(separatedBy: placeholder).count == english[key]!
                        .components(separatedBy: placeholder).count)
                }
            }
        }
    }

    @Test(arguments: ["personas", "default", "rewrite", "auxiliary", "rules", "master"])
    func `external store changes invalidate undo without overwriting cloud data`(change: String) async throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.setDefaultPersonaSelection(fixture.custom.id)
        #expect(model.personaUndoMessage != nil)
        switch change {
        case "personas": fixture.store.personas += [PersonaProfile(name: "Cloud addition", prompt: "Cloud text")]
        case "default": fixture.store.activePersonaID = SettingsStore.englishPersonaID.uuidString
        case "rewrite": fixture.store.personaRewriteEnabled = false
        case "auxiliary": fixture.store.auxiliaryPersonaID = fixture.custom.id.uuidString
        case "rules": fixture.store.savePersonaAppBinding(appIdentifier: "Cloud app", personaID: nil)
        default: fixture.store.personaAppBindingsEnabled = false
        }
        NotificationCenter.default.post(name: .personaSelectionDidChange, object: fixture.store)
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.personaUndoMessage == nil)
        let profiles = fixture.store.personas
        model.undoPersonaChange()
        #expect(fixture.store.personas == profiles)
    }

    @Test func `choosing no persona records an explicit opt out`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.store.applyPersonaSelection(nil)
        fixture.store.personaSelectionIsExplicit = false
        fixture.model.syncPersonaSelectionFromStore(preservingEditor: true)
        fixture.model.setDefaultPersonaSelection(nil)
        #expect(fixture.store.personaSelectionIsExplicit)
        fixture.model.undoPersonaChange()
        #expect(!fixture.store.personaSelectionIsExplicit)
        #expect(!fixture.store.personaRewriteEnabled)
    }

    @Test func `manually named rules also disable matching app candidates`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        let candidate = PersonaAppCandidate(id: "com.example.app", displayName: "Example",
                                            bundleIdentifier: "com.example.app", appURL: nil, isRunning: true)
        #expect(!fixture.model.hasPersonaAppRule(for: candidate))
        fixture.store.savePersonaAppBinding(appIdentifier: "Example", personaID: nil)
        fixture.model.syncPersonaSelectionFromStore(preservingEditor: true)
        #expect(fixture.model.hasPersonaAppRule(for: candidate))
        fixture.store.personaAppBindings = []
        fixture.store.savePersonaAppBinding(appIdentifier: "COM.EXAMPLE.APP", personaID: nil)
        fixture.model.syncPersonaSelectionFromStore(preservingEditor: true)
        #expect(fixture.model.hasPersonaAppRule(for: candidate))
    }

    @Test func `selection notification preserves dirty draft away from persona page`() async throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.model.selectPersona(fixture.custom.id)
        fixture.model.personaDraftPrompt = "Unsaved elsewhere"
        fixture.model.navigate(to: .home)
        fixture.store.applyPersonaSelection(SettingsStore.englishPersonaID)
        try await Task.sleep(for: .milliseconds(40))
        #expect(fixture.model.selectedPersonaID == fixture.custom.id)
        #expect(fixture.model.personaDraftPrompt == "Unsaved elsewhere")
        #expect(fixture.model.defaultPersonaSelectionID == SettingsStore.englishPersonaID)
    }

    @Test func `new undo notice supersedes earlier save toast`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.model.toastMessage = "Earlier notice"
        fixture.model.setDefaultPersonaSelection(fixture.custom.id)
        #expect(fixture.model.toastMessage == nil)
        #expect(fixture.model.personaUndoMessage != nil)
        fixture.model.applyPersonaSelection(SettingsStore.defaultPersonaID)
        #expect(fixture.model.personaUndoMessage == nil)
    }

    @Test func `no persona manual rule is valid and persists without an override`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.model.setDefaultPersonaSelection(nil)
        fixture.model.openPersonaAppRules(adding: true)
        fixture.model.personaAppBindingDraftIdentifier = "Manual app"
        #expect(fixture.model.personaAppBindingDraftPersonaID == nil)
        #expect(fixture.model.canSavePersonaAppBinding)
        fixture.model.savePersonaAppBinding()
        let binding = try #require(fixture.store.personaAppBindings.first)
        #expect(binding.appIdentifier == "Manual app" && binding.personaID == nil)
    }

    @Test(arguments: [true, false])
    func `undo cannot overwrite an external change before its notification runs`(profiles: Bool) throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.model.deletePersona(id: fixture.custom.id)
        let cloudPersona = PersonaProfile(name: "Cloud addition", prompt: "Cloud text")
        if profiles {
            fixture.store.personas += [cloudPersona]
        } else {
            fixture.store.applyPersonaSelection(SettingsStore.englishPersonaID)
        }
        fixture.model.undoPersonaChange()
        #expect(!fixture.store.personas.contains { $0.id == fixture.custom.id })
        if profiles {
            #expect(fixture.store.personas.contains { $0.id == cloudPersona.id })
        } else {
            #expect(fixture.store.activePersonaID == SettingsStore.englishPersonaID.uuidString)
        }
        #expect(fixture.model.personaUndoMessage == nil)
    }

    @Test func `undo is scoped to the account that created the snapshot`() throws {
        let fixture = try PersonaLibraryFixture()
        defer { fixture.cleanUp() }
        fixture.model.deletePersona(id: fixture.custom.id)
        fixture.model.personaUndoScope = "another-account"
        fixture.model.undoPersonaChange()
        #expect(!fixture.store.personas.contains { $0.id == fixture.custom.id })
        #expect(fixture.model.personaUndoMessage == nil)
    }

    private func table(_ language: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/Typeflux/Resources/\(language).lproj/Localizable.strings")
        return try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        ) as? [String: String])
    }
}

@MainActor
final class PersonaLibraryFixture {
    let suite = "PersonaLibraryRedesignTests.\(UUID().uuidString)"
    let originalLanguage = AppLocalization.shared.language
    let defaults: UserDefaults
    let store: SettingsStore
    let custom = PersonaProfile(name: "Report", prompt: "Summarize the report.")
    let model: StudioViewModel

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        store = SettingsStore(defaults: defaults)
        store.appLanguage = .english
        store.personas += [custom]
        store.applyPersonaSelection(SettingsStore.defaultPersonaID)
        model = StudioViewModel(
            settingsStore: store,
            historyStore: PersonaLibraryHistoryStore(),
            initialSection: .personas
        )
        AppLocalization.shared.setLanguage(.english)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        AppLocalization.shared.setLanguage(originalLanguage)
    }
}

private final class PersonaLibraryHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/persona-history.md")
    }
}
