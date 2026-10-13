import Foundation

/// Insets apply only inside the solid detail column; the native sidebar owns its own inset.
struct StudioShellLayout {
    let width: CGFloat
    let sidebarWidth: CGFloat

    init(width: CGFloat, sidebarWidth: CGFloat? = nil) {
        self.width = width
        self.sidebarWidth = sidebarWidth ?? (width >= 1040 ? 220 : 0)
    }

    var horizontalInset: CGFloat {
        width - sidebarWidth < 640 ? 12 : 24
    }

    var contentWidth: CGFloat {
        min(Layout.contentMaxWidth, max(0, width - sidebarWidth - horizontalInset * 2))
    }
}
