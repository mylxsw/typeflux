@testable import Typeflux
import WebKit
import XCTest

@MainActor
final class AskBrowserWorkspaceTests: XCTestCase {
    private func makeWorkspace() -> AskBrowserWorkspace {
        let name = "AskBrowserWorkspaceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AskBrowserWorkspace(policy: AskBrowserSitePolicy(defaults: defaults), dataStore: .nonPersistent())
    }

    func testTabsAreNumberedSelectedAndCapped() throws {
        let workspace = makeWorkspace()
        let first = try workspace.newTab()
        let second = try workspace.newTab(select: false)
        XCTAssertEqual([first.number, second.number], [1, 2])
        XCTAssertEqual(workspace.selectedTab?.id, first.id)
        XCTAssertEqual(workspace.tab(number: 2)?.id, second.id)
        XCTAssertEqual(first.displayTitle, L("ask.web.newTab"))
        for _ in 2 ..< AskBrowserWorkspace.maxTabs { try workspace.newTab() }
        XCTAssertThrowsError(try workspace.newTab()) { error in
            XCTAssertEqual(error.localizedDescription,
                           AskBrowserWorkspace.WorkspaceError.tooManyTabs.localizedDescription)
        }
        workspace.tabs.forEach { workspace.close($0) }
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.selectedTabId)
    }

    func testClosingTheSelectedTabSelectsItsNeighbour() throws {
        let workspace = makeWorkspace()
        let first = try workspace.newTab(), second = try workspace.newTab(), third = try workspace.newTab()
        workspace.select(second)
        workspace.close(second)
        XCTAssertEqual(workspace.selectedTabId, first.id)
        workspace.close(first)
        XCTAssertEqual(workspace.selectedTabId, third.id)
        workspace.close(third)
        workspace.close(third) // Already closed: no effect.
        XCTAssertTrue(workspace.tabs.isEmpty)
    }

    func testPrivateTabsUseANonPersistentStoreAndSafariUserAgent() throws {
        let workspace = makeWorkspace()
        let normal = try workspace.newTab()
        let secret = try workspace.newTab(isPrivate: true)
        XCTAssertTrue(normal.webView.configuration.websiteDataStore === workspace.dataStore)
        XCTAssertFalse(secret.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(secret.webView.configuration.websiteDataStore === workspace.dataStore)
        XCTAssertEqual(normal.webView.configuration.applicationNameForUserAgent,
                       AskBrowserWorkspace.applicationNameForUserAgent)
        workspace.tabs.forEach { workspace.close($0) }
    }

    func testPersistentProfileIsSeparateFromTheDefaultStore() {
        let store = AskBrowserWorkspace.persistentStore()
        XCTAssertTrue(store.isPersistent)
        if #available(macOS 14.0, *) {
            XCTAssertEqual(store.identifier, AskBrowserWorkspace.profileIdentifier)
        }
    }

    func testPopupsOpenAsTabsWithTheOpenerOwner() throws {
        let workspace = makeWorkspace()
        let opener = try workspace.newTab(owner: .agent(conversationId: "c1"))
        let configuration = workspace.configuration(isPrivate: false)
        let popup = try XCTUnwrap(opener.openPopup?(configuration))
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertTrue(workspace.tabs[1].webView === popup)
        XCTAssertEqual(workspace.tabs[1].owner, .agent(conversationId: "c1"))
        workspace.tabs.forEach { workspace.close($0) }
    }

    func testClosingAHandoffTabCancelsIt() async throws {
        let workspace = makeWorkspace()
        let tab = try workspace.newTab()
        let presentation = workspace.presentationRequest
        let task = Task { await workspace.requestHandoff(tab: tab, reason: .payment, message: "") }
        for _ in 0 ..< 100 where workspace.handoff == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(workspace.presentationRequest, presentation)
        workspace.close(tab)
        let completed = await task.value
        XCTAssertFalse(completed)
        XCTAssertNil(workspace.handoff)
    }

    func testANewHandoffReplacesAnOlderOne() async throws {
        let workspace = makeWorkspace()
        let tab = try workspace.newTab()
        let first = Task { await workspace.requestHandoff(tab: tab, reason: .login, message: "a") }
        for _ in 0 ..< 100 where workspace.handoff == nil { try await Task.sleep(for: .milliseconds(10)) }
        let second = Task { await workspace.requestHandoff(tab: tab, reason: .verification, message: "b") }
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        for _ in 0 ..< 100 where workspace.handoff?.message != "b" { try await Task.sleep(for: .milliseconds(10)) }
        workspace.finishHandoff(completed: true)
        let secondResult = await second.value
        XCTAssertTrue(secondResult)
        workspace.close(tab)
    }

    func testSitesMergePermissionsAndStoredData() async throws {
        let workspace = makeWorkspace()
        workspace.policy.set(.read, for: "www.example.com")
        var sites = await workspace.sites()
        XCTAssertEqual(sites.map(\.host), ["example.com"])
        XCTAssertEqual(sites.first?.permission, .read)
        XCTAssertEqual(sites.first?.hasData, false)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/", .name: "session",
                                                             .value: "1", .secure: "TRUE",
                                                             .expires: Date().addingTimeInterval(3600)]))
        await workspace.dataStore.httpCookieStore.setCookie(cookie)
        sites = await workspace.sites()
        XCTAssertEqual(sites.first { $0.host == "fixture.invalid" }?.hasData, true)
        XCTAssertEqual(sites.first { $0.host == "fixture.invalid" }?.permission, .ask)
        await workspace.clearData(for: "fixture.invalid")
        sites = await workspace.sites()
        XCTAssertNil(sites.first { $0.host == "fixture.invalid" })
        await workspace.dataStore.httpCookieStore.setCookie(cookie)
        await workspace.clearAllData()
        let cookies = await workspace.dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty)
        await workspace.clearData(for: "nothing.invalid") // No records: no effect.
    }

    func testTabReportsFailuresButNotCancellationsAndRecoversFromCrashes() throws {
        let workspace = makeWorkspace()
        let tab = try workspace.newTab()
        tab.webView(tab.webView, didFailProvisionalNavigation: nil,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        tab.webView(tab.webView, didFail: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertNil(tab.notice, "Cancelled and policy-interrupted loads are not failures")
        tab.webView(tab.webView, didFail: nil,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                       userInfo: [NSLocalizedDescriptionKey: "Server not found"]))
        XCTAssertEqual(tab.notice, "Server not found")
        let generation = tab.generation
        tab.webViewWebContentProcessDidTerminate(tab.webView)
        XCTAssertEqual(tab.notice, L("ask.web.crashed"))
        XCTAssertGreaterThan(tab.generation, generation, "Observations from before the crash are stale")
        tab.load(URL(string: "https://fixture.invalid/")!)
        XCTAssertNil(tab.notice, "A new navigation clears the notice")
        workspace.close(tab)
    }

    // MARK: - AskLocalTools integration

    func testLocalToolsOfferTheToolOnlyWithABrowser() async throws {
        let tools = AskLocalTools(registry: MCPRegistry())
        var names = await tools.definitions(conversationId: nil).map(\.name)
        XCTAssertFalse(names.contains("web_browser"))
        XCTAssertNil(tools.browserWorkspace)
        let workspace = makeWorkspace()
        tools.embeddedBrowser = AskEmbeddedBrowserTool(workspace: workspace)
        names = await tools.definitions(conversationId: nil).map(\.name)
        XCTAssertTrue(names.contains("web_browser"))
        XCTAssertTrue(tools.browserWorkspace === workspace)
    }

    func testLocalToolsRouteRiskApprovalAndExecution() async throws {
        let tools = AskLocalTools(registry: MCPRegistry())
        let call: (String) -> AskToolCall = { arguments in
            AskToolCall(id: "1", function: .init(name: "web_browser", arguments: arguments))
        }
        XCTAssertEqual(AskLocalTools.builtinRisk(call(#"{"action":"read"}"#)), .read)
        XCTAssertEqual(AskLocalTools.builtinRisk(call(#"{"action":"click"}"#)), .write)
        do {
            _ = try await tools.approvalBinding(for: call(#"{"action":"tabs"}"#), conversationId: "c1")
            XCTFail("No browser configured")
        } catch {}
        let workspace = makeWorkspace()
        tools.embeddedBrowser = AskEmbeddedBrowserTool(workspace: workspace)
        XCTAssertEqual(tools.risk(of: call(#"{"action":"tabs"}"#)), AskToolRisk.none)
        XCTAssertEqual(tools.risk(of: call("not json")), .destructive)
        let binding = try await tools.approvalBinding(for: call(#"{"action":"tabs"}"#), conversationId: "c1")
        XCTAssertEqual(binding.target.kind, "browser_tab")
        XCTAssertFalse(binding.allowsReuse)
        let output = try await tools.execute(call(#"{"action":"tabs"}"#), conversationId: "c1")
        XCTAssertTrue(output.content.contains("No tabs are open"))
        let approved = try await tools.executeApproved(call(#"{"action":"tabs"}"#), conversationId: "c1",
                                                       binding: binding, authorize: {})
        XCTAssertEqual(approved.content, output.content)
    }
}
