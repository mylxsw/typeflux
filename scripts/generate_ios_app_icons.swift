#!/usr/bin/env swift
// Run from the repository root: swift scripts/generate_ios_app_icons.swift
// Reuse desktop artwork, removing desktop padding and producing opaque iOS tiles.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("Apps/iOS/TypefluxIOS/Assets.xcassets")
let styles = [
    ("primary", ""), ("glassFrosted", "GlassFrosted"), ("pureWhite", "PureWhite"), ("white", "White"),
    ("black", "Black"), ("colorful", "Colorful"), ("retroMosaic", "Mosaic"),
    ("cartoonPetrol", "CartoonPetrol"), ("cartoonCobalt", "CartoonCobalt"),
    ("cartoonLavender", "CartoonLavender"), ("yarnBall", "YarnBall"), ("hairyPuppet", "HairyPuppet")
]

func render(_ image: NSImage, size: Int, padded: Bool) -> Data {
    let canvas = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let context = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // Fill the already rounded artwork's corners using the tile background color.
    let source = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let background = source.colorAt(x: source.pixelsWide / 2, y: source.pixelsHigh / 8) ?? .white
    background.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    let inset = padded ? image.size.width * 0.095 : 0
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(origin: .zero, size: image.size).insetBy(dx: inset, dy: inset),
        operation: .sourceOver, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, canvas.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

for (style, resource) in styles {
    let primary = style == "primary"
    let path = primary
        ? catalog.appendingPathComponent("AppIcon.appiconset/AppIcon.png")
        : root.appendingPathComponent("Sources/Typeflux/Resources/AppIcons/TypefluxIcon\(resource).png")
    let image = NSImage(contentsOf: path)!
    if !primary {
        let folder = catalog.appendingPathComponent("AppIcon-\(style).appiconset")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let padded = ["glassFrosted", "pureWhite", "white", "black", "colorful", "retroMosaic"].contains(style)
        try render(image, size: 1024, padded: padded).write(to: folder.appendingPathComponent("AppIcon.png"))
        let contents = """
        {"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],
         "info":{"author":"xcode","version":1}}
        """
        try contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }
    let iconPath = catalog.appendingPathComponent(primary ? "AppIcon.appiconset/AppIcon.png" : "AppIcon-\(style).appiconset/AppIcon.png")
    let folder = catalog.appendingPathComponent("IconPreview-\(style).imageset")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try render(NSImage(contentsOf: iconPath)!, size: 192, padded: false)
        .write(to: folder.appendingPathComponent("preview.png"))
    let contents = """
    {"images":[{"filename":"preview.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}
    """
    try contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
