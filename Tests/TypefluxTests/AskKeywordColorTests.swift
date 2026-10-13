import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskKeywordColorTests {
    @Test func `ordinary plugins default to the existing accent color`() {
        let plugin: any AskLauncherPlugin = AskSettingsPlugin()
        #expect(plugin.keywordColor == TypefluxColor.accent.color)
        #expect(AskKeywordChip(title: "Settings", symbol: "gearshape").tint == TypefluxColor.accent.color)
    }

    @Test func `destructive commands use danger while ordinary system commands stay blue`() {
        let destructive: Set<AskSystemCommand> = [.emptyTrash, .shutdown, .restart, .resetSpotlight]
        for command in AskSystemCommand.allCases {
            let plugin: any AskLauncherPlugin = AskSystemCommandPlugin(command: command)
            #expect(plugin
                .keywordColor ==
                (destructive.contains(command) ? TypefluxColor.danger.color : TypefluxColor.accent.color))
        }
        let kill: any AskLauncherPlugin = AskKillAppPlugin()
        #expect(kill.keywordColor == TypefluxColor.danger.color)
    }

    @Test(arguments: [AskKillAppPlugin.id, AskSystemCommand.shutdown.id, AskSettingsPlugin.id])
    func `custom keywords and aliases inherit the plugin color`(pluginID: String) throws {
        let plugins: [any AskLauncherPlugin] = [AskKillAppPlugin(), AskSystemCommandPlugin(command: .shutdown),
                                                AskSettingsPlugin()]
        let keyword = AskKeyword(keyword: "custom", pluginID: pluginID, aliases: ["alias"])
        let session = AskPluginSession(plugins: plugins, keywords: { [keyword] })
        defer { session.deactivate() }
        #expect(session.detect(in: "ALIAS ") == "")
        #expect(session.keyword == keyword)
        let plugin = try #require(session.plugin)
        #expect(plugin
            .keywordColor ==
            (pluginID == AskSettingsPlugin.id ? TypefluxColor.accent.color : TypefluxColor.danger.color))
    }

    /// Render the production composer to verify the color reaches the actual prefix.
    /// Set TYPEFLUX_ASK_SNAPSHOTS to also save light and dark review screenshots.
    @Test(arguments: [AskKillAppPlugin.id, AskSystemCommand.emptyTrash.id, AskSystemCommand.shutdown.id,
                      AskSystemCommand.restart.id, AskSystemCommand.resetSpotlight.id,
                      AskSystemCommand.toggleDarkMode.id, AskSettingsPlugin.id])
    func `launcher renders the configured prefix color`(pluginID: String) async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let dangerous = pluginID != AskSystemCommand.toggleDarkMode.id && pluginID != AskSettingsPlugin.id
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let keyword = AskKeyword(keyword: "custom", pluginID: pluginID, aliases: ["alias"])
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "alias ", prepare: { model in
                model.modelLibrary.settings.saveAskLauncherKeywords([keyword])
                if pluginID == AskKillAppPlugin.id {
                    model.plugins.replacePlugins([AskKillAppPlugin(applications: { [] })])
                }
            })
            defer { launcher.close() }
            launcher.window.appearance = NSAppearance(named: appearance)
            #expect(launcher.fixture.model.plugins.keyword == keyword)
            try await Task.sleep(for: .milliseconds(150))
            let hosting = try #require(launcher.window.contentView)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            // The first 80pt contains the prefix, above the results and footer.
            let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
            var tintedPixels = 0
            for row in 0 ..< min(bitmap.pixelsHigh, Int(80 * scale)) {
                for column in 0 ..< min(bitmap.pixelsWide, Int(240 * scale)) {
                    guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                    if dangerous {
                        if color.redComponent > 0.5, color.redComponent > color.greenComponent * 1.5,
                           color.redComponent > color.blueComponent * 1.5 {
                            tintedPixels += 1
                        }
                    } else if color.blueComponent > 0.5, color.blueComponent > color.redComponent * 1.5 {
                        tintedPixels += 1
                    }
                }
            }
            #expect(
                tintedPixels > 20,
                "Expected a visible \(dangerous ? "red" : "blue") prefix for \(pluginID) in \(theme)"
            )
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: root.appendingPathComponent("keyword-\(pluginID)-\(theme).png"))
            }
        }
    }
}
