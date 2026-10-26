import SwiftUI
import Testing
@testable import Typeflux

@Suite("Application grid", .exclusiveUIState)
@MainActor
struct AskApplicationGridTests {
    @Test func geometryAndNavigation() {
        #expect(AskApplicationGrid.height(count: 0) == 0)
        #expect(AskApplicationGrid.height(count: 6) == 106)
        #expect(AskApplicationGrid.height(count: 8) == 220)
        #expect(AskApplicationGrid.move(2, delta: 1, count: 14) == 9)
        #expect(AskApplicationGrid.move(9, delta: -1, count: 14) == 2)
        #expect(AskApplicationGrid.move(8, delta: 1, count: 10) == 9)
        #expect(AskApplicationGrid.move(0, delta: -1, count: 10, horizontal: true) == 0)
        #expect(AskApplicationGrid.move(5, delta: 1, count: 10, horizontal: true) == 6)
        #expect(AskApplicationGrid.tracks.count == 7)
    }
    private var matches: [AskAppMatch] {
        (0..<14).map { index in
            AskAppMatch(entry: AskAppEntry(name: "App \(index)", url: URL(fileURLWithPath: "/Applications/App\(index).app"),
                                           bundleID: "app.\(index)", names: []), score: 1)
        }
    }

    @Test func onlyUnfilteredHomeUsesGridNavigation() {
        let apps = matches
        let home = AskLauncherHome.build(.init(applications: apps.map(\.entry)))
        let items = AskLauncherHome.items(home)
        #expect(AskLauncherHome.move(1, by: 1, in: items) == 8)
        #expect(AskLauncherHome.move(7, by: -1, in: items, horizontal: true) == 6)
        #expect(AskLauncherSuggestions.height(for: home) == 13 + 106 + 34 + AskApplicationGrid.height(count: 14))
        var results = AskQuickResults(apps: apps, lead: true)
        let itemsInSearch = AskQuickResultsView.listItems(for: results)
        #expect(itemsInSearch.map(\.index) == Array(0..<14))
        #expect(AskQuickResultsView.rowHeight(.app(0), in: results) == AskQuickResultsView.appHeight)
        results.move(1)
        #expect(results.highlighted == 1)
        results.move(-1)
        #expect(results.highlighted == 0)
    }

    @Test func tileAndGridRender() throws {
        let app = matches[0].entry
        let tile = AskApplicationTile(app: app, title: Text(app.name), selected: true, action: {})
        let renderer = ImageRenderer(content: tile.frame(width: 110))
        #expect(renderer.nsImage != nil)
        let home = AskLauncherHome.build(.init(applications: matches.map(\.entry)))
        let homeRenderer = ImageRenderer(content: AskLauncherSuggestions(sections: home, highlighted: .constant(0), onPick: { _ in }).frame(width: 740))
        #expect(homeRenderer.nsImage != nil)
        let results = AskQuickResults(apps: matches, lead: true)
        let searchRenderer = ImageRenderer(content: AskQuickResultsView(results: results, question: "App",
            onRun: { _, _ in }, onHighlight: { _ in }).frame(width: 740))
        #expect(searchRenderer.nsImage != nil)
    }

    @Test func selectionOnlyChangesIconOutline() throws {
        func render(selected: Bool) throws -> NSBitmapImageRep {
            let app = matches[0].entry
            let renderer = ImageRenderer(content:
                AskApplicationTile(app: app, title: Text(app.name), selected: selected, action: {})
                    .frame(width: 110)
                    .background(Color.black)
                    .environment(\.colorScheme, .dark))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let plain = try render(selected: false)
        let selected = try render(selected: true)
        #expect(selected.pixelsWide == plain.pixelsWide)
        #expect(selected.pixelsHigh == plain.pixelsHigh)
        var changedPixels = 0
        var bluePixels = 0
        for y in 0..<selected.pixelsHigh {
            for x in 0..<selected.pixelsWide {
                let before = try #require(plain.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let after = try #require(selected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let difference = abs(before.redComponent - after.redComponent)
                    + abs(before.greenComponent - after.greenComponent)
                    + abs(before.blueComponent - after.blueComponent)
                if difference > 0.05 {
                    changedPixels += 1
                    // The icon occupies the center of the tile, above its unchanged label.
                    #expect(x >= 54 && x < 166 && y >= 20 && y < 145)
                    if after.blueComponent > after.redComponent + 0.2 { bluePixels += 1 }
                }
            }
        }
        #expect(changedPixels > 500)
        #expect(bluePixels > changedPixels * 9 / 10)
    }

}
