import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class RingActionExecutorTests: XCTestCase {
    private var environment: FakeRingEnvironment!
    private var executor: RingActionExecutor!
    private var failures: [String] = []
    private var features: [RingFeature] = []
    private var keywords: [KeywordHotkey] = []

    override func setUp() {
        super.setUp()
        environment = FakeRingEnvironment()
        executor = RingActionExecutor(environment: environment)
        failures = []
        features = []
        keywords = []
        executor.onFailure = { [weak self] in self?.failures.append($0) }
        executor.handlers = RingActionExecutor.Handlers(
            feature: { [weak self] in self?.features.append($0) },
            keyword: { [weak self] in self?.keywords.append($0) }
        )
    }

    override func tearDown() {
        environment = nil
        executor = nil
        super.tearDown()
    }

    private func run(_ kind: RingActionKind) async {
        await executor.perform(RingAction(kind: kind, title: "t", symbol: "s"), previousApplication: nil)
    }

    func testFeaturesAndKeywordsGoToTheApp() async {
        await run(.feature(.clipboard))
        await run(.keyword(keyword: "rw", pluginID: "custom.rw"))
        XCTAssertEqual(features, [.clipboard])
        XCTAssertEqual(keywords.map(\.keyword), ["rw"])
        XCTAssertEqual(keywords.map(\.pluginID), ["custom.rw"])
        XCTAssertNil(keywords.first?.binding)
        XCTAssertTrue(failures.isEmpty)
    }

    func testDefaultHandlersDoNothing() async {
        executor.handlers = RingActionExecutor.Handlers()
        await run(.feature(.notes))
        await run(.keyword(keyword: "rw", pluginID: "p"))
        XCTAssertTrue(failures.isEmpty)
    }

    func testOpensAppsAndReportsMissingOnes() async {
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        environment.applications["com.apple.Notes"] = notes
        await run(.app(bundleIdentifier: "com.apple.Notes", name: "Notes"))
        await run(.app(bundleIdentifier: "com.example.gone", name: "Gone"))
        XCTAssertEqual(environment.openedApplications, [notes])
        XCTAssertEqual(failures, [L("ring.error.appMissing", "Gone")])
    }

    func testSendsKeysToThePreviousApp() async {
        let binding = HotkeyBinding(keyCode: 21, modifierFlags: RingActionExecutor.flags([.command, .shift]))
        await executor.perform(RingAction(kind: .keys(binding), title: "t", symbol: "s"),
                               previousApplication: NSRunningApplication.current)
        XCTAssertEqual(environment.activated, [NSRunningApplication.current])
        XCTAssertEqual(environment.keyStrokes.map(\.0), [21])
        XCTAssertEqual(environment.keyStrokes.map(\.1), [binding.modifierFlags])
    }

    func testSystemActions() async {
        await run(.system(.darkMode))
        await run(.system(.mute))
        await run(.system(.missionControl))
        await run(.system(.lockScreen))
        await run(.system(.emoji))
        await run(.system(.keepAwake))
        await run(.system(.keepAwake))
        XCTAssertEqual(environment.scripts.count, 2)
        XCTAssertTrue(environment.scripts[0].contains("dark mode"))
        XCTAssertTrue(environment.scripts[1].contains("output muted"))
        XCTAssertEqual(environment.openedApplications, [RingActionExecutor.missionControlURL])
        XCTAssertEqual(environment.keyStrokes.map(\.0), [12, 49])
        XCTAssertTrue(environment.keyStrokes.allSatisfy { $0.1 == RingActionExecutor.flags([.control, .command]) })
        XCTAssertEqual(environment.keepAwake, [true, false])
        XCTAssertFalse(executor.keepAwake)
        XCTAssertTrue(failures.isEmpty)
    }

    func testScriptFailuresExplainAutomation() async {
        environment.scriptsSucceed = false
        await run(.system(.darkMode))
        await run(.system(.mute))
        XCTAssertEqual(failures, [L("ring.error.automation"), L("ring.error.automation")])
    }

    func testShortcutsURLsAndFolders() async {
        let downloads = RingSettingsPresentation.expandedFolderPath("~/Downloads")
        environment.directories = [downloads]
        await run(.shortcut(name: "Pomodoro"))
        await run(.url("https://typeflux.app"))
        await run(.url("file:///etc/hosts"))
        await run(.folder(path: "~/Downloads"))
        await run(.folder(path: "/nowhere"))
        XCTAssertEqual(environment.processes, [[RingActionExecutor.shortcutsExecutable, "run", "Pomodoro"]])
        XCTAssertEqual(environment.opened, [URL(string: "https://typeflux.app")!,
                                            URL(fileURLWithPath: downloads, isDirectory: true)])
        XCTAssertEqual(failures, [L("ring.error.invalidURL"), L("ring.error.folderMissing", "/nowhere")])
    }

    func testEventFlagsMapEveryModifier() {
        let flags = LiveRingSystemEnvironment.eventFlags(RingActionExecutor.flags([.command, .option, .control,
                                                                                  .shift, .function]))
        XCTAssertEqual(flags, [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
        XCTAssertEqual(LiveRingSystemEnvironment.eventFlags(0), [])
    }

    func testLiveEnvironmentHarmlessQueries() {
        let live = LiveRingSystemEnvironment()
        XCTAssertTrue(live.directoryExists(atPath: NSTemporaryDirectory()))
        XCTAssertFalse(live.directoryExists(atPath: "/definitely/not/here"))
        XCTAssertNil(live.applicationURL(bundleIdentifier: "com.example.not-installed.\(UUID().uuidString)"))
        XCTAssertFalse(live.setKeepAwake(false))
        live.activate(nil)
        live.activate(NSRunningApplication.current)
        live.runProcess("/usr/bin/true", arguments: [])
        live.runProcess("/definitely/not/here", arguments: [])
        XCTAssertTrue(live.runAppleScript("return 1"))
        XCTAssertFalse(live.runAppleScript("this is not applescript ((("))
    }
}
