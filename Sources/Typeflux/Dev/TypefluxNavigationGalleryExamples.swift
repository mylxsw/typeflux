import TypefluxUI

enum TypefluxNavigationGalleryExamples {
    static let labels = TypefluxNavigationGalleryLabels(
        navigation: "Navigation and floating surfaces", window: "Window template",
        search: "Search", inlineSearch: "Menu / popover / picker search", panel: "Spotlight panel",
        empty: "No matching results", hud: "Show HUD", copied: "Copied", sheet: "Sheet",
        alert: "Delete confirmation", dialog: "Confirmation dialog", cancel: "Cancel", confirm: "Add",
        delete: "Delete", disabled: "Disabled", collapsed: "Collapsed", expanded: "Expanded · empty",
        filtering: "Filtering · retained on blur", sampleQuery: "Typeflux",
        hints: ["↑↓ Select", "↵ Open", "⌘↵ Plain text", "⌘1–9", "Esc Close"]
    )

    static let items = [
        TypefluxSpotlightItem(id: "notes", title: "Notes", subtitle: "Reading and writing", systemImage: "note.text"),
        TypefluxSpotlightItem(id: "history", title: "History", systemImage: "clock"),
        TypefluxSpotlightItem(id: "disabled", title: "Unavailable result", systemImage: "doc", isEnabled: false)
    ]

    static let modes = [
        TypefluxSpotlightMode(id: "all", title: "All", systemImage: "square.grid.2x2"),
        TypefluxSpotlightMode(id: "text", title: "Text", systemImage: "doc.text"),
        TypefluxSpotlightMode(id: "images", title: "Images", systemImage: "photo")
    ]
}
