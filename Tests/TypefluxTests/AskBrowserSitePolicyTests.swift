@testable import Typeflux
import XCTest

@MainActor
final class AskBrowserSitePolicyTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AskBrowserSitePolicyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testUnknownSitesAskAndHostsAreNormalized() {
        let policy = AskBrowserSitePolicy(defaults: defaults())
        XCTAssertEqual(policy.permission(for: "github.com"), .ask)
        XCTAssertEqual(policy.permission(for: nil), .ask)
        XCTAssertEqual(policy.permission(for: ""), .ask)
        policy.set(.act, for: "WWW.GitHub.com")
        XCTAssertEqual(policy.permission(for: "github.com"), .act)
        XCTAssertEqual(policy.permission(for: "www.github.com"), .act)
        XCTAssertEqual(policy.permission(for: "gist.github.com"), .ask, "Subdomains are separate sites")
        XCTAssertNil(AskBrowserSitePolicy.normalized("  "))
    }

    func testPermissionsPersistAndCanBeRemoved() {
        let store = defaults()
        let policy = AskBrowserSitePolicy(defaults: store)
        policy.set(.off, for: "mail.google.com")
        policy.set(.read, for: "example.com")
        policy.set(.act, for: "")
        let reloaded = AskBrowserSitePolicy(defaults: store)
        XCTAssertEqual(reloaded.permission(for: "mail.google.com"), .off)
        XCTAssertEqual(reloaded.permission(for: "example.com"), .read)
        XCTAssertEqual(reloaded.permissions.count, 2)
        reloaded.remove("example.com")
        reloaded.remove("")
        XCTAssertEqual(AskBrowserSitePolicy(defaults: store).permission(for: "example.com"), .ask)
    }

    func testCorruptStoredValuesAreIgnored() {
        let store = defaults()
        store.set(["a.com": "bogus", "b.com": "read"], forKey: AskBrowserSitePolicy.defaultsKey)
        let policy = AskBrowserSitePolicy(defaults: store)
        XCTAssertEqual(policy.permission(for: "a.com"), .ask)
        XCTAssertEqual(policy.permission(for: "b.com"), .read)
    }

    func testActionKinds() {
        XCTAssertEqual(AskBrowserRisk.kind(action: "tabs", elementName: nil), .none)
        XCTAssertEqual(AskBrowserRisk.kind(action: "handoff", elementName: nil), .none)
        XCTAssertEqual(AskBrowserRisk.kind(action: "snapshot", elementName: nil), .observe)
        XCTAssertEqual(AskBrowserRisk.kind(action: "screenshot", elementName: nil), .observe)
        XCTAssertEqual(AskBrowserRisk.kind(action: "open", elementName: nil), .navigate)
        XCTAssertEqual(AskBrowserRisk.kind(action: "click", elementName: "Unread"), .write)
        XCTAssertEqual(AskBrowserRisk.kind(action: "fill", elementName: "Send"), .write, "Filling never sends")
        XCTAssertEqual(AskBrowserRisk.kind(action: "click", elementName: "Send message"), .sensitive)
        XCTAssertEqual(AskBrowserRisk.kind(action: "unknown", elementName: nil), .sensitive)
    }

    func testSensitiveWordsMatchWholeLatinWordsAndCJKSubstrings() {
        XCTAssertTrue(AskBrowserRisk.isSensitive("Place order"))
        XCTAssertTrue(AskBrowserRisk.isSensitive("DELETE repository"))
        XCTAssertTrue(AskBrowserRisk.isSensitive("立即支付"))
        XCTAssertTrue(AskBrowserRisk.isSensitive("메시지 전송"))
        XCTAssertFalse(AskBrowserRisk.isSensitive("Postman collections"))
        XCTAssertFalse(AskBrowserRisk.isSensitive("Reordering tips"))
        XCTAssertFalse(AskBrowserRisk.isSensitive(nil))
        XCTAssertFalse(AskBrowserRisk.isSensitive(""))
    }

    func testRiskTable() {
        typealias Risk = AskBrowserRisk
        XCTAssertEqual(Risk.risk(.none, permission: .off), .none)
        XCTAssertEqual(Risk.risk(.sensitive, permission: .act), .destructive)
        XCTAssertEqual(Risk.risk(.write, permission: .off), .read, "Off is refused at execution, not asked")
        for kind in [Risk.Kind.observe, .navigate, .write] {
            XCTAssertEqual(Risk.risk(kind, permission: .ask), .write)
        }
        XCTAssertEqual(Risk.risk(.observe, permission: .read), .read)
        XCTAssertEqual(Risk.risk(.navigate, permission: .read), .read)
        XCTAssertEqual(Risk.risk(.write, permission: .read), .write)
        XCTAssertEqual(Risk.risk(.write, permission: .act), .read)
        XCTAssertEqual(Risk.risk(.observe, permission: .act), .read)
    }

    func testAddressBarInput() throws {
        typealias Browser = AskBrowserWorkspace
        XCTAssertEqual(Browser.url(forInput: " https://github.com/x ")?.absoluteString, "https://github.com/x")
        XCTAssertEqual(Browser.url(forInput: "github.com/notifications")?.absoluteString, "https://github.com/notifications")
        XCTAssertEqual(Browser.url(forInput: "localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(Browser.url(forInput: "about:blank")?.absoluteString, "about:blank")
        let search = Browser.url(forInput: "typeflux 下载")
        XCTAssertEqual(search?.host, "www.google.com")
        let query = URLComponents(url: try XCTUnwrap(search), resolvingAgainstBaseURL: false)?.queryItems?.first
        XCTAssertEqual(query?.value, "typeflux 下载")
        XCTAssertEqual(Browser.url(forInput: "javascript:alert(1)")?.host, "www.google.com", "Scripts are searched, never run")
        XCTAssertNil(Browser.url(forInput: "   "))
    }

    func testNavigationPolicyAllowsOnlyWebSchemes() {
        XCTAssertTrue(AskBrowserTab.allowsNavigation(to: URL(string: "https://a.com")))
        XCTAssertTrue(AskBrowserTab.allowsNavigation(to: URL(string: "about:blank")))
        XCTAssertTrue(AskBrowserTab.allowsNavigation(to: nil))
        XCTAssertFalse(AskBrowserTab.allowsNavigation(to: URL(string: "file:///etc/passwd")))
        XCTAssertFalse(AskBrowserTab.allowsNavigation(to: URL(string: "mailto:a@b.c")))
        XCTAssertFalse(AskBrowserTab.allowsNavigation(to: URL(string: "javascript:alert(1)")))
    }
}
