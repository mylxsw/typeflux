import AppKit
import XCTest

@MainActor
enum CloudSpeechAcceptanceCapture {
    static var enabled: Bool { directory != nil }

    private static var directory: URL? {
        ProcessInfo.processInfo.environment["TYPEFLUX_CLOUD_ACCEPTANCE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static func save(_ view: NSView, name: String) throws {
        guard let directory else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 3_000)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
