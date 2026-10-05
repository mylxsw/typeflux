import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class AskCloudflareSettingsVisualTests: XCTestCase {
    func testCloudflareSettingsRenderInBothAppearances() async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(language) }
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = AgentSettingsSection(title: L("agent.settings.web")) {
                AgentSettingsRow(icon: "globe", title: L("ask.settings.search.title"), subtitle: L("ask.settings.search.subtitle"), subtitleLineLimit: nil) {
                    Text("Cloudflare Web Search").font(.system(size: 13))
                }
                ModelRowDivider(leading: 66)
                AgentSettingsRow(icon: "key", title: L("ask.settings.search.cloudflare.token")) {
                    SecureField("Cloudflare API Token", text: .constant("fixture-token"))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                AskCloudflareSearchSettingsView(configuration: .constant(.init(accountID: "0123456789abcdef0123456789abcdef")))
            }.padding(24).frame(width: 760, height: 600, alignment: .top).background(StudioTheme.surface)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(hosting.fittingSize.height, 600)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 4000)
            if let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLOUDFLARE_SNAPSHOTS"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent(appearance == .aqua ? "cloudflare-light.png" : "cloudflare-dark.png"))
            }
        }
    }
}
