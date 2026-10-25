import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Tool permission settings", .serialized, .exclusiveUIState)
@MainActor
struct AskToolPermissionsSettingsTests {
    @Test func revisitingPermissionsSkipsUnrelatedCapabilityIO() {
        let suite = "permission-reload-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var dependencyReads = 0
        var statusUpdates = 0
        let view = AskToolsSettingsView(
            settings: settings,
            owner: { dependencyReads += 1; return "fixture" },
            pane: .permissions,
            onStatusesChange: { _ in statusUpdates += 1 },
            permissions: AgentAutomationPermissions(
                accessibilityGranted: { dependencyReads += 1; return false },
                screenRecordingGranted: { dependencyReads += 1; return false },
                requestAccessibility: {}, requestScreenRecording: {}))
        for _ in 0..<5 { view.reload() }
        #expect(dependencyReads == 0)
        #expect(statusUpdates == 0)
        #expect(!settings.toolPermissionEntries.isEmpty)
    }

    @Test func permissionLabelsAreLocalizedAndNavigationUsesTheSharedPane() {
        #expect(AgentSettingsPane.permissions.group == .capabilities)
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLocalization.shared.setLanguage(language)
            for entry in AskToolAuthorization.builtins {
                #expect(!entry.title.hasPrefix("agent.permissions."))
                #expect(!entry.toolTitle.hasPrefix("agent.permissions."))
                #expect(!entry.detail.hasPrefix("agent.permissions."))
                #expect(entry.detail != L("agent.permissions.help.unknown", entry.tool, entry.action))
            }
            let unknown = AskToolAuthorizationEntry(tool: "custom_tool", action: "custom_action", effect: .unknown)
            #expect(unknown.detail.contains("custom_tool"))
            #expect(unknown.detail.contains("custom_action"))
            for permission in AskToolPermission.allCases { #expect(!permission.title.hasPrefix("agent.permissions.")) }
            #expect(!AgentSettingsPane.permissions.title.isEmpty)
        }
    }

    @Test func permissionsRenderAtCompactAndWideWidthsInBothAppearances() async throws {
        let defaults = UserDefaults(suiteName: "permission-render-" + UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        for dark in [false, true] {
            for width in [460.0, 760.0] {
                AppLocalization.shared.setLanguage(dark ? .english : .simplifiedChinese)
                let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: width, height: 900),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: ScrollView {
                    AskToolsSettingsView(settings: settings, pane: .permissions,
                                         permissions: .fixed(accessibility: false, screenRecording: false)).padding(24)
                }.background(StudioTheme.shellSurface))
                host.frame = window.contentView!.bounds
                window.contentView = host
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(data.count > 10000)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_AGENT_SNAPSHOTS"] {
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: root.appendingPathComponent("permissions-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
                window.orderOut(nil); window.close()
            }
        }
    }
}
