import Foundation
import Testing
import XCTest
@testable import Typeflux

final class FeatureAnalyticsSpy: AnalyticsEventReporting, @unchecked Sendable {
    struct Event { let name: String; let properties: [String: String] }
    private let lock = NSLock()
    private var storage: [Event] = []
    var events: [Event] { lock.withLock { storage } }
    func report(eventName: String, properties: [String: String]) {
        lock.withLock { storage.append(Event(name: eventName, properties: properties)) }
    }
    func reportFirstOpenIfNeeded() {}
}

final class FeatureUsageAnalyticsTests: XCTestCase {
    func testTerminalRaceReportsExactlyOnceWithSameFlow() {
        let spy = FeatureAnalyticsSpy()
        let run = FeatureUsageAnalytics(reporter: spy).start(.workflow, properties: ["execution_kind": "submitted"])
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            run.finish(index.isMultiple(of: 2) ? .completed : .cancelled)
        }
        XCTAssertEqual(spy.events.count, 2)
        XCTAssertEqual(spy.events.first?.name, "workflow_started")
        XCTAssertEqual(spy.events.first?.properties["flow_id"], spy.events.last?.properties["flow_id"])
        XCTAssertNotNil(Int(spy.events.last?.properties["duration_ms"] ?? ""))
    }

    func testChildReporterForwardsToHostWithoutCreatingAnotherQueue() throws {
        let received = expectation(description: "forwarded")
        let reporter = FeatureProcessAnalyticsReporter { command in
            XCTAssertEqual(command.destination, .host)
            XCTAssertEqual(command.action, "analyticsEvent")
            let message = try? JSONDecoder().decode(FeatureProcessAnalyticsReporter.Message.self, from: command.payload)
            XCTAssertEqual(message?.eventName, "clipboard_opened")
            XCTAssertEqual(message?.properties["feature"], "clipboard")
            received.fulfill()
        }
        FeatureUsageAnalytics(reporter: reporter).event(.clipboard, "opened")
        wait(for: [received], timeout: 1)
    }

    func testActionMetadataDoesNotContainAssociatedContent() {
        XCTAssertEqual(AskPluginAction.Kind.copy("private content").analyticsName, "copy")
        XCTAssertEqual(AskPluginAction.Kind.open(URL(string: "https://private.example/secret")!).analyticsName, "open")
        XCTAssertEqual(ScreenshotOutputAction.followUp(.translate).analyticsName, ScreenshotFollowUp.translate.rawValue)
    }
}

@Suite("Feature usage integration", .exclusiveUIState)
@MainActor
struct FeatureUsageIntegrationTests {
    @Test func livePreviewsDoNotCountAsExecutionsAndResultUseCountsOnce() async throws {
        let plugin = AskTestPlugin()
        let spy = FeatureAnalyticsSpy()
        let keyword = AskKeyword(keyword: "my-private-alias", pluginID: plugin.id)
        let session = AskPluginSession(plugins: [plugin]) { [keyword] }
        session.analytics = FeatureUsageAnalytics(reporter: spy)
        session.debounce = .zero
        session.enter(keyword)
        session.update(text: "private input", selection: nil, language: .english)
        for _ in 0..<200 where session.output == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.output != nil)
        #expect(spy.events.map(\.name) == ["keyword_activated"])
        session.recordResultUse()
        session.recordResultUse()
        #expect(spy.events.map(\.name) == ["keyword_activated", "keyword_executed"])
        #expect(spy.events.allSatisfy { !$0.properties.values.contains("my-private-alias") && !$0.properties.values.contains("private input") })
        #expect(spy.events.last?.properties["plugin_id"] == "custom")
        session.deactivate()
    }

    @Test func submissionCountsOnceAndCustomKeywordDoesNotLeak() async throws {
        let plugin = AskTestPlugin(); plugin.live = false
        let spy = FeatureAnalyticsSpy()
        let keyword = AskKeyword(keyword: "secret", pluginID: plugin.id)
        let session = AskPluginSession(plugins: [plugin]) { [keyword] }
        session.analytics = FeatureUsageAnalytics(reporter: spy)
        session.enter(keyword)
        session.update(text: "confidential", selection: nil, language: .english)
        for _ in 0..<200 where session.plan == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.run())
        for _ in 0..<200 where session.output == nil { try await Task.sleep(for: .milliseconds(5)) }
        session.recordResultUse()
        #expect(spy.events.filter { $0.name == "keyword_executed" }.count == 1)
        #expect(spy.events.filter { $0.name == "launcher_action_executed" }.count == 1)
        #expect(spy.events.allSatisfy { $0.properties["keyword_id"] == nil })
        session.deactivate()
    }

    @Test func planOnlyKeywordsCountWhenTheirActionIsUsed() async throws {
        let plugin = AskTestPlugin(); plugin.live = false
        plugin.planActions = [AskPluginAction(kind: .openChat, title: "Open", symbol: "star")]
        let keyword = plugin.defaultKeywords[0]
        let spy = FeatureAnalyticsSpy()
        let session = AskPluginSession(plugins: [plugin]) { [keyword] }
        session.analytics = FeatureUsageAnalytics(reporter: spy)
        session.enter(keyword)
        session.update(text: "command", selection: nil, language: .english)
        for _ in 0..<200 where session.plan == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.output == nil)
        session.recordResultUse()
        session.recordResultUse()
        #expect(spy.events.filter { $0.name == "keyword_executed" }.count == 1)
        #expect(plugin.runs.isEmpty)
        session.deactivate()
    }

    @Test func chainedKeywordIsDistinguishedFromUserSubmission() async throws {
        let plugin = AskTestPlugin(); plugin.live = false
        let spy = FeatureAnalyticsSpy()
        let keyword = plugin.defaultKeywords[0]
        let session = AskPluginSession(plugins: [plugin]) { [keyword] }
        session.analytics = FeatureUsageAnalytics(reporter: spy)
        session.chain(to: keyword, text: "generated argument", chain: ["private-parent"], selection: nil, language: .english)
        for _ in 0..<200 where session.output == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(spy.events.first { $0.name == "keyword_executed" }?.properties["execution_kind"] == "workflow_chain")
        #expect(spy.events.allSatisfy { !$0.properties.values.contains("private-parent") })
        session.deactivate()
    }

    @Test func translationPanelDoesNotResubmitWhenCopyingOrImporting() async throws {
        let fixture = TranslationPanelFixture(); defer { fixture.clean() }
        let spy = FeatureAnalyticsSpy()
        let model = fixture.model
        model.analytics = FeatureUsageAnalytics(reporter: spy)
        model.open(source: .input)
        model.text = "Hello world"
        model.translate()
        for _ in 0..<400 where model.running { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.running)
        #expect(spy.events.filter { $0.name == "translation_started" }.count == 1)
        #expect(spy.events.filter { $0.name == "translation_completed" }.count == 1)
        if let output = model.output { model.importLauncher(output) }
        model.copy(number: 1)
        model.dismiss()
        #expect(spy.events.filter { $0.name == "translation_started" }.count == 1)
        #expect(!spy.events.contains { $0.name == "translation_cancelled" })
    }
}

extension FeatureUsageIntegrationTests {
    @Test func workflowReportsCompletionAndSanitizesCustomIdentity() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("private-client-workflow", manifest: AskWorkflowFixture.inline("private-client-workflow", keyword: "private-keyword", script: "ignored"))
        fixture.store.reload()
        fixture.store.trust("private-client-workflow")
        var plugin = try #require(fixture.store.plugins { (nil, nil) }.first)
        plugin.runner = AnalyticsWorkflowRunner()
        plugin.searchPath = { "/usr/bin:/bin" }
        let keyword = try #require(plugin.defaultKeywords.first)
        let spy = FeatureAnalyticsSpy()
        let session = AskPluginSession(plugins: [plugin]) { [keyword] }
        session.analytics = FeatureUsageAnalytics(reporter: spy)
        session.enter(keyword)
        session.update(text: "private input", selection: nil, language: .english, runWhenPlanned: true)
        for _ in 0..<400 where session.output == nil && session.failure == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.output != nil)
        let events = spy.events.filter { $0.name.hasPrefix("workflow_") }
        #expect(events.map(\.name) == ["workflow_started", "workflow_completed"])
        #expect(events.first?.properties["flow_id"] == events.last?.properties["flow_id"])
        #expect(events.allSatisfy { $0.properties["workflow_id"] == nil && $0.properties["workflow_source"] == "custom" })
        #expect(events.allSatisfy { !$0.properties.values.contains("private input") })
        session.deactivate()
        #expect(!spy.events.contains { $0.name == "workflow_cancelled" })
    }

    @Test func workflowFailureIsBoundedAndDoesNotUploadStderr() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("failure", manifest: AskWorkflowFixture.inline("failure", script: "ignored"))
        fixture.store.reload(); fixture.store.trust("failure")
        var plugin = try #require(fixture.store.plugins { (nil, nil) }.first)
        plugin.runner = AnalyticsWorkflowRunner(exitCode: 1)
        plugin.searchPath = { "/usr/bin:/bin" }
        let keyword = try #require(plugin.defaultKeywords.first)
        let spy = FeatureAnalyticsSpy()
        let session = AskPluginSession(plugins: [plugin]) { [keyword] }
        session.analytics = FeatureUsageAnalytics(reporter: spy)
        session.enter(keyword)
        session.update(text: "input", selection: nil, language: .english, runWhenPlanned: true)
        for _ in 0..<400 where session.failure == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.failure != nil)
        #expect(spy.events.filter { $0.name.hasPrefix("workflow_") }.map(\.name) == ["workflow_started", "workflow_failed"])
        #expect(spy.events.last?.properties["error_kind"] == "execution_failed")
        #expect(spy.events.allSatisfy { !$0.properties.values.contains("private stderr") })
        session.deactivate()
    }
}

private struct AnalyticsWorkflowRunner: AskWorkflowRunning {
    var exitCode: Int32 = 0
    func run(_ invocation: AskWorkflowInvocation) -> AsyncThrowingStream<AskWorkflowRunEvent, Error> {
        AsyncThrowingStream { stream in
            stream.yield(.finished(.init(exitCode: exitCode, stdout: "result", stderr: "private stderr", duration: 0.01)))
            stream.finish()
        }
    }
}
