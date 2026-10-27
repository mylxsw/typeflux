import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskLauncherFeatureIconsTests {
    @Test func keywordIconsFollowDestinationsAndPreserveUnrelatedFeatures() {
        let mappings = [(AskOpenChatPlugin.id, "chat"), (AskTranslatePlugin.id, "translate"),
                        (AskScreenshotPlugin.id, "screenshot"), (AskScreenshotTextPlugin.id, "screenshot"),
                        (AskNotesPlugin.id, "notes"), (AskClipboardPlugin.id, "clipboard"),
                        (AskSettingsPlugin.id, "settings")]
        for (pluginID, expected) in mappings {
            #expect(AskLauncherFeatureIcons.name(for: .init(keyword: "custom-alias", pluginID: pluginID)) == expected)
        }
        #expect(AskLauncherFeatureIcons.name(for: .init(keyword: "dict", pluginID: AskTranslatePlugin.id,
            options: [AskTranslatePlugin.actionOption: AskTranslatePlugin.wordBookAction])) == "wordbook")
        for mode in ScreenshotMode.allCases {
            let keyword = AskKeyword(keyword: "capture", pluginID: AskScreenshotPlugin.id,
                                     options: [ScreenshotMode.option: mode.rawValue])
            #expect(AskLauncherFeatureIcons.name(for: keyword)
                == (mode == .recording || mode == .gif ? "recording" : "screenshot"))
        }
        for id in [AskCalendarPlugin.id, AskWorkflowPlugin.idPrefix + "custom", "unknown"] {
            #expect(AskLauncherFeatureIcons.name(for: .init(keyword: "fy", pluginID: id)) == nil)
        }
    }

    @Test func bothFamiliesContainEveryIconWithTransparentCorners() throws {
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
