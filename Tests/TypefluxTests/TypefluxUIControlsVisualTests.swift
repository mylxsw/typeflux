import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite("TypefluxUI content snapshots", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUIControlsVisualTests {
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("typeflux-ui-content-" + UUID().uuidString)

    @Test func `all content controls in four appearances`() async throws {
        let root = snapshotDirectory
        defer { removeTemporarySnapshots() }
        let scene = TypefluxControlsGalleryView().padding(24).background(TypefluxColor.contentBackground.color)
        let measurement = NSHostingView(rootView: scene.frame(width: 1000))
        let height = ceil(measurement.fittingSize.height)
        #expect(height > 2000)
        try await TypefluxUISnapshot.renderMatrix(scene, size: NSSize(width: 1000, height: height),
                                                  directory: root, name: "content-controls")
        try await TypefluxUISnapshot.renderMatrix(
            TypefluxUIControlsOverviewScene().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TypefluxColor.contentBackground.color),
            size: NSSize(width: 1100, height: 1200), directory: root, name: "content-overview"
        )
        try await TypefluxUISnapshot.renderMatrix(
            TypefluxEmptyStateFallback(title: "No results", systemImage: "magnifyingglass",
                                      description: "Check spelling or add a new item.",
                                      actions: TypefluxButton("Add item", kind: .primary, action: {})),
            size: NSSize(width: 600, height: 240), directory: root, name: "empty-state-macos13"
        )
        try await TypefluxUISnapshot.renderMatrix(
            TypefluxEmptyState("Nothing here", systemImage: "tray", description: "Add an item to begin."),
            size: NSSize(width: 600, height: 240), directory: root, name: "empty-state-no-action"
        )
    }

    @Test func `high contrast native appearances retain solid content`() async throws {
        defer { removeTemporarySnapshots() }
        let scene = TypefluxControlsGalleryView().padding(24).background(TypefluxColor.contentBackground.color)
        let height = ceil(NSHostingView(rootView: scene.frame(width: 1000)).fittingSize.height)
        try await TypefluxUISnapshot.renderMatrix(
            scene, size: NSSize(width: 1000, height: height), directory: snapshotDirectory,
            name: "content-accessible", increasedContrast: true
        )
    }

    @Test func `gallery extension renders application supplied content`() async throws {
        defer { removeTemporarySnapshots() }
        let state = TypefluxGalleryState()
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                state.style = style
                state.appearance = dark ? .dark : .light
                let file = snapshotDirectory.appendingPathComponent(
                    "gallery-content-entry-\(style.rawValue)-\(dark ? "dark" : "light").png"
                )
                try await TypefluxUISnapshot.render(TypefluxGalleryRoot(state: state, onAppearanceChange: { _ in }),
                                                    size: NSSize(width: 1000, height: 820),
                                                    style: style, dark: dark, file: file)
            }
        }
    }

    private var snapshotDirectory: URL {
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_UI_SNAPSHOTS"] {
            return URL(fileURLWithPath: directory)
        }
        return temporaryDirectory
    }

    private func removeTemporarySnapshots() {
        if ProcessInfo.processInfo.environment["TYPEFLUX_UI_SNAPSHOTS"] == nil {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }
}
