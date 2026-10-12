import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct TypefluxNavigationVisualTests {
    @Test func `navigation gallery renders all four combinations and both accessibility fallbacks`() async throws {
        let configured = ProcessInfo.processInfo.environment["TYPEFLUX_UI_SNAPSHOTS"]
        let directory = configured.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if configured == nil {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let view = TypefluxNavigationGallery(labels: TypefluxNavigationGalleryExamples.labels,
                                             items: TypefluxNavigationGalleryExamples.items,
                                             modes: TypefluxNavigationGalleryExamples.modes)
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TypefluxColor.contentBackground.color)
        try await TypefluxUISnapshot.renderMatrix(view, size: NSSize(width: 1100, height: 1080),
                                                  directory: directory, name: "navigation")
        for dark in [false, true] {
            for reduced in [false, true] {
                let fallback = view.environment(\.typefluxAccessibilityOptions,
                                                TypefluxAccessibilityOptions(reduceTransparency: reduced,
                                                                             increasedContrast: !reduced))
                try await TypefluxUISnapshot.render(fallback, size: NSSize(width: 1100, height: 1080),
                                                    style: .liquidGlass, dark: dark,
                                                    file: directory.appendingPathComponent(
                                                        "navigation-\(reduced ? "reduce-transparency" : "increase-contrast")-\(dark ? "dark" : "light").png"
                                                    ))
            }
        }
    }

    @Test func `glass live fallback branches host content and remain readable`() {
        for style in InterfaceStyle.allCases {
            for material: GlassMaterial? in [nil, .visualEffect, .opaque] {
                let view = TypefluxGlassGroup {
                    TypefluxGlassContainer { Text("Navigation").padding() }
                }.environment(\.interfaceStyle, style).environment(\.glassMaterialOverride, material)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0)
            }
        }
    }
}
