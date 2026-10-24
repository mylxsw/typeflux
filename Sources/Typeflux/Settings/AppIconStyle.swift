import AppKit

enum AppIconStyle: String, CaseIterable, Codable, Identifiable {
    case glassFrosted
    case pureWhite
    case violetInfinity
    case white
    case black
    case colorful
    case retroMosaic
    case cartoonPetrol
    case cartoonCobalt
    case cartoonLavender
    case yarnBall
    case hairyPuppet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glassFrosted: L("appIcon.glassFrosted")
        case .pureWhite: L("appIcon.pureWhite")
        case .violetInfinity: L("appIcon.violetInfinity")
        case .white: L("appIcon.white")
        case .black: L("appIcon.black")
        case .colorful: L("appIcon.colorful")
        case .retroMosaic: L("appIcon.retroMosaic")
        case .cartoonPetrol: L("appIcon.cartoonPetrol")
        case .cartoonCobalt: L("appIcon.cartoonCobalt")
        case .cartoonLavender: L("appIcon.cartoonLavender")
        case .yarnBall: L("appIcon.yarnBall")
        case .hairyPuppet: L("appIcon.hairyPuppet")
        }
    }

    var resourceName: String {
        switch self {
        case .glassFrosted: "TypefluxIconGlassFrosted"
        case .pureWhite: "TypefluxIconPureWhite"
        case .violetInfinity: "TypefluxIconVioletInfinity"
        case .white: "TypefluxIconWhite"
        case .black: "TypefluxIconBlack"
        case .colorful: "TypefluxIconColorful"
        case .retroMosaic: "TypefluxIconMosaic"
        case .cartoonPetrol: "TypefluxIconCartoonPetrol"
        case .cartoonCobalt: "TypefluxIconCartoonCobalt"
        case .cartoonLavender: "TypefluxIconCartoonLavender"
        case .yarnBall: "TypefluxIconYarnBall"
        case .hairyPuppet: "TypefluxIconHairyPuppet"
        }
    }

    var needsRoundedTile: Bool {
        switch self {
        case .violetInfinity, .cartoonPetrol, .cartoonCobalt, .cartoonLavender, .yarnBall, .hairyPuppet: true
        default: false
        }
    }
}

@MainActor
enum AppIconController {
    private static let application = AppIconApplication()
    static func image(for style: AppIconStyle) -> NSImage? {
        let url = Bundle.appResources.url(
            forResource: style.resourceName,
            withExtension: "png",
            subdirectory: "AppIcons"
        ) ?? Bundle.appResources.url(forResource: style.resourceName, withExtension: "png")
        guard let url, let artwork = NSImage(contentsOf: url) else { return nil }
        guard style.needsRoundedTile else { return artwork }
        return roundedTile(for: artwork, sourceInsetFraction: style == .violetInfinity ? 0.1 : 0)
    }

    private static func roundedTile(for artwork: NSImage, sourceInsetFraction: CGFloat) -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        return NSImage(size: size, flipped: false) { canvas in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let tile = canvas.insetBy(dx: canvas.width * 0.095, dy: canvas.height * 0.095)
            NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.height * 0.22).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            // Some supplied artwork already has a tile and outer padding; sample only its interior.
            let source = NSRect(origin: .zero, size: artwork.size).insetBy(
                dx: artwork.size.width * sourceInsetFraction,
                dy: artwork.size.height * sourceInsetFraction
            )
            artwork.draw(in: tile, from: source, operation: .copy, fraction: 1)
            return true
        }
    }

    @discardableResult
    static func apply(_ style: AppIconStyle, force: Bool = false) -> Bool {
        application.apply(style, force: force, load: image(for:)) { image in
            NSApp.applicationIconImage = image
            if image != nil { NSApp.dockTile.display() }
        }
    }
}

/// Retain only the selected artwork. Recreating a Dock tile may reinstall it,
/// but repeated notifications must not decode/rasterize/install an unchanged icon.
@MainActor
final class AppIconApplication {
    private var style: AppIconStyle?
    private var image: NSImage?

    @discardableResult
    func apply(_ next: AppIconStyle, force: Bool = false,
               load: (AppIconStyle) -> NSImage?, install: (NSImage?) -> Void) -> Bool {
        if style == next {
            if force { install(image) }
            return true
        }
        let nextImage: NSImage?
        if next == .glassFrosted { nextImage = nil }
        else {
            guard let loaded = load(next) else { return false }
            nextImage = loaded
        }
        install(nextImage)
        image = nextImage
        style = next
        return true
    }
}
