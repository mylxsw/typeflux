import Network
@testable import Typeflux
import WebKit
import XCTest

@MainActor final class AskPreviewHostTests: XCTestCase {
    func bundle(html: String) -> AskArtifactBundle {
        let data = Data(html.utf8)
        let ref = AskArtifactRef(id: UUID().uuidString.lowercased(), ownerId: "o", conversationId: "c", runId: "r",
                                 version: "1", mediaType: "text/html", sizeBytes: Int64(data.count),
                                 sha256: AskToolPolicy.digest(data), cleanup: "device_30_days")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "index.html", resources: []),
                     files: ["index.html": data, "app.js": Data("globalThis.localScript = 42".utf8),
                             "style.css": Data("body { color: rgb(1, 2, 3); }".utf8)])
    }

    func evaluate(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, completionHandler: { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            })
        }
    }

    func ready(_ view: WKWebView) async throws {
        for _ in 0 ..< 200 {
            if let state = try? await evaluate(view, "document.readyState"), state as? String == "complete",
               !view.isLoading,
               view.url?.scheme == AskPreviewPolicy.scheme {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Real WebKit page did not load")
        throw AskArtifactError.unavailable
    }

    func testPolicyRejectsCrossArtifactTraversalQueriesAndFileURLs() throws {
        let policy = AskPreviewPolicy(token: "test", paths: ["index.html", "a b.txt"])
        XCTAssertEqual(try policy.path(policy.url("a b.txt")), "a b.txt")
        XCTAssertEqual(
            try policy.path(XCTUnwrap(URL(string: "typeflux-artifact://test/index.html#section"))),
            "index.html"
        )
        for value in ["file:///etc/passwd", "https://example.com/index.html", "typeflux-artifact://other/index.html",
                      "typeflux-artifact://test/../outside", "typeflux-artifact://test/%2e%2e/outside",
                      "typeflux-artifact://test/%252e%252e/outside", "typeflux-artifact://test/missing",
                      "typeflux-artifact://user@test/index.html", "typeflux-artifact://test:80/index.html",
                      "typeflux-artifact://test/index.html?q=1", "typeflux-artifact://test/a%5cb"] {
            XCTAssertThrowsError(try policy.path(XCTUnwrap(URL(string: value))), value)
        }
        XCTAssertTrue(policy.contentSecurityPolicy.contains("sandbox allow-scripts;"))
        XCTAssertFalse(policy.contentSecurityPolicy.contains("allow-same-origin"))
    }

    func testRolloutAndDynamicSourceFailClosed() async throws {
        let host = AskPreviewHost()
        let data = bundle(html: "hi")
        do { _ = try await host.open(.artifact(data.manifest.ref), enabled: false) { _ in data }; XCTFail() }
        catch { XCTAssertEqual(error as? AskArtifactError, .previewDisabled) }
        let process = AskProcessRef(id: "p", ownerId: "o", conversationId: "c", runId: "r", workspaceId: "w",
                                    instanceId: "i", startedAt: Date(), cleanup: "app_session")
        do {
            _ = try await host.open(
                .developmentService(process: process, address: XCTUnwrap(URL(string: "http://127.0.0.1:9000"))),
                enabled: true
            ) { _ in data }
            XCTFail()
        } catch { XCTAssertEqual(error as? AskArtifactError, .dynamicUnavailable) }
        var ref = data.manifest.ref; ref.mediaType = "application/octet-stream"
        do { _ = try await host.open(.artifact(ref), enabled: true) { _ in data }; XCTFail() }
        catch { XCTAssertEqual(error as? AskArtifactError, .unsupported) }
    }

    func testRealWebKitRunsLocalScriptWithoutBridgeOrFileAuthority() async throws {
        let data = bundle(html: """
        <!doctype html><link rel="stylesheet" href="style.css"><script src="app.js"></script>
        <h1>Offline artifact</h1><script>globalThis.inlineScript = 7;</script>
        """)
        let host = AskPreviewHost()
        defer { host.close() }
        let view = try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in data }
        try await ready(view)
        let actual = try await evaluate(
            view,
            "[inlineScript, localScript, getComputedStyle(document.body).color, typeof window.webkit?.messageHandlers].join('|')"
        ) as? String
        XCTAssertEqual(actual, "7|42|rgb(1, 2, 3)|undefined")
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        _ = try await evaluate(
            view,
            "globalThis.fileResult = 'pending'; fetch('file:///etc/passwd').then(() => fileResult = 'read').catch(() => fileResult = 'blocked'); true"
        )
        try await Task.sleep(for: .milliseconds(100))
        let fileAccess = try await evaluate(view, "fileResult") as? String
        XCTAssertEqual(fileAccess, "blocked")
        let storage = try await evaluate(
            view,
            "(() => { try { localStorage.setItem('x','x'); return 'stored'; } catch(e) { return 'blocked'; } })()"
        ) as? String
        XCTAssertEqual(storage, "blocked")
    }

    func testRealWebKitBlocksOutboundRequestsAndCrossArtifactResources() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let listenerReady = expectation(description: "Listener ready")
        let received = expectation(description: "No outbound TCP connections")
        received.isInverted = true
        listener.stateUpdateHandler = {
            if case .ready = $0 {
                listenerReady.fulfill()
            }
        }
        listener.newConnectionHandler = { connection in received.fulfill(); connection.cancel() }
        listener.start(queue: .main)
        defer { listener.cancel() }
        await fulfillment(of: [listenerReady], timeout: 5)
        let port = try XCTUnwrap(listener.port).rawValue
        let endpoint = "http://127.0.0.1:\(port)"
        let data = bundle(html: """
        <script src="\(endpoint)/script"></script><link rel="stylesheet" href="\(endpoint)/style">
        <img src="\(endpoint)/image"><iframe src="\(endpoint)/frame"></iframe>
        <link rel="preconnect" href="\(endpoint)">
        <style>@import url('\(endpoint)/import'); body { background: url('\(endpoint)/background'); }</style>
        <form id="leak" action="\(endpoint)/form" method="POST"><input name="secret" value="private"></form>
        <script src="typeflux-artifact://another-artifact/stolen.js"></script>
        <script>
        globalThis.results = [];
        fetch('\(endpoint)/fetch').then(() => results.push('LEAK')).catch(() => results.push('fetch-blocked'));
        try { new WebSocket('ws://127.0.0.1:\(port)/socket'); } catch(e) { results.push('ws-blocked'); }
        try { navigator.sendBeacon('\(endpoint)/beacon', 'secret'); } catch(e) { results.push('beacon-blocked'); }
        try { new Worker('\(endpoint)/worker'); } catch(e) { results.push('worker-blocked'); }
        globalThis.popup = window.open('\(endpoint)/popup');
        document.getElementById('leak').submit();
        </script>
        """)
        let host = AskPreviewHost()
        var reports: [String] = []
        host.report = { reports.append($0) }
        defer { host.close() }
        let view = try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in data }
        try await ready(view)
        let result = try await evaluate(view, "results.join('|')") as? String ?? ""
        XCTAssertTrue(result.contains("fetch-blocked"))
        XCTAssertFalse(result.contains("LEAK"))
        let stolen = try await evaluate(view, "typeof stolen") as? String
        let popup = try await evaluate(view, "popup === null") as? Bool
        XCTAssertEqual(stolen, "undefined")
        XCTAssertEqual(popup, true)
        _ = try? await evaluate(view, "location.href = '\(endpoint)/navigate'")
        await fulfillment(of: [received], timeout: 1)
        host.check()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(reports.isEmpty)
        XCTAssertEqual(view.url?.scheme, AskPreviewPolicy.scheme)
    }

    func testRealWebKitReportsScriptErrorsMissingResourcesAndRevocation() async throws {
        let data =
            bundle(html: "<script src='missing.js'></script><script>throw new Error('broken generated page')</script>")
        let host = AskPreviewHost()
        var revoked = false, reports: [String] = []
        host.report = { reports.append($0) }
        let view = try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in
            if revoked {
                throw AskArtifactError.denied
            }; return data
        }
        defer { host.close() }
        try await ready(view)
        host.check()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(
            reports.contains { $0.contains("broken generated page") || $0.contains("Script error") },
            reports.joined(separator: " | ")
        )
        XCTAssertTrue(reports.contains { $0 == AskArtifactError.unavailable.localizedDescription })
        revoked = true
        host.check()
        XCTAssertNil(host.webView)
        XCTAssertNil(host.policy)
        XCTAssertEqual(reports.last, AskArtifactError.denied.localizedDescription)
    }

    func testRealWebKitCannotUseWebRTCOrNativeDialogs() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let listening = expectation(description: "UDP listener ready")
        let received = expectation(description: "No STUN traffic")
        received.isInverted = true
        listener.stateUpdateHandler = {
            if case .ready = $0 {
                listening.fulfill()
            }
        }
        listener.newConnectionHandler = { connection in received.fulfill(); connection.cancel() }
        listener.start(queue: .main)
        defer { listener.cancel() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port).rawValue
        let data = bundle(html: "<h1>Permission probe</h1>")
        let host = AskPreviewHost()
        defer { host.close() }
        var reports: [String] = []
        host.report = { reports.append($0) }
        let view = try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in data }
        try await ready(view)
        let rtc = try await evaluate(view, """
        (() => { try {
          const peer = new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:\(port)'}]});
          peer.createDataChannel('probe'); peer.createOffer().then(x => peer.setLocalDescription(x));
          return 'allowed';
        } catch(e) { return 'blocked'; } })()
        """) as? String
        XCTAssertEqual(rtc, "blocked")
        let dialogs = try await evaluate(
            view,
            "[confirm('confirmation'), prompt('prompt') === null].join('|')"
        ) as? String
        XCTAssertEqual(dialogs, "false|true")
        _ = try await evaluate(view, "alert('visible page alert'); true")
        // CSP sandbox blocks modal dialogs before any native UI is requested.
        XCTAssertFalse(reports.contains("visible page alert"))
        await fulfillment(of: [received], timeout: 1)
    }

    func testCloseAndRevocationDuringRuleCompilationDoNotPublishAView() async throws {
        let host = AskPreviewHost(), data = bundle(html: "<h1>unpublished</h1>")
        let cancelled = Task { @MainActor in
            try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in data }
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(host.webView)
        do {
            _ = try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in
                host.close()
                return data
            }
            XCTFail("Closed preview must not resume loading")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(host.webView)
        var loads = 0
        do {
            _ = try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in
                loads += 1
                if loads > 1 {
                    throw AskArtifactError.denied
                }
                return data
            }
            XCTFail("Revoked preview must not begin loading")
        } catch { XCTAssertEqual(error as? AskArtifactError, .denied) }
        XCTAssertNil(host.webView)
    }

    func testFileSelectionDoesNotReadFilesAndProcessFailureClosesPage() async throws {
        let host = AskPreviewHost(), data = bundle(html: "<h1>offline</h1>")
        var reports: [String] = []
        host.report = { reports.append($0) }
        let view = try await host.open(.artifact(data.manifest.ref), enabled: true) { _ in data }
        defer { host.close() }
        try await ready(view)
        _ = try await evaluate(view, "document.body.innerHTML += '<input id=f type=file>'; document.getElementById('f').click(); true")
        try await Task.sleep(for: .milliseconds(100))
        let files = try await evaluate(view, "document.getElementById('f').files.length") as? Int
        XCTAssertEqual(files, 0)
        let failure = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "page failed"])
        host.webView(view, didFail: nil, withError: failure)
        host.webView(view, didFailProvisionalNavigation: nil, withError: failure)
        XCTAssertEqual(reports.suffix(2), ["page failed", "page failed"])
        host.webViewWebContentProcessDidTerminate(view)
        XCTAssertNil(host.webView)
        XCTAssertEqual(reports.last, L("ask.artifact.pageFailed"))
    }
}
