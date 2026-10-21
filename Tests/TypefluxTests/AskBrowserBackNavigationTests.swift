import Network
import WebKit
import XCTest
@testable import Typeflux

/// Real HTTP documents are required: HTML-string loads do not establish Back history.
@MainActor
final class AskBrowserBackNavigationTests: XCTestCase {
    private enum Change { case sourceOff, destinationOff, none }

    func testBackRejectsSourceDisabledWhilePaused() async throws { try await checkBack(.sourceOff) }
    func testBackRejectsDestinationDisabledWhilePaused() async throws { try await checkBack(.destinationOff) }
    func testBackNavigatesBetweenUnchangedAllowedOrigins() async throws { try await checkBack(.none) }

    private func checkBack(_ change: Change) async throws {
        let source = try await server(title: "Source B")
        defer { source.stop() }
        let destination = try await server(title: "Destination A")
        defer { destination.stop() }
        let originA = try XCTUnwrap(destination.url)
        let originB = try XCTUnwrap(source.url)
        XCTAssertNotEqual(AskHTTPOrigin(originA), AskHTTPOrigin(originB))
        let name = "AskBrowserBackNavigationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let workspace = AskBrowserWorkspace(policy: AskBrowserSitePolicy(defaults: defaults), dataStore: .nonPersistent())
        defer { workspace.tabs.forEach { workspace.close($0) } }
        let tool = AskEmbeddedBrowserTool(workspace: workspace)
        for origin in [originA, originB] { workspace.policy.set(.read, for: origin.absoluteString) }
        let tab = try workspace.newTab()
        for (url, title) in [(originA, "Destination A"), (originB, "Source B")] {
            tab.load(url)
            try await tab.waitForLoad(timeout: .seconds(5))
            XCTAssertFalse(tab.isLoading)
            XCTAssertEqual(tab.url, url)
            XCTAssertEqual(tab.title, title, "The HTTP document must have loaded successfully")
        }
        _ = try XCTUnwrap(tab.webView.backForwardList.backItem)
        XCTAssertEqual(tab.webView.backForwardList.backItem?.url, originA)
        XCTAssertTrue(tab.canGoBack)
        let generation = tab.generation
        let authorized = expectation(description: "Pre-suspension authorization executed")
        var authorizationChecks = 0
        workspace.setPaused(true)
        let task = Task {
            try await tool.execute(["action": "back", "tab": tab.number], conversationId: "c") {
                authorizationChecks += 1
                if authorizationChecks == 1 { authorized.fulfill() }
            }
        }
        await fulfillment(of: [authorized], timeout: 5)
        XCTAssertEqual(authorizationChecks, 1)
        XCTAssertNil(workspace.activity)
        switch change {
        case .sourceOff: workspace.policy.set(.off, for: originB.absoluteString)
        case .destinationOff: workspace.policy.set(.off, for: originA.absoluteString)
        case .none: break
        }
        workspace.setPaused(false)
        do {
            let output = try await task.value
            if change == .none {
                XCTAssertFalse(output.isError)
                XCTAssertEqual(tab.url, originA)
                XCTAssertGreaterThan(tab.generation, generation)
                XCTAssertEqual(workspace.activity?.tabId, tab.id)
            } else {
                XCTFail("Off must deny Back before dispatch")
            }
        } catch {
            if change == .none { throw error }
            if change == .sourceOff {
                XCTAssertEqual(error.localizedDescription, L("ask.web.denied", AskHTTPOrigin(originB)!.description))
            }
        }
        XCTAssertEqual(authorizationChecks, change == .none ? 3 : 2)
        if change != .none {
            XCTAssertEqual(tab.url, originB)
            XCTAssertEqual(tab.generation, generation, "A refusal must not commit navigation")
            XCTAssertEqual(tab.webView.backForwardList.backItem?.url, originA)
            XCTAssertNil(workspace.activity, "A refusal must not start agent activity")
            XCTAssertFalse(tab.isLoading)
        }
    }

    private func server(title: String) async throws -> BackHTTPServer {
        let server = try BackHTTPServer(title: title)
        let ready = expectation(description: "Loopback HTTP listener ready")
        server.listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        server.listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        guard server.listener.port != nil else {
            server.stop()
            throw NSError(domain: "Loopback listener not ready", code: 1)
        }
        return server
    }
}

/// Callbacks run on the main queue; cancellation closes every accepted connection.
@MainActor
private final class BackHTTPServer {
    let listener: NWListener
    private var connections: [NWConnection] = []
    private var stopped = false
    var url: URL? { listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/") } }

    init(title: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let body = "<!doctype html><html><head><title>\(title)</title></head><body>\(title)</body></html>"
        let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, error in
                    guard error == nil else { connection.cancel(); return }
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    func stop() {
        stopped = true
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
