@testable import Typeflux
import WebKit
import XCTest

/// Real DOM/JavaScript execution in WebKit. This does not replace Safari/Chrome
/// AppleScript or macOS permission acceptance; see AskAutomationAcceptanceTests.
@MainActor
final class AskBrowserDOMTests: XCTestCase {
    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/harness/fixtures/browser-observation.html")
    }

    private func page() async throws -> WKWebView {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        try view.loadHTMLString(String(contentsOf: Self.fixture), baseURL: URL(string: "https://fixture.invalid/"))
        for _ in 0 ..< 100 {
            if let ready = try? await view.evaluateJavaScript("typeof window.fixtureEvents !== 'undefined'"),
               ready as? Bool == true {
                return view
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "Fixture navigation timed out", code: 1)
    }

    private func snapshot(_ view: WKWebView, id: String = "version-1",
                          read: Bool = false) async throws -> [String: Any] {
        try await json(view, AskBrowserExecutor.observationScript(id: id, read: read))
    }

    private func json(_ view: WKWebView, _ script: String) async throws -> [String: Any] {
        let raw = try await view.evaluateJavaScript(script) as! String
        return try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
    }

    private func action(_ view: WKWebView, _ args: [String: Any],
                        id: String = "version-1") async throws -> [String: Any] {
        try await json(view, AskBrowserExecutor.actionScript(id: id, command: AskBrowserExecutor.command(args)))
    }

    func testNativeInputTextareaAndContenteditableEventsAndValueVerification() async throws {
        let view = try await page()
        for selector in ["#text", "#area", "#editable"] {
            let observed = try await snapshot(view, read: true)
            XCTAssertTrue((observed["text"] as? String)?.contains("controlled") == true)
            let text = selector == "#text" ? "Hello ' \" 世界🙂" : "Hello ' \"\n世界🙂"
            let result = try await action(view, ["action": "fill", "selector": selector, "text": text])
            XCTAssertEqual(result["status"] as? String, "ok")
            XCTAssertEqual(result["event_dispatched"] as? Bool, true)
            XCTAssertEqual(result["effect_verified"] as? Bool, true)
            XCTAssertTrue((result["message"] as? String)?.contains("persistence are unverified") == true)
        }
        let rawEvents = try await view.evaluateJavaScript("fixtureEvents.map(e=>e[0])")
        let events = try XCTUnwrap(rawEvents as? [String])
        XCTAssertEqual(events, ["input", "change", "input", "change", "input", "change"])
        // Framework-style own property setter must not suppress the native setter.
        _ = try await view
            .evaluateJavaScript(
                "Object.defineProperty(document.querySelector('#text'),'value',{set(v){},get(){return 'shadow'}});true"
            )
        _ = try await snapshot(view)
        let result = try await action(view, ["action": "fill", "selector": "#text", "text": "native"])
        XCTAssertEqual(result["effect_verified"] as? Bool, true)
        _ = try await view
            .evaluateJavaScript(
                "document.querySelector('#area').addEventListener('input',e=>e.target.value='rejected');true"
            )
        _ = try await snapshot(view)
        let rejected = try await action(view, ["action": "fill", "selector": "#area", "text": "attempt"])
        XCTAssertEqual(rejected["event_dispatched"] as? Bool, true)
        XCTAssertEqual(rejected["effect_verified"] as? Bool, false)
    }

    func testMissingUnsupportedReadonlyAndInvalidSelectorAreErrors() async throws {
        let view = try await page()
        for args: [String: Any] in [["action": "click", "selector": "#missing"], ["action": "click", "selector": "["],
                                    ["action": "fill", "selector": "#checkbox", "text": "true"], [
                                        "action": "fill",
                                        "selector": "#readonly",
                                        "text": "new"
                                    ],
                                    ["action": "click", "ref": "version-1:999"], [
                                        "action": "click",
                                        "ref": "version-1:0"
                                    ]] {
            _ = try await snapshot(view)
            let result = try await action(view, args)
            XCTAssertEqual(result["status"] as? String, "invalid")
            XCTAssertEqual(result["event_dispatched"] as? Bool, false)
        }
    }

    func testVersionedRefsOneShotAndStaleDOMNavigationOrGeometry() async throws {
        let view = try await page()
        let first = try await snapshot(view)
        let elements = try XCTUnwrap(first["elements"] as? [[String: Any]])
        let clickRef = try XCTUnwrap(elements.first { $0["name"] as? String == "Controlled click" }?["ref"] as? String)
        XCTAssertTrue(clickRef.hasPrefix("version-1:"))
        let click = try await action(view, ["action": "click", "ref": clickRef])
        XCTAssertEqual(click["status"] as? String, "ok"); XCTAssertEqual(click["effect_verified"] as? Bool, false)
        let replay = try await action(view, ["action": "click", "ref": clickRef])
        XCTAssertEqual(replay["message"] as? String, "needs-observation")
        _ = try await snapshot(view, id: "version-2")
        let stale = try await action(view, ["action": "click", "ref": clickRef], id: "version-2")
        XCTAssertEqual(stale["message"] as? String, "needs-observation")
        for change in ["document.querySelector('#text').outerHTML=document.querySelector('#text').outerHTML",
                       "document.querySelector('#click').setAttribute('data-test','redraw')", "location.hash='changed'",
                       "window.scrollTo(0,100)", "window.dispatchEvent(new Event('blur'))",
                       "document.dispatchEvent(new Event('visibilitychange'))"] {
            _ = try await snapshot(view)
            _ = try await view.evaluateJavaScript(change + ";true")
            let result = try await action(view, ["action": "click", "selector": "#click"])
            XCTAssertEqual(result["message"] as? String, "needs-observation", change)
            XCTAssertEqual(result["event_dispatched"] as? Bool, false)
        }
        _ = try await snapshot(view)
        view.frame.size.width = 600
        let resized = try await action(view, ["action": "click", "selector": "#click"])
        XCTAssertEqual(resized["message"] as? String, "needs-observation")
        let rawCount = try await view.evaluateJavaScript("fixtureClicks")
        let count = try XCTUnwrap(rawCount as? Int)
        XCTAssertEqual(count, 1)
    }

    func testScrollAndMissingObservationDoNotClaimBusinessEffect() async throws {
        let view = try await page()
        let absent = try await action(view, ["action": "back"])
        XCTAssertEqual(absent["message"] as? String, "needs-observation")
        _ = try await snapshot(view)
        let result = try await action(view, ["action": "scroll", "amount": 1])
        XCTAssertEqual(result["status"] as? String, "ok"); XCTAssertEqual(result["effect_verified"] as? Bool, false)
    }
}
