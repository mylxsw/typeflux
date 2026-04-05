import AppKit

enum AppAppearance {
    static func nsAppearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func apply(_ mode: AppearanceMode) {
        NSApp.appearance = nsAppearance(for: mode)
    }
}
