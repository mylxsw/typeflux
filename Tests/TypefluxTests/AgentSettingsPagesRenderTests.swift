import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders every Agent settings pane with the production `StudioView` in light and dark.
/// Set `TYPEFLUX_AGENT_SNAPSHOTS=<dir>` to keep the PNGs.
@Suite("Agent settings pages rendering", .serialized, .exclusiveUIState)
@MainActor
struct AgentSettingsPagesRenderTests {
    @Test func everyAgentPaneRendersInLightAndDark() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.appLanguage = .simplifiedChinese
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            settings.interfaceStyle = .classic
            settings.mcpServers = [
                MCPServerConfig(name: "notion", transport: .stdio(.init(command: "npx"))),
                MCPServerConfig(name: "linear", transport: .http(.init(url: "https://mcp.linear.app/sse")))
            ]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-render-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                let model = StudioViewModel(settingsStore: settings,
                                            historyStore: FileHistoryStore(baseDir: root.appendingPathComponent("history")),
                                            initialSection: .agent, localModelManager: FixtureLocalModels())
                model.navigate(to: .agent)
                for pane in AgentSettingsPane.allCases {
                    try await render(StudioView(viewModel: model, agentPane: pane),
                                     dark: dark, name: "agent-\(pane.rawValue)-\(dark ? "dark" : "light")")
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
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_AGENT_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}
