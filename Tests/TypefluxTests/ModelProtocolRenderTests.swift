import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

final class ModelProtocolRenderTests: XCTestCase {
    /// Opt-in screenshots use isolated settings without credentials or network requests.
    @MainActor
    func testCustomProtocolSettingsRender() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_PROTOCOL_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "protocol-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = RegisteredProvider(
            id: "endpoint:fixture",
            name: "Example Gateway",
            baseURL: "https://api.example.com/v1",
            models: [.init(id: "example-model", name: "Example Model")],
            apiStyle: .responses
        )
        try ModelRegistry(providers: [provider]).write(defaults)
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(AddModelEndpointView(library: library), size: NSSize(width: 520, height: 460),
                             appearance: appearance, file: root.appendingPathComponent("add-protocol-\(name).png"))
            try await render(
                ProviderModelsView(library: library, providerID: provider.id).padding(24).background(ModelVisualStyle.canvas),
                size: NSSize(width: 760, height: 660),
                appearance: appearance,
                file: root.appendingPathComponent("provider-protocol-\(name).png")
            )
        }
    }

    @MainActor
    private func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let frame = NSRect(origin: NSPoint(x: -10000, y: -10000), size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4000)
        try data.write(to: file)
    }
}
