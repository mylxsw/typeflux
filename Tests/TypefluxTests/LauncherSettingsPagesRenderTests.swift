import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders every Launcher settings pane with the production `StudioView` in light and dark.
/// Set `TYPEFLUX_LAUNCHER_SNAPSHOTS=<dir>` to keep the PNGs.
@Suite("Launcher settings pages rendering", .serialized, .exclusiveUIState)
@MainActor
struct LauncherSettingsPagesRenderTests {
    @Test func everyLauncherPaneRendersInLightAndDark() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            settings.interfaceStyle = .classic
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-render-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                let model = StudioViewModel(settingsStore: settings,
                                            historyStore: FileHistoryStore(baseDir: root.appendingPathComponent("history")),
                                            initialSection: .launcher, localModelManager: FixtureLocalModels())
                model.navigate(to: .launcher)
                for pane in LauncherSettingsPane.allCases {
                    try await render(StudioView(viewModel: model, launcherPane: pane),
                                     dark: dark, name: "launcher-\(pane.rawValue)-\(dark ? "dark" : "light")")
                }
            }
        }
    }

    private func render(_ view: some View, dark: Bool, name: String) async throws {
        let size = NSSize(width: 1100, height: 2400)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -12000, y: -12000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 20000, "\(name) rendered blank")
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}
