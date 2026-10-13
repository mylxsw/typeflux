import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ClipboardSpotlightSnapshotTests {
    @Test func panelStatesRenderInBothStylesAndAppearances() async throws {
        let configured = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SPOTLIGHT_SNAPSHOTS"]
        let directory = configured.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if configured == nil { try? FileManager.default.removeItem(at: directory) } }
        let entries = try fixtureEntries(in: directory)
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                let model = ClipboardPanelModel()
                model.previewDelay = 0
                model.reset(entries: entries)
                let suffix = "\(style.rawValue)-\(dark ? "dark" : "light").png"
                try await render(model, style: style, dark: dark, directory: directory, name: "panel-" + suffix)
                model.showsPreview = true
                try await render(model, style: style, dark: dark, directory: directory, name: "preview-" + suffix)
                model.showsPreview = false
                for mode in ClipboardCategory.allCases where mode != .all {
                    model.category = mode
                    try await render(model, style: style, dark: dark, directory: directory,
                                     name: "mode-\(mode.rawValue)-" + suffix)
                }
                model.category = .all
                model.query = "No matching clipboard entry"
                try await render(model, style: style, dark: dark, directory: directory, name: "empty-" + suffix)
                model.query = ""
                model.perform(.saveSnippet, at: 0)
                model.snippetError = L("clipboard.snippet.error.unavailable")
                try await render(model, style: style, dark: dark, directory: directory,
                                 name: "snippet-editor-" + suffix)
                model.cancelSnippetEdit()
                model.perform(.editBeforePaste, at: 0)
                try await render(model, style: style, dark: dark, directory: directory,
                                 name: "edit-before-paste-" + suffix)
                model.cancelEdit()
                model.requestClearUnpinned()
                try await render(model, style: style, dark: dark, directory: directory, name: "confirmation-" + suffix)
                model.cancelPending()
                model.setAppFilter(ClipboardAppFilter(bundleID: "com.example.notes", name: "Example Notes"))
                model.isRecordingPaused = true
                try await render(model, style: style, dark: dark, directory: directory,
                                 name: "app-filter-paused-" + suffix)
            }
        }
        try await renderFallbacks(entries, directory: directory)
    }

    private func renderFallbacks(_ entries: [ClipboardEntry], directory: URL) async throws {
        for dark in [false, true] {
            for reduced in [false, true] {
                let model = ClipboardPanelModel()
                model.reset(entries: entries)
                let view = ClipboardPanelView(model: model, focusRequest: 0)
                    .environment(\.typefluxAccessibilityOptions,
                                 TypefluxAccessibilityOptions(reduceTransparency: reduced, increasedContrast: !reduced))
                    .environment(\.accessibilityReduceTransparency, reduced)
                    .environment(\.colorSchemeContrast, reduced ? .standard : .increased)
                    // Accessibility must win even over an explicit glass override.
                    .environment(\.glassMaterialOverride, .liquidGlass)
                try await TypefluxUISnapshot.render(view, size: ClipboardPanelView.size(showsPreview: false),
                                                    style: .liquidGlass, dark: dark, increasedContrast: !reduced,
                                                    file: directory.appendingPathComponent(
                                                        "\(reduced ? "reduce-transparency" : "increase-contrast")-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// Opt in on the acceptance Mac to capture WindowServer's actual glass compositor.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SPOTLIGHT_LIVE"] == "1"))
    func nativePanelMatrix() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SPOTLIGHT_SNAPSHOTS"])
        let directory = URL(fileURLWithPath: path)
        let entries = try fixtureEntries(in: directory)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = ClipboardPanelModel()
            model.previewDelay = 0
            model.reset(entries: entries)
            let controller = ClipboardPanelController(settingsStore: settings)
            controller.reduceMotion = { true }
            defer { controller.dismiss() }
            for style in InterfaceStyle.allCases {
                for dark in [false, true] {
                    settings.interfaceStyle = style
                    settings.appearanceMode = dark ? .dark : .light
                    controller.present(model)
                    let window = try #require(controller.presentedWindow)
                    for preview in [false, true] {
                        model.showsPreview = preview
                        try await Task.sleep(for: .milliseconds(500))
                        let name = "native-\(preview ? "preview" : "panel")-\(style.rawValue)-\(dark ? "dark" : "light").png"
                        let file = directory.appendingPathComponent(name)
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
                        try capture.run()
                        capture.waitUntilExit()
                        #expect(capture.terminationStatus == 0)
                        #expect(try Data(contentsOf: file).count > 1000)
                    }
                    controller.dismiss()
                }
            }
        }
    }

    private func render(_ model: ClipboardPanelModel, style: InterfaceStyle, dark: Bool,
                        directory: URL, name: String) async throws {
        try await TypefluxUISnapshot.render(ClipboardPanelView(model: model, focusRequest: 0),
                                            size: ClipboardPanelView.size(showsPreview: model.showsPreview),
                                            style: style, dark: dark, file: directory.appendingPathComponent(name))
    }

    private func fixtureEntries(in directory: URL) throws -> [ClipboardEntry] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("fixture.png")
        try ClipboardTestSupport.imageData(width: 400, height: 150, text: "Typeflux").write(to: image)
        var snippet = ClipboardTestSupport.entry(.text, text: "Kind regards, Typeflux")
        snippet.snippet = ClipboardSnippet(name: "Email signature", alias: "my signature")
        return [
            ClipboardTestSupport.entry(.text, text: "Review the UI specification tomorrow",
                                       sourceBundleID: "com.example.notes", sourceAppName: "Example Notes",
                                       isPinned: true),
            ClipboardTestSupport.entry(.link, text: "https://example.com/design", sourceAppName: "Browser"),
            ClipboardTestSupport.entry(.image, imagePath: image.path, imagePixelSize: CGSize(width: 400, height: 150)),
            ClipboardTestSupport.entry(.code, text: "SELECT term, uses FROM vocabulary ORDER BY uses DESC;"),
            ClipboardTestSupport.entry(.voice, text: "Make this paragraph more concise"), snippet
        ]
    }
}
