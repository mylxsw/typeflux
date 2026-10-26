import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskLauncherFeatureIconsTests {
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
