@testable import Typeflux
import WebKit
import XCTest

@MainActor
final class AskSidePanelTests: XCTestCase {
    private func makeBrowser() -> AskBrowserWorkspace {
        let name = "AskSidePanelTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AskBrowserWorkspace(policy: AskBrowserSitePolicy(defaults: defaults), dataStore: .nonPersistent())
    }

    private func target(_ path: String) -> AskSidePanelFileAccess.Target {
        .init(root: "/workspace", relativePath: path)
    }

    func testFilesTabIsPinnedShownFirstAndCannotClose() {
        let panel = AskSidePanel(browser: nil)
        XCTAssertNil(panel.selection)
        XCTAssertEqual(panel.tabs.map(\.id), [.files])
        panel.prepareForPresentation()
        XCTAssertEqual(panel.selection, .files)
        XCTAssertFalse(panel.canCloseSelection)
        panel.closeSelected()
        panel.close(.files)
        XCTAssertEqual(panel.tabs.map(\.id), [.files])
        XCTAssertNil(panel.selectedFileTab)
        // Without a browser there are no web tabs.
        XCTAssertNil(try panel.newWebTab())
        panel.presentBrowser()
        XCTAssertEqual(panel.selection, .files)
    }

    func testOpeningAFileTwiceSwitchesToItsTab() throws {
        let panel = AskSidePanel(browser: nil)
        let report = try panel.open(target("outputs/report.html"), conversationId: "c1")
        XCTAssertEqual(report.kind, .html)
        XCTAssertEqual(report.name, "report.html")
        let data = try panel.open(target("inputs/data.csv"), conversationId: "c1")
        XCTAssertEqual(panel.selection, .file(data.id))
        let again = try panel.open(target("outputs/report.html"), conversationId: "c1")
        XCTAssertTrue(again === report)
        XCTAssertEqual(panel.selection, .file(report.id))
        XCTAssertEqual(panel.fileTabs.count, 2)
        XCTAssertTrue(panel.selectedFileTab === report)
        XCTAssertTrue(panel.canCloseSelection)
        // The same path in another conversation's workspace is another file.
        let other = try panel.open(target("outputs/report.html"), conversationId: "c2")
        XCTAssertFalse(other === report)
        let forced = try panel.open(target("work/notes"), conversationId: "c1", kind: .text)
        XCTAssertEqual(forced.kind, .text)
    }

    func testFileTabsAreCapped() throws {
        let panel = AskSidePanel(browser: nil)
        for index in 0 ..< AskSidePanel.maxFileTabs {
            try panel.open(target("outputs/\(index).txt"), conversationId: "c1")
        }
        XCTAssertThrowsError(try panel.open(target("outputs/extra.txt"), conversationId: "c1")) { error in
            XCTAssertEqual(error as? AskSidePanel.PanelError, .tooManyFileTabs)
        }
        // An open file still switches over at the cap.
        XCTAssertNoThrow(try panel.open(target("outputs/0.txt"), conversationId: "c1"))
        panel.close(.file(panel.fileTabs[3].id))
        XCTAssertNoThrow(try panel.open(target("outputs/extra.txt"), conversationId: "c1"))
    }

    func testClosingSelectsTheTabBeforeOrFiles() throws {
        let panel = AskSidePanel(browser: nil)
        let first = try panel.open(target("a.txt"), conversationId: "c1")
        let second = try panel.open(target("b.txt"), conversationId: "c1")
        let third = try panel.open(target("c.txt"), conversationId: "c1")
        panel.select(.file(second.id))
        panel.closeSelected()
        XCTAssertEqual(panel.selection, .file(first.id))
        // Closing a tab that is not selected keeps the selection.
        panel.close(.file(third.id))
        XCTAssertEqual(panel.selection, .file(first.id))
        panel.close(.file(first.id))
        XCTAssertEqual(panel.selection, .files)
        XCTAssertTrue(panel.fileTabs.isEmpty)
        panel.select(.file(first.id)) // Closed: ignored.
        XCTAssertEqual(panel.selection, .files)
    }

    func testChangingConversationClosesOtherConversationsFiles() async throws {
        let panel = AskSidePanel(browser: nil)
        try panel.open(target("a.txt"), conversationId: "c1")
        let kept = try panel.open(target("b.txt"), conversationId: "c2")
        await panel.refreshFiles(conversationId: "c1") {
            (URL(fileURLWithPath: "/workspace"), [AskWorkspaceFile(relativePath: "inputs/a.txt", size: 1,
                                                                    modifiedAt: Date(), origin: .upload, messageId: nil)])
        }
        XCTAssertEqual(panel.files.count, 1)
        panel.retainFiles(conversationId: "c2")
        XCTAssertEqual(panel.fileTabs.map(\.id), [kept.id])
        XCTAssertTrue(panel.files.isEmpty)
        XCTAssertNil(panel.filesRoot)
        XCTAssertEqual(panel.filesConversationId, "c2")
        panel.retainFiles(conversationId: nil)
        XCTAssertTrue(panel.fileTabs.isEmpty)
        XCTAssertEqual(panel.selection, .files)
    }

    func testFileRefreshKeepsOnlyTheLatestResult() async throws {
        let panel = AskSidePanel(browser: nil)
        let file = AskWorkspaceFile(relativePath: "outputs/new.txt", size: 1, modifiedAt: Date(), origin: .generated,
                                    messageId: nil)
        let gate = AsyncStream<Void>.makeStream()
        let slow = Task { @MainActor in
            await panel.refreshFiles(conversationId: "c1") {
                for await _ in gate.stream { break }
                return (URL(fileURLWithPath: "/old"), [])
            }
        }
        await Task.yield()
        XCTAssertTrue(panel.filesLoading)
        await panel.refreshFiles(conversationId: "c1") { (URL(fileURLWithPath: "/new"), [file]) }
        gate.continuation.yield()
        await slow.value
        XCTAssertEqual(panel.files, [file])
        XCTAssertEqual(panel.filesRoot?.path, "/new")
        XCTAssertFalse(panel.filesLoading)

        struct Failure: LocalizedError { var errorDescription: String? { "disk unavailable" } }
        await panel.refreshFiles(conversationId: "c1") { throw Failure() }
        XCTAssertEqual(panel.filesError, "disk unavailable")
        await panel.refreshFiles(conversationId: "c1") { nil }
        XCTAssertNil(panel.filesError)
        XCTAssertTrue(panel.files.isEmpty)
        await panel.refreshFiles(conversationId: nil) { XCTFail("No conversation, nothing to load"); return nil }
        XCTAssertNil(panel.filesRoot)
    }

    func testFileTabsReloadAndKeepTheirMode() throws {
        let panel = AskSidePanel(browser: nil)
        let tab = try panel.open(target("README.md"), conversationId: "c1")
        XCTAssertEqual(tab.kind, .markdown)
        tab.showsSource = true
        panel.reloadFileTabs()
        XCTAssertEqual(tab.revision, 1)
        XCTAssertTrue(tab.showsSource)
    }

    func testWebTabsShareTheStripWithFiles() throws {
        let browser = makeBrowser()
        let existing = try browser.newTab()
        let panel = AskSidePanel(browser: browser)
        XCTAssertEqual(panel.tabs.map(\.id), [.files, .web(existing.id)])
        let file = try panel.open(target("a.txt"), conversationId: "c1")
        let page = try XCTUnwrap(try panel.newWebTab(isPrivate: true))
        XCTAssertTrue(page.isPrivate)
        XCTAssertEqual(panel.tabs.map(\.id), [.files, .web(existing.id), .file(file.id), .web(page.id)])
        XCTAssertEqual(panel.selection, .web(page.id))
        panel.select(.web(existing.id))
        XCTAssertEqual(browser.selectedTabId, existing.id, "Selecting a web tab selects it in the browser")
        if case let .web(tab)? = panel.selectedTab { XCTAssertTrue(tab === existing) } else { XCTFail("Web tab selected") }

        // The AI opens and closes pages through the browser workspace.
        let agentTab = try browser.newTab(owner: .agent(conversationId: "c1"), select: false)
        XCTAssertEqual(panel.tabs.last?.id, .web(agentTab.id))
        panel.select(.web(agentTab.id))
        browser.close(agentTab)
        XCTAssertFalse(panel.tabs.contains { $0.id == .web(agentTab.id) })
        XCTAssertEqual(panel.selection, .web(page.id), "The tab before the closed page is shown")

        panel.close(.web(page.id))
        XCTAssertNil(browser.tab(id: page.id))
        XCTAssertEqual(panel.selection, .file(file.id))
        panel.close(.web(existing.id))
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertEqual(panel.tabs.map(\.id), [.files, .file(file.id)])
    }

    func testPresentingTheBrowserOpensAPageWhenNoneIsOpen() throws {
        let browser = makeBrowser()
        let panel = AskSidePanel(browser: browser)
        panel.showFiles()
        panel.presentBrowser()
        let tab = try XCTUnwrap(browser.selectedTab)
        XCTAssertEqual(panel.selection, .web(tab.id))
        let second = try browser.newTab(select: false)
        panel.showFiles()
        panel.presentBrowser()
        XCTAssertEqual(panel.selection, .web(tab.id), "Shows the browser's selected page")
        browser.select(second)
        panel.presentBrowser()
        XCTAssertEqual(panel.selection, .web(second.id))
        // A remembered selection survives reopening the panel.
        panel.prepareForPresentation()
        XCTAssertEqual(panel.selection, .web(second.id))
        browser.tabs.forEach { browser.close($0) }
        panel.prepareForPresentation()
        XCTAssertEqual(panel.selection, .files)
    }

    func testFullBrowserReportsAnError() throws {
        let panel = AskSidePanel(browser: makeBrowser())
        for _ in 0 ..< AskBrowserWorkspace.maxTabs { try panel.newWebTab() }
        XCTAssertThrowsError(try panel.newWebTab())
        panel.browser?.tabs.forEach { panel.browser?.close($0) }
    }
}

extension AskSidePanelTests {
    func testAWebTabFollowsTheBrowserButFilesStayPut() throws {
        let browser = makeBrowser()
        let panel = AskSidePanel(browser: browser)
        let first = try XCTUnwrap(try panel.newWebTab())
        let second = try browser.newTab(select: false)
        browser.select(second)
        XCTAssertEqual(panel.selection, .web(second.id), "The AI switched pages while a page showed")
        panel.showFiles()
        browser.select(first)
        XCTAssertEqual(panel.selection, .files)
        browser.tabs.forEach { browser.close($0) }
    }
}
