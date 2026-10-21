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

    func testExactOriginsAndLegacyMigration() {
        let store = defaults()
        store.set(
            ["example.com": "act", "denied.com": "off", "www.double.com": "off", "broken.com": "bogus", "例子.测试": "off"],
            forKey: AskBrowserSitePolicy.defaultsKey
        )
        var owner = "a"
        let policy = AskBrowserSitePolicy(defaults: store, owner: { owner }, deviceId: "d")
        for value in [nil, "", "example.com", "https://example.com", "http://example.com", "data:x", "file:///tmp/x"] {
            XCTAssertEqual(policy.permission(for: value), .ask)
        }
        policy.set(.read, for: "https://EXAMPLE.com:443/path")
        XCTAssertEqual(policy.permission(for: "https://example.com/other"), .read)
        for value in [
            "http://example.com",
            "https://example.com:444",
            "https://www.example.com",
            "https://sub.example.com"
        ] {
            XCTAssertEqual(policy.permission(for: value), .ask)
        }
        for value in ["http://denied.com", "https://www.denied.com:444", "https://例子.测试", "https://www.例子.测试"] {
            XCTAssertEqual(policy.permission(for: value), .off)
        }
        XCTAssertEqual(policy.permission(for: "https://www.www.double.com"), .off)
        XCTAssertEqual(policy.permission(for: "https://www.double.com"), .ask)
        policy.set(.act, for: "https://www.denied.com")
        XCTAssertEqual(policy.permission(for: "https://www.denied.com"), .off)
        policy.remove("denied.com")
        XCTAssertEqual(policy.permission(for: "https://www.denied.com"), .act)
        policy.set(.act, for: "bare.com")
        XCTAssertEqual(policy.permissions.count, 2)
        owner = "b"
        XCTAssertTrue(policy.permissions.isEmpty)
        XCTAssertEqual(policy.permission(for: "https://example.com"), .ask)
        owner = "a"
        XCTAssertEqual(policy.permission(for: "https://example.com"), .read)
        XCTAssertEqual(
            AskBrowserSitePolicy(defaults: store, owner: { "a" }, deviceId: "d").permission(for: "https://example.com"),
            .read
        )
        XCTAssertEqual(
            AskBrowserSitePolicy(defaults: store, owner: { "a" }, deviceId: "other")
                .permission(for: "https://example.com"),
            .ask
        )
        policy.remove("https://example.com")
        policy.remove("")
        XCTAssertEqual(policy.permission(for: "https://example.com"), .ask)
        XCTAssertNil(AskBrowserSitePolicy.normalized("  "))
    }

    func testOriginParsingRejectsAmbiguousAuthority() {
        XCTAssertEqual(AskHTTPOrigin(string: "HTTP://example.com:80/a")?.description, "http://example.com")
        XCTAssertEqual(AskHTTPOrigin(string: "https://[2001:0db8::1]:443/a")?.description, "https://[2001:db8::1]")
        XCTAssertEqual(AskHTTPOrigin(string: "http://[::1]:8080")?.description, "http://[::1]:8080")
        for value in [
            "https://u:p@example.com",
            "https://u@example.com",
            "https://example.com:0",
            "https://example.com:65536",
            "https://example.com:bad", "https://example.com:", "https://example.com:999999999999999999999",
            "https://bad..com",
            "https://-bad.com",
            "https://bad_.com",
            "https://%00.com",
            "https://[garbage]",
            "file:///x",
            "data:x",
            "about:blank",
            "custom://example.com",
            "example.com",
            "https://"
        ] {
            XCTAssertNil(AskHTTPOrigin(string: value), value)
        }
        XCTAssertEqual(AskHTTPOrigin(string: "https://例子.测试")?.description, "https://xn--fsqu00a.xn--0zwm56d")
        XCTAssertNil(AskHTTPOrigin(nil))
    }

    func testActionKinds() {
        XCTAssertEqual(AskBrowserRisk.kind(action: "tabs", elementName: nil), .none)
        XCTAssertEqual(AskBrowserRisk.kind(action: "handoff", elementName: nil), .none)
        XCTAssertEqual(AskBrowserRisk.kind(action: "snapshot", elementName: nil), .observe)
        XCTAssertEqual(AskBrowserRisk.kind(action: "screenshot", elementName: nil), .observe)
        XCTAssertEqual(AskBrowserRisk.kind(action: "open", elementName: nil), .navigate)
        XCTAssertEqual(AskBrowserRisk.kind(action: "click", elementName: "Unread"), .sensitive)
        XCTAssertEqual(
            AskBrowserRisk.kind(action: "fill", elementName: "Send"),
            .sensitive,
            "Generic fills require fresh consent"
        )
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
