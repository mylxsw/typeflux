import AppKit

enum AppIconStyle: String, CaseIterable, Codable, Identifiable {
    case white
    case black
    case colorful
    case retroMosaic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .white: L("appIcon.white")
        case .black: L("appIcon.black")
        case .colorful: L("appIcon.colorful")
        case .retroMosaic: L("appIcon.retroMosaic")
        }
    }

    var resourceName: String {
        switch self {
        case .white: "TypefluxIconWhite"
        case .black: "TypefluxIconBlack"
        case .colorful: "TypefluxIconColorful"
        case .retroMosaic: "TypefluxIconMosaic"
        }
    }
}

@MainActor
enum AppIconController {
    static func image(for style: AppIconStyle) -> NSImage? {
        let url = Bundle.appResources.url(
            forResource: style.resourceName,
            withExtension: "png",
            subdirectory: "AppIcons"
        ) ?? Bundle.appResources.url(forResource: style.resourceName, withExtension: "png")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    @discardableResult
    static func apply(_ style: AppIconStyle) -> Bool {
        if style == .black {
            NSApp.applicationIconImage = nil
            return true
        }
        guard let image = image(for: style) else { return false }
        NSApp.applicationIconImage = image
        NSApp.dockTile.display()
        return true
    }
}
