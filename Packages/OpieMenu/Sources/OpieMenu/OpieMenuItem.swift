import AppKit

/// The three visual treatments supported by the radial menu.
public enum OpieMenuStyle: String, CaseIterable {
    case classic
    case frosted
    case liquidGlass

    public var isAvailable: Bool {
        guard self == .liquidGlass else { return true }
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Icons are supplied by the host application. A custom image is drawn at 26 × 26 points.
public enum OpieMenuIcon {
    case systemSymbol(String)
    case image(NSImage)
    case smile
}

public struct OpieMenuItem: Identifiable {
    public let id: String
    public var title: String
    public var icon: OpieMenuIcon

    public init(id: String, title: String, icon: OpieMenuIcon) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}
