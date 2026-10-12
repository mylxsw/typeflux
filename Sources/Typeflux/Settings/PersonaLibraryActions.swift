import Foundation

enum PersonaDraftNavigation: Equatable {
    case select(UUID?)
    case create(name: String, template: UUID?)
    case duplicate(UUID)
}

enum PersonaDraftDecision: Equatable {
    case save, discard, cancel
}

struct PersonaDeletionImpacts {
    let resetsDefault: Bool
    let resetsAuxiliary: Bool
    let rules: [PersonaAppBinding]
}

struct PersonaDeletionSnapshot {
    let personas: [PersonaProfile]
    let defaultID: String
    let rewriteEnabled: Bool
    let selectionExplicit: Bool
    let auxiliaryID: String
    let rules: [PersonaAppBinding]
    let selectedID: UUID?
    let name: String
    let prompt: String
    let wasCreating: Bool
    let templateID: UUID?
    let ruleDraftPersonaID: UUID?
}

enum PersonaUndoAction {
    case defaultSelection(String, Bool, Bool)
    case auxiliary(String)
    case rules([PersonaAppBinding])
    case deletion(PersonaDeletionSnapshot)
    case template(prompt: String, source: UUID?)
}
