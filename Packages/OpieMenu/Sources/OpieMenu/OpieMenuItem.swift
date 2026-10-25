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

/// What the middle of the ring shows besides the title. A ring with more than one page draws
/// page dots; an icon is drawn above the title (for example the app a page belongs to).
public struct OpieMenuCenter {
    public var icon: NSImage?
    public var pageCount: Int
    public var pageIndex: Int

    public static var plain: OpieMenuCenter { OpieMenuCenter() }

    public init(icon: NSImage? = nil, pageCount: Int = 1, pageIndex: Int = 0) {
        self.icon = icon
        self.pageCount = max(1, pageCount)
        self.pageIndex = min(max(0, pageIndex), max(1, pageCount) - 1)
    }

    var showsPages: Bool { pageCount > 1 }
}
