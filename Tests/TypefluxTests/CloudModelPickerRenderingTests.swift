@testable import Typeflux
import AppKit
import SwiftUI
import XCTest

@MainActor
final class CloudModelPickerRenderingTests: XCTestCase {
    func testPricedPickerRendersModelParameters() throws {
        let suite = "cloud-picker-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.removeModel("cloud:default", providerID: "typefluxCloud")
        try library.addModels([
            .init(id: "fast", name: "Fast", reference: "cloud:fast", scenarios: ["ask"],
                  pricing: .init(multiplier: "0.5"), contextWindowTokens: 32768, maxOutputTokens: 4096),
            .init(id: "balanced", name: "Balanced", reference: "cloud:balanced", scenarios: ["ask"],
                  pricing: .init(multiplier: "1"), contextWindowTokens: 128000, maxOutputTokens: 8192),
            .init(id: "deep", name: "Deep", reference: "cloud:deep", scenarios: ["ask"],
                  pricing: .init(multiplier: "2"), contextWindowTokens: 128000, maxOutputTokens: 16384),
        ], providerID: "typefluxCloud")
        let content = AskModelChoices(library: library, reference: .constant("cloud:balanced"),
                                      showsDefaultAction: false, loggedIn: true)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 260)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        XCTAssertGreaterThanOrEqual(image.pixelsWide, 360)
        XCTAssertGreaterThanOrEqual(image.pixelsHigh, 260)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_CATALOG_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("cloud-model-picker.png"))
        }
    }
}
