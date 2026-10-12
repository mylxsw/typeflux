enum TypefluxTableActionVisibility {
    static func isVisible(hovered: Bool, selected: Bool, focused: Bool, voiceOver: Bool) -> Bool {
        hovered || selected || focused || voiceOver
    }
}
