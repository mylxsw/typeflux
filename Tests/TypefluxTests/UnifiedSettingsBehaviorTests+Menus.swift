import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
extension UnifiedSettingsBehaviorTests {
    /// Select without native menu tracking, which can terminate the Swift Testing host.
    static func selectPopupItem(_ title: String, identifier: String = "personas.defaultSelection",
                                model: StudioViewModel, in window: NSWindow) throws {
        let matchingBinding = personaBinding(identifier, model: model)
        let binding = try #require(matchingBinding, "Unknown persona picker \(identifier)")
        let selection: UUID?
        if title == L("personas.redesign.none") {
            try #require(identifier == "personas.defaultSelection", "Only the default picker allows None")
            selection = nil
        } else {
            let matchingPersona = model.personas.first { $0.name == title }
            let persona = try #require(matchingPersona, "Unknown persona option \(title)")
            selection = persona.id
        }
        let contentView = window.contentView
        let content = try #require(contentView)
        let popup = popupButtons(in: content).first { $0.accessibilityIdentifier() == identifier }
        if let popup {
            let enabled = popup.isEnabled
            try #require(enabled, "The identified picker must be enabled: \(identifier)")
            if let item = popup.item(withTitle: title), let action = popup.action {
                let itemEnabled = item.isEnabled
                try #require(itemEnabled, "The selected option must be enabled: \(title)")
                popup.selectItem(withTitle: title)
                let sent = NSApp.sendAction(action, to: popup.target, from: popup)
                try #require(sent, "The identified native picker must send its selection")
                return
            }
        }
        // SwiftUI's lazy menu may have no native items or accessibility proxy until opened.
        // Use the same model getters and setters as StudioPersonaUsageStrip instead.
        binding.wrappedValue = selection
    }

    private static func popupButtons(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popupButtons(in: $0) }
    }

    private static func personaBinding(_ identifier: String, model: StudioViewModel) -> Binding<UUID?>? {
        switch identifier {
        case "personas.defaultSelection":
            Binding(get: { model.defaultPersonaSelectionID }, set: model.setDefaultPersonaSelection)
        case "personas.auxiliarySelection":
            Binding(get: { UUID(uuidString: model.auxiliaryPersonaID) }, set: { id in
                if let id {
                    model.setAuxiliaryPersona(id.uuidString)
                }
            })
        default:
            nil
        }
    }
}
