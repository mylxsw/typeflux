import SwiftUI
import Testing
@testable import Typeflux

@Suite("Application grid", .exclusiveUIState)
@MainActor
struct AskApplicationGridTests {
    @Test func geometryAndNavigation() {
        #expect(AskApplicationGrid.height(count: 0) == 0)
        #expect(AskApplicationGrid.height(count: 6) == 106)
        #expect(AskApplicationGrid.height(count: 7) == 220)
        #expect(AskApplicationGrid.move(2, delta: 1, count: 14) == 8)
        #expect(AskApplicationGrid.move(8, delta: -1, count: 14) == 2)
        #expect(AskApplicationGrid.move(8, delta: 1, count: 10) == 9)
        #expect(AskApplicationGrid.move(0, delta: -1, count: 10, horizontal: true) == 0)
        #expect(AskApplicationGrid.move(5, delta: 1, count: 10, horizontal: true) == 6)
        #expect(AskApplicationGrid.tracks.count == 6)
    }
    private var matches: [AskAppMatch] {
        (0..<14).map { index in
            AskAppMatch(entry: AskAppEntry(name: "App \(index)", url: URL(fileURLWithPath: "/Applications/App\(index).app"),
                                           bundleID: "app.\(index)", names: []), score: 1)
        }
    }

    @Test func homeAndSearchUseSameGridOrder() {
        let apps = matches
        let home = AskLauncherHome.build(.init(applications: apps.map(\.entry)))
        let items = AskLauncherHome.items(home)
        #expect(AskLauncherHome.move(1, by: 1, in: items) == 7)
        #expect(AskLauncherHome.move(7, by: -1, in: items, horizontal: true) == 6)
        #expect(AskLauncherSuggestions.height(for: home) == 13 + 34 + AskApplicationGrid.height(count: 14))
        var results = AskQuickResults(apps: apps, lead: true)
        let blocks = AskQuickResultsView.displayBlocks(for: results)
        #expect(blocks.count == 1)
        #expect(blocks[0].map(\.index) == Array(0..<14))
        #expect(AskQuickResultsView.contentHeight(for: results) == 13 + 22 + AskApplicationGrid.height(count: 14))
        let moved1 = results.moveApplication(1)
        #expect(moved1)
        #expect(results.highlighted == 6)
        let movedHorizontal = results.moveApplication(1, horizontal: true)
        #expect(movedHorizontal)
        #expect(results.highlighted == 7)
        let moved2 = results.moveApplication(1)
        #expect(moved2)
        #expect(results.highlighted == 13)
        let moved3 = results.moveApplication(1)
        #expect(moved3)
        #expect(results.highlighted == 0)
        results.highlight(14)
        let movedAI = results.moveApplication(1)
        #expect(!movedAI)
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

}
