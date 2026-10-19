import AppKit
import Testing
import WebKit
@testable import Typeflux

@Suite("Ask Mermaid rendering", .serialized, .exclusiveUIState)
@MainActor struct AskMermaidRenderingTests {
    private final class HeightReceiver: NSObject, WKScriptMessageHandler {
        func userContentController(_: WKUserContentController, didReceive _: WKScriptMessage) {}
    }

    @Test func `bundled renderer draws a diagram from local resources`() async throws {
        _ = NSApplication.shared
        let page = try #require(AskMermaidResources.hostURL)
        let resources = try #require(AskMermaidResources.resourceURL)
        let receiver = HeightReceiver()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(receiver, name: "mermaidHeight")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadFileURL(page, allowingReadAccessTo: resources)

        var ready = false
        for _ in 0 ..< 100 {
            let value = try? await webView.evaluateJavaScript("typeof window.renderDiagram") as? String
            if value == "function" { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ready)
        guard ready else { return }

        _ = try await webView.callAsyncJavaScript("return await window.renderDiagram(source, false)",
                                                 arguments: ["source": "flowchart TD\nA[Start] --> B[End]"],
                                                 in: nil, contentWorld: .page)
        let svgValue = try await webView.evaluateJavaScript("document.querySelector('#diagram svg')?.outerHTML")
        let svg = try #require(svgValue as? String)
        #expect(svg.contains("Start"))
        #expect(svg.contains("End"))

        let multiline = "flowchart TD\nA[\"确定目标与平台<br/>手机 / PC / Web\"] --> B[\"提炼核心玩法\"]"
        _ = try await webView.callAsyncJavaScript("return await window.renderDiagram(source, true)",
                                                 arguments: ["source": multiline], in: nil, contentWorld: .page)
        let secondValue = try await webView.evaluateJavaScript("document.querySelector('#diagram svg')?.outerHTML")
        let second = try #require(secondValue as? String)
        #expect(second.contains("确定目标与平台"))
        #expect(second.contains("提炼核心玩法"))
        let labelValue = try await webView.evaluateJavaScript("document.querySelector('#diagram svg')?.textContent")
        let labelText = try #require(labelValue as? String)
        #expect(!labelText.contains("<br"))
    }
}
