import AppKit

enum AppIconStyle: String, CaseIterable, Codable, Identifiable {
    case glassFrosted
    case pureWhite
    case white
    case black
    case colorful
    case retroMosaic
    case cartoonPetrol
    case cartoonCobalt
    case cartoonLavender
    case yarnBall

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glassFrosted: L("appIcon.glassFrosted")
        case .pureWhite: L("appIcon.pureWhite")
        case .white: L("appIcon.white")
        case .black: L("appIcon.black")
        case .colorful: L("appIcon.colorful")
        case .retroMosaic: L("appIcon.retroMosaic")
        case .cartoonPetrol: L("appIcon.cartoonPetrol")
        case .cartoonCobalt: L("appIcon.cartoonCobalt")
        case .cartoonLavender: L("appIcon.cartoonLavender")
        case .yarnBall: L("appIcon.yarnBall")
        }
    }

    var resourceName: String {
        switch self {
        case .glassFrosted: "TypefluxIconGlassFrosted"
        case .pureWhite: "TypefluxIconPureWhite"
        case .white: "TypefluxIconWhite"
        case .black: "TypefluxIconBlack"
        case .colorful: "TypefluxIconColorful"
        case .retroMosaic: "TypefluxIconMosaic"
        case .cartoonPetrol: "TypefluxIconCartoonPetrol"
        case .cartoonCobalt: "TypefluxIconCartoonCobalt"
        case .cartoonLavender: "TypefluxIconCartoonLavender"
        case .yarnBall: "TypefluxIconYarnBall"
        }
    }

    var needsRoundedTile: Bool {
        switch self {
        case .cartoonPetrol, .cartoonCobalt, .cartoonLavender, .yarnBall: true
        default: false
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
        guard let url, let artwork = NSImage(contentsOf: url) else { return nil }
        guard style.needsRoundedTile else { return artwork }
        return roundedTile(for: artwork)
    }

    private static func roundedTile(for artwork: NSImage) -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        return NSImage(size: size, flipped: false) { canvas in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let tile = canvas.insetBy(dx: canvas.width * 0.095, dy: canvas.height * 0.095)
            NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.height * 0.22).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            artwork.draw(in: tile, from: NSRect(origin: .zero, size: artwork.size), operation: .copy, fraction: 1)
            return true
        }
    }

    @discardableResult
    static func apply(_ style: AppIconStyle) -> Bool {
        if style == .glassFrosted {
            NSApp.applicationIconImage = nil
            return true
        }
        guard let image = image(for: style) else { return false }
        NSApp.applicationIconImage = image
        NSApp.dockTile.display()
        return true
    }
}
