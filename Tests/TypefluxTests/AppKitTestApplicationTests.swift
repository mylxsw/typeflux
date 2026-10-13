import AppKit
import Testing

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AppKitTestApplicationTests {
    @Test func windowClosureKeepsTheRunnerAliveAndExplicitQuitIsReported() {
        let previous = NSApp.delegate
        var reports = 0
        let application = AppKitTestApplication(recordTermination: { reports += 1 })
        defer { application.restore() }
        #expect(NSApp.delegate === application)
        #expect(!application.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(reports == 0)
        #expect(application.applicationShouldTerminate(NSApp) == .terminateCancel)
        #expect(reports == 1)
        application.restore()
        #expect(NSApp.delegate === previous)
        application.restore()
        #expect(NSApp.delegate === previous)
    }

    @Test func restoringTheDelegateReleasesTheFixture() {
        weak var fixture: AppKitTestApplication?
        do {
            let application = AppKitTestApplication(recordTermination: {})
            fixture = application
            application.restore()
        }
        #expect(fixture == nil)
    }

    @Test func throwingCaseRestoresThePreviousApplicationDelegate() async throws {
        let previous = NSApp.delegate
        let trait = ExclusiveUIStateTrait()
        let test = try #require(Test.current)
        let testCase = try #require(Test.Case.current)
        await #expect(throws: Failure.self) {
            try await trait.provideScope(for: test, testCase: testCase) { throw Failure() }
        }
        #expect(NSApp.delegate === previous)
    }

    private struct Failure: Error {}
}
