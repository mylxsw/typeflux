import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskLauncherFeatureIconsTests {
    @Test func `keyword icons follow destinations and preserve unrelated features`() {
        let mappings = [(AskOpenChatPlugin.id, "chat"), (AskTranslatePlugin.id, "translate"),
                        (AskScreenshotPlugin.id, "screenshot"), (AskScreenshotTextPlugin.id, "ocr"),
                        (AskNotesPlugin.id, "notes"), (AskNoteCapturePlugin.id, "notes"), (AskClipboardPlugin.id, "clipboard"),
                        (AskSettingsPlugin.id, "settings")]
        for (pluginID, expected) in mappings {
            #expect(AskLauncherFeatureIcons.name(for: .init(keyword: "custom-alias", pluginID: pluginID)) == expected)
        }
        #expect(AskLauncherFeatureIcons.name(for: .init(
            keyword: "dict",
            pluginID: AskTranslatePlugin.id,
            options: [AskTranslatePlugin.actionOption: AskTranslatePlugin.wordBookAction]
        )) == "wordbook")
        let captureNames: [ScreenshotMode: String] = [.region: "screenshot", .fullScreen: "screenshot-full",
                                                      .scrolling: "screenshot-scroll", .recording: "recording",
                                                      .gif: "gif"]
        for mode in ScreenshotMode.allCases {
            let keyword = AskKeyword(keyword: "capture", pluginID: AskScreenshotPlugin.id,
                                     options: [ScreenshotMode.option: mode.rawValue])
            #expect(AskLauncherFeatureIcons.name(for: keyword)
                == captureNames[mode])
        }
        for id in [AskWorkflowPlugin.idPrefix + "custom", "system.unknown", "unknown"] {
            #expect(AskLauncherFeatureIcons.name(for: .init(keyword: "fy", pluginID: id)) == nil)
        }
    }

    @Test func `every built in keyword and alias has destination artwork`() throws {
        var resolved = Set<String>()
        for keyword in AskPluginRegistry.defaultKeywords {
            let name = try #require(AskLauncherFeatureIcons.name(for: keyword), "Missing icon: \(keyword.keyword)")
            resolved.insert(name)
            #expect(AskLauncherFeatureIcons.image(for: name, style: .sculpted) != nil)
            for alias in keyword.allKeywords {
                var renamed = keyword
                renamed.keyword = alias
                #expect(AskLauncherFeatureIcons.name(for: renamed) == name)
            }
        }
        #expect(resolved == Set(AskLauncherFeatureIcons.names))
    }

    @Test func `custom prompt and URL do not borrow unrelated branding`() {
        let prompt = AskKeyword(keyword: "rw", pluginID: AskPromptPlugin.id,
                                options: ["preset": "polish", "prompt": "Translate {input}"])
        let web = AskKeyword(keyword: "g", pluginID: AskWebSearchPlugin.id,
                             options: ["engine": "google", "url": "https://example.com?q={query}"])
        #expect(AskLauncherFeatureIcons.name(for: prompt) == nil)
        #expect(AskLauncherFeatureIcons.name(for: web) == nil)
        #expect(AskLauncherFeatureIcons.name(for: .init(keyword: "g", pluginID: AskWebSearchPlugin.id)) == "web-google")
        #expect(AskLauncherFeatureIcons.name(for: .init(keyword: "rw", pluginID: AskPromptPlugin.id,
                                                        options: ["preset": "unknown"])) == nil)
    }

    @Test func `dedicated artwork renders in chips directory and both appearances`() throws {
        for scheme in [ColorScheme.dark, .light] {
            let keywords = AskPluginRegistry.defaultKeywords
            let rows = stride(from: 0, to: keywords.count, by: 7).map { Array(keywords[$0 ..< min(
                $0 + 7,
                keywords.count
            )]) }
            let view = VStack(spacing: 18) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        ForEach(rows[index]) { keyword in
                            VStack(spacing: 6) {
                                AskPluginItemIcon(icon: .feature(AskLauncherFeatureIcons.name(for: keyword)!),
                                                  symbol: "star", filled: false)
                                AskKeywordChip(title: keyword.keyword, symbol: "star", detail: nil, keyword: keyword)
                            }.frame(width: 150, height: 72)
                        }
                    }
                }
                AskKeywordChip(title: "Custom", symbol: "star", detail: "Fallback")
                AskPluginItemIcon(icon: .feature("missing"), symbol: "star", filled: false)
            }.padding(24).background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width > 1000 && image.size.height > 100)
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_FEATURE_SNAPSHOTS"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let data = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("keyword-atlas-" + (scheme == .dark ? "dark" : "light") + ".png")
                )
            }
        }
    }

    @Test func `both families contain every icon with transparent corners`() throws {
        for style in AskLauncherFeatureIcons.Style.allCases {
            for name in AskLauncherFeatureIcons.names {
                let image = try #require(AskLauncherFeatureIcons.image(for: "feature." + name, style: style))
                #expect(image === AskLauncherFeatureIcons.image(for: name, style: style))
                let data = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                #expect(bitmap.pixelsWide == 512)
                #expect(bitmap.pixelsHigh == 512)
                #expect(bitmap.hasAlpha)
                #expect((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01)
                #expect((bitmap.colorAt(x: 256, y: 256)?.alphaComponent ?? 0) > 0.9)
            }
        }
        #expect(AskLauncherFeatureIcons.image(for: "unknown", style: .sculpted) == nil)
        #expect(AskLauncherFeatureIcons.image(for: "chat", style: .sculpted)
            !== AskLauncherFeatureIcons.image(for: "chat", style: .light))
    }
}
