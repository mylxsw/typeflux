@testable import Typeflux
import WebKit
import XCTest

/// Tab order, recently opened items, the panel's width and focused viewing.
@MainActor
final class AskSidePanelArrangementTests: XCTestCase {
    private func makeBrowser() -> AskBrowserWorkspace {
        let name = "AskSidePanelArrangementTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AskBrowserWorkspace(policy: AskBrowserSitePolicy(defaults: defaults), dataStore: .nonPersistent())
    }

    private func target(_ path: String) -> AskSidePanelFileAccess.Target {
        .init(root: "/workspace", relativePath: path)
    }

    // MARK: Order

    func testTabsReorderWhileTheFilesTabStaysFirst() throws {
        let panel = AskSidePanel(browser: nil)
        let first = try panel.open(target("a.txt"), conversationId: "c1")
        let second = try panel.open(target("b.txt"), conversationId: "c1")
        let third = try panel.open(target("c.txt"), conversationId: "c1")
        let ids: [AskSidePanelTab.ID] = [.file(first.id), .file(second.id), .file(third.id)]
        XCTAssertEqual(panel.tabs.map(\.id), [.files] + ids)

        panel.move(.file(third.id), before: .file(first.id))
        XCTAssertEqual(panel.order, [.file(third.id), .file(first.id), .file(second.id)])
        panel.move(.file(third.id), before: nil)
        XCTAssertEqual(panel.order, ids, "Nil moves to the end")
        // Moving before the Files tab lands right after it; the Files tab never moves.
        panel.move(.file(second.id), before: .files)
        XCTAssertEqual(panel.tabs.map(\.id), [.files, .file(second.id), .file(first.id), .file(third.id)])
        panel.move(.files, before: nil)
        panel.move(.files, onto: .file(third.id))
        XCTAssertEqual(panel.tabs.first?.id, .files)
        XCTAssertEqual(panel.order, [.file(second.id), .file(first.id), .file(third.id)])
        // Unknown tabs and a tab onto itself change nothing.
        panel.move(.file(UUID()), before: .file(first.id))
        panel.move(.file(first.id), before: .file(UUID()))
        panel.move(.file(first.id), before: .file(first.id))
        panel.move(.file(first.id), onto: .file(first.id))
        panel.move(.file(first.id), onto: .file(UUID()))
        XCTAssertEqual(panel.order, [.file(second.id), .file(first.id), .file(third.id)])
    }

    func testDraggingOntoATabTakesItsPlace() throws {
        let panel = AskSidePanel(browser: nil)
        let first = try panel.open(target("a.txt"), conversationId: "c1")
        let second = try panel.open(target("b.txt"), conversationId: "c1")
        let third = try panel.open(target("c.txt"), conversationId: "c1")
        // Rightwards: after the target.
        panel.move(.file(first.id), onto: .file(second.id))
        XCTAssertEqual(panel.order, [.file(second.id), .file(first.id), .file(third.id)])
        panel.move(.file(second.id), onto: .file(third.id))
        XCTAssertEqual(panel.order, [.file(first.id), .file(third.id), .file(second.id)])
        // Leftwards: before the target.
        panel.move(.file(second.id), onto: .file(first.id))
        XCTAssertEqual(panel.order, [.file(second.id), .file(first.id), .file(third.id)])
        // Onto the Files tab: first after it.
        panel.move(.file(third.id), onto: .files)
        XCTAssertEqual(panel.order, [.file(third.id), .file(second.id), .file(first.id)])
        // The selection follows its tab, not its position.
        panel.select(.file(second.id))
        panel.move(.file(second.id), onto: .file(first.id))
        XCTAssertEqual(panel.selection, .file(second.id))
    }

    func testWebTabsReorderAndKeepTheirPlaceWhenTheAIOpensMore() throws {
        let browser = makeBrowser()
        defer { browser.tabs.forEach { browser.close($0) } }
        let panel = AskSidePanel(browser: browser)
        let page = try XCTUnwrap(try panel.newWebTab())
        let file = try panel.open(target("a.txt"), conversationId: "c1")
        panel.move(.file(file.id), onto: .web(page.id))
        XCTAssertEqual(panel.order, [.file(file.id), .web(page.id)])
        let agent = try browser.newTab(owner: .agent(conversationId: "c1"), select: false)
        XCTAssertEqual(panel.order, [.file(file.id), .web(page.id), .web(agent.id)])
    }

    // MARK: Recents

    func testRecentsListOpenedFilesAndPagesNewestFirst() throws {
        let browser = makeBrowser()
        defer { browser.tabs.forEach { browser.close($0) } }
        let panel = AskSidePanel(browser: browser)
        XCTAssertTrue(panel.recents.isEmpty)
        try panel.open(target("outputs/a.md"), conversationId: "c1")
        try panel.open(target("outputs/b.md"), conversationId: "c2")
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        try panel.openWeb(url)
        XCTAssertEqual(panel.recents.map(\.title), ["example.com", "b.md", "a.md"])
        XCTAssertEqual(panel.recents.first?.detail, "https://example.com/")
        // Reopening moves an item to the front without a duplicate, also for the same page.
        try panel.open(target("outputs/a.md"), conversationId: "c1")
        try panel.openWeb(try XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertEqual(panel.recents.map(\.title), ["example.com", "a.md", "b.md"])
        XCTAssertEqual(panel.recents[1].detail, "outputs/a.md")
        // Each conversation sees only its own files, and every page.
        XCTAssertEqual(panel.recents(conversationId: "c1").map(\.title), ["example.com", "a.md"])
        XCTAssertEqual(panel.recents(conversationId: nil).map(\.title), ["example.com"])
    }

    func testRecentsAreCapped() throws {
        let panel = AskSidePanel(browser: nil)
        for index in 0 ..< AskSidePanel.maxRecents + 3 {
            let tab = try panel.open(target("outputs/\(index).txt"), conversationId: "c1")
            panel.close(.file(tab.id))
        }
        XCTAssertEqual(panel.recents.count, AskSidePanel.maxRecents)
        XCTAssertEqual(panel.recents.first?.title, "\(AskSidePanel.maxRecents + 2).txt")
    }

    func testOpeningARecentFileFromANewTabReplacesTheBlankTab() throws {
        let browser = makeBrowser()
        defer { browser.tabs.forEach { browser.close($0) } }
        let panel = AskSidePanel(browser: browser)
        let file = try panel.open(target("outputs/a.md"), conversationId: "c1")
        panel.close(.file(file.id))
        let blank = try XCTUnwrap(try panel.newWebTab())
        try panel.openRecent(try XCTUnwrap(panel.recents.first), conversationId: "c1")
        XCTAssertEqual(panel.selectedFileTab?.target, target("outputs/a.md"))
        XCTAssertNil(browser.tab(id: blank.id), "The blank tab it was picked on closes")
        XCTAssertEqual(panel.order.count, 1)

        // Another conversation's file never opens.
        let other = AskSidePanelRecent.file(target("outputs/secret.md"), conversationId: "c2")
        try panel.openRecent(other, conversationId: "c1")
        XCTAssertFalse(panel.fileTabs.contains { $0.target == target("outputs/secret.md") })
    }

    func testOpeningARecentPageLoadsItInTheBlankTab() throws {
        let browser = makeBrowser()
        defer { browser.tabs.forEach { browser.close($0) } }
        let panel = AskSidePanel(browser: browser)
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))
        let blank = try XCTUnwrap(try panel.newWebTab())
        try panel.openRecent(.web(url), conversationId: nil)
        XCTAssertEqual(browser.tabs.count, 1, "The blank tab shows the page")
        XCTAssertEqual(panel.selection, .web(blank.id))
        XCTAssertEqual(panel.recents.first, .web(url))
        // A page already open is switched to; the new blank tab closes.
        let second = try XCTUnwrap(try panel.newWebTab())
        try panel.openRecent(.web(url), conversationId: nil)
        XCTAssertEqual(panel.selection, .web(blank.id))
        XCTAssertNil(browser.tab(id: second.id))
        // From a tab that is not blank, the page opens like any link.
        panel.select(.web(blank.id))
        try panel.openRecent(.web(url), conversationId: nil)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    func testRecentIdentity() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        let file = AskSidePanelRecent.file(target("work/run.py"), conversationId: "c1")
        XCTAssertNotEqual(file.id, AskSidePanelRecent.file(target("work/run.py"), conversationId: "c2").id)
        XCTAssertEqual(file.title, "run.py")
        XCTAssertTrue(AskSidePanelRecent.web(url).matches(.web(try XCTUnwrap(URL(string: "https://example.com")))))
        XCTAssertFalse(AskSidePanelRecent.web(url).matches(file))
        XCTAssertTrue(AskSidePanelRecent.web(url).id.hasPrefix("web:"))
        XCTAssertEqual(AskSidePanelRecent.web(try XCTUnwrap(URL(string: "about:blank"))).title, "about:blank")
    }

    // MARK: Width and focus

    func testWidthIsKeptBetweenSessions() throws {
        let name = "AskSidePanelWidth." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AskSidePanelWidth.load(defaults: defaults), AskSidePanelWidth.defaultWidth)
        AskSidePanelWidth.save(642.4, defaults: defaults)
        XCTAssertEqual(AskSidePanelWidth.load(defaults: defaults), 642)
        // Widths below the panel's minimum, or not finite, are not kept.
        AskSidePanelWidth.save(100, defaults: defaults)
        AskSidePanelWidth.save(.infinity, defaults: defaults)
        XCTAssertEqual(AskSidePanelWidth.load(defaults: defaults), 642)
        // The browser panel's older value carries over; a broken one falls back.
        defaults.set(700.0, forKey: AskSidePanelWidth.key)
        XCTAssertEqual(AskSidePanelWidth.load(defaults: defaults), 700)
        defaults.set(12.0, forKey: AskSidePanelWidth.key)
        XCTAssertEqual(AskSidePanelWidth.load(defaults: defaults), AskSidePanelWidth.defaultWidth)
    }

    func testDraggedWidthLeavesTheConversationItsRoom() {
        let minimum = AskWorkspaceLayout.minimumDockedPanelWidth
        XCTAssertEqual(AskSidePanelWidth.clamped(10, windowWidth: 1400, sidebarWidth: 0), minimum)
        XCTAssertEqual(AskSidePanelWidth.clamped(600, windowWidth: 1400, sidebarWidth: 0), 600)
        XCTAssertEqual(AskSidePanelWidth.clamped(2000, windowWidth: 1400, sidebarWidth: 260),
                       1400 - 260 - AskWorkspaceLayout.minimumDockedContentWidth)
        // A window too narrow for both still gives the panel its minimum.
        XCTAssertEqual(AskSidePanelWidth.clamped(900, windowWidth: 500, sidebarWidth: 0), minimum)
    }

    func testFocusedPanelFillsTheWindow() {
        let size = CGSize(width: 1400, height: 900)
        let docked = AskWorkspaceLayout(size: size, sidebarCollapsed: false, showsUsage: true,
                                        rightPanelWidth: 560, docksRightPanel: true)
        XCTAssertEqual(docked.usageWidth, 560)
        XCTAssertGreaterThan(docked.mainWidth, 0)
        let focused = AskWorkspaceLayout(size: size, sidebarCollapsed: false, showsUsage: true,
                                         rightPanelWidth: 560, docksRightPanel: true, focusesRightPanel: true)
        XCTAssertEqual(focused.usageWidth, size.width)
        XCTAssertEqual(focused.mainWidth, 0)
        XCTAssertFalse(focused.sidebarInline)
        XCTAssertTrue(focused.usageInline)
        // Focus only applies to the docked side panel.
        let usage = AskWorkspaceLayout(size: size, sidebarCollapsed: false, showsUsage: true,
                                       rightPanelWidth: 390, focusesRightPanel: true)
        XCTAssertEqual(usage.usageWidth, 390)
    }

    // MARK: Quick Look

    func testOfficeAndIWorkFilesUseQuickLook() {
        for ext in ["docx", "XLSX", "pptx", "pages", "numbers", "key", "rtf", "odt", "mov"] {
            XCTAssertTrue(AskSidePanelQuickLook.previews(ext), ext)
            XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: ext), .unsupported,
                           "\(ext) is not rendered by the panel itself")
        }
        for ext in ["bin", "zip", "html", "md", ""] {
            XCTAssertFalse(AskSidePanelQuickLook.previews(ext), ext)
        }
    }
}

extension AskSidePanelArrangementTests {
    func testOpeningAMissingRecentShowsANotice() throws {
        let panel = AskSidePanel(browser: nil)
        for index in 0 ..< AskSidePanel.maxFileTabs {
            try panel.open(target("outputs/\(index).txt"), conversationId: "c1")
        }
        panel.notice = "old"
        panel.open(recent: .file(target("outputs/extra.txt"), conversationId: "c1"), conversationId: "c1")
        XCTAssertEqual(panel.notice, AskSidePanel.PanelError.tooManyFileTabs.errorDescription)
        panel.open(recent: .file(target("outputs/0.txt"), conversationId: "c1"), conversationId: "c1")
        XCTAssertNil(panel.notice)
        // Without a browser a page opens nowhere and reports nothing.
        panel.open(recent: .web(try XCTUnwrap(URL(string: "https://example.com"))), conversationId: "c1")
        XCTAssertNil(panel.notice)
    }

    func testDroppedFilesAreReadFromTheirProviders() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drop-" + UUID().uuidString + ".txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fileProvider = NSItemProvider(object: file as NSURL)
        let text = NSItemProvider(object: "not a file" as NSString)
        let web = NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com")) as NSURL)

        // Without a conversation, or without files, the drop is refused.
        XCTAssertFalse(AskSidePanelDrop.accept([fileProvider], conversationId: nil) { _ in XCTFail("No conversation") })
        XCTAssertFalse(AskSidePanelDrop.accept([text], conversationId: "c1") { _ in XCTFail("No files") })

        let added = expectation(description: "files added")
        var received: [URL] = []
        XCTAssertTrue(AskSidePanelDrop.accept([text, fileProvider], conversationId: "c1") { urls in
            received = urls
            added.fulfill()
        })
        await fulfillment(of: [added], timeout: 5)
        XCTAssertEqual(received.map(\.standardizedFileURL), [file.standardizedFileURL])
        // A web address is not a file.
        let none = await AskSidePanelDrop.fileURLs([web])
        XCTAssertTrue(none.isEmpty)
    }
}
