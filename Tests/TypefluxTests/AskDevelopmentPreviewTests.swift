import Network
@testable import Typeflux
import WebKit
import XCTest

@MainActor final class AskDevelopmentPreviewTests: XCTestCase {
    typealias Fixture = AskProjectLoopTests.Fixture

    func testActualLeaseOriginScopeAndStopAreRequired() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        let preview = try fixture.tools.terminalPreview(
            lease.reference,
            entry: "index.html",
            resources: ["index.html", "app.js", "style.css"]
        )
        defer { preview.close() }
        let otherLease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(otherLease, ready: true)
        fixture.tools.cancelProjectRun(.init(ownerId: "owner", conversationId: "conversation", runId: "old-run"))
        XCTAssertEqual(try fixture.runtime.runtime.status(otherLease, scope: fixture.runtime.scope).state, .ready)
        XCTAssertThrowsError(try preview.validate(process: otherLease.reference))
        XCTAssertThrowsError(try preview.validate(address: fixture.runtime.runtime.serviceAddress(otherLease, scope: fixture.runtime.scope)))
        for property in ["id", "instance", "owner", "conversation", "run", "workspace"] {
            var forged = lease.reference
            switch property {
            case "id": forged.id = "other"
            case "instance": forged.instanceId = "previous-session"
            case "owner": forged.ownerId = "other"
            case "conversation": forged.conversationId = "other"
            case "run": forged.runId = "other"
            default: forged.workspaceId = "other"
            }
            XCTAssertThrowsError(try preview.validate(process: forged))
            XCTAssertThrowsError(try fixture.tools.terminalStatus(forged))
        }
        XCTAssertThrowsError(try preview.validate(address: URL(string: "http://localhost:\(lease.port!)")))
        for resources in [["../escape"], ["index.html", "index.html"], ["index.html?q=1"], []] {
            XCTAssertThrowsError(try fixture.tools.terminalPreview(
                lease.reference,
                entry: "index.html",
                resources: resources
            ))
        }
        do { _ = try await preview.load("../escape"); XCTFail("Expected rejection") } catch {}
        let data = try await preview.load("index.html")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Prototype"))
        let host = AskPreviewHost(); defer { host.close() }
        _ = try await host.open(.developmentService(process: lease.reference, address: preview.address), enabled: true,
                                development: preview) { _ in throw AskArtifactError.denied }
        try await AskProjectPreviewCapture.waitUntilLoaded(host)
        try fixture.tools.stopTerminal(lease.reference)
        XCTAssertNil(host.webView, "Stop closes the executable preview synchronously")
        XCTAssertThrowsError(try preview.validate())
        do { _ = try await preview.load("index.html"); XCTFail("Expected rejection") } catch {}
    }

    func testRevocationRunReplacementTimeoutAndShutdownInvalidatePages() async throws {
        for action in ["revoke", "replace", "timeout", "shutdown", "workspace"] {
            let fixture = try Fixture(); defer { fixture.close() }
            let lease = try await fixture.start("serve.py", service: true, timeout: action == "timeout" ? 1.5 : 10)
            _ = try await fixture.runtime.wait(lease, ready: true)
            let preview = try fixture.tools.terminalPreview(
                lease.reference,
                entry: "index.html",
                resources: ["index.html"]
            )
            defer { preview.close() }
            var invalidated = false; preview.invalidated = { invalidated = true }
            switch action {
            case "revoke": fixture.settings.askFileAccessFolders = []; fixture.runtime.runtime.reconcileAuthorization()
            case "replace": fixture.tools.bindExecution(
                    ownerId: "owner",
                    conversationId: "conversation",
                    runId: "new-run"
                )
            case "timeout": _ = try await fixture.runtime.wait(lease); fixture.runtime.runtime.reconcileAuthorization()
            case "workspace": fixture.runtime.runtime.workspaceDeleted(lease.workspace, scope: fixture.runtime.scope)
            default: fixture.runtime.runtime.shutdown()
            }
            XCTAssertTrue(invalidated, action); XCTAssertThrowsError(try preview.validate())
        }
    }

    func testRealBrowserBlocksOtherLeaseHTTPFileWebSocketAndSTUN() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let tcp = try NWListener(using: .tcp, on: .any), udp = try NWListener(using: .udp, on: .any)
        let listening = expectation(description: "TCP and UDP probes ready"); listening.expectedFulfillmentCount = 2
        let traffic = expectation(description: "No page network escapes"); traffic.isInverted = true
        for listener in [tcp, udp] {
            listener.stateUpdateHandler = {
                if case .ready = $0 {
                    listening.fulfill()
                }
            }
            listener.newConnectionHandler = { connection in traffic.fulfill(); connection.cancel() }
            listener.start(queue: .main)
        }
        defer { tcp.cancel(); udp.cancel() }
        await fulfillment(of: [listening], timeout: 5)
        let endpoint = try "http://127.0.0.1:\(XCTUnwrap(tcp.port).rawValue)"
        let html = """
        <h1>Network probe</h1><img src="\(endpoint)/img"><script src="\(endpoint)/js"></script>
        <iframe src="\(endpoint)/frame"></iframe><link rel="preconnect" href="\(endpoint)">
        <script>
        fetch('\(endpoint)/fetch').catch(()=>{});
        fetch('file:///etc/passwd').catch(()=>{});
        try { new WebSocket('ws://127.0.0.1:\(tcp.port!.rawValue)/socket'); } catch(e) {}
        try { navigator.sendBeacon('\(endpoint)/beacon','private'); } catch(e) {}
        try { const p = new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:\(udp.port!.rawValue)'}]});
        p.createDataChannel('leak');p.createOffer().then(x=>p.setLocalDescription(x)); } catch(e) {}
        </script>
        """
        try Data(html.utf8).write(to: fixture.runtime.source.appendingPathComponent("index.html"))
        let lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        let preview = try fixture.tools.terminalPreview(lease.reference, entry: "index.html", resources: ["index.html"])
        let host = AskPreviewHost(); defer { host.close() }
        let view = try await host.open(
            .developmentService(process: lease.reference, address: preview.address),
            enabled: true,
            development: preview
        ) { _ in throw AskArtifactError.denied }
        try await AskProjectPreviewCapture.waitUntilLoaded(host)
        let bridge = try await view.evaluateJavaScript("typeof window.webkit?.messageHandlers") as? String
        XCTAssertEqual(bridge, "undefined")
        _ = try? await view.evaluateJavaScript("location.href='\(endpoint)/navigate'")
        await fulfillment(of: [traffic], timeout: 1)
        let diagnostics = try await host.collectDiagnostics()
        XCTAssertFalse(diagnostics.errors.isEmpty)
    }

    func testProxyDeniesRedirectOversizedMissingAndCancelledResponses() async throws {
        for kind in ["redirect", "length", "stream", "missing", "cancel"] {
            let fixture = try Fixture(); defer { fixture.close() }
            let scriptURL = fixture.runtime.source.appendingPathComponent("serve.py")
            var script = try String(contentsOf: scriptURL)
            if kind == "redirect" {
                script = script.replacingOccurrences(of: "body = Path(resources[path]).read_bytes()", with:
                    "client.sendall(b'HTTP/1.1 302 Found\\r\\nLocation: http://127.0.0.1:1/leak\\r\\nContent-Length: 0\\r\\n\\r\\n'); continue")
            } else if kind == "stream" {
                script = script.replacingOccurrences(of: "body = Path(resources[path]).read_bytes()", with:
                    "client.sendall(b'HTTP/1.1 200 OK\\r\\nConnection: close\\r\\n\\r\\n' + b'x'*512); continue")
            }
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let lease = try await fixture.start("serve.py", service: true)
            _ = try await fixture.runtime.wait(lease, ready: true)
            let preview = try AskDevelopmentPreview(
                runtime: fixture.runtime.runtime,
                lease: lease,
                scope: fixture.runtime.scope,
                entry: "index.html",
                paths: ["index.html", "missing.html"],
                maximumFileBytes: kind == "length" || kind == "stream" ? 64 : 16384
            )
            defer { preview.close() }
            if kind == "cancel" {
                preview.close()
            }
            do { _ = try await preview.load(kind == "missing" ? "missing.html" : "index.html"); XCTFail(kind) } catch {}
        }
    }
}
