import AppKit
import Carbon
@testable import Typeflux
import XCTest

/// Opt-in: creates and closes ONLY a new fixture window in each real browser.
/// It never changes TCC or the browser's "JavaScript from Apple Events" setting.
@MainActor
final class AskAutomationAcceptanceTests: XCTestCase {
    func testNativePermissionEvidence() throws {
        print(
            "P09 permissions: accessibility=\(AXIsProcessTrusted()), screen_capture=\(CGPreflightScreenCaptureAccess())"
        )
        if !AXIsProcessTrusted() {
            XCTAssertThrowsError(try AskComputerTargetProbe().target(app: NSRunningApplication.current))
        }
        for bundle in ["com.apple.Safari", "com.google.Chrome"] {
            let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundle)
            let status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, typeWildCard, typeWildCard, false)
            print("P09 automation preflight: \(bundle)=\(status)")
        }
    }

    func testRealSafariFixture() async throws {
        try await exercise("com.apple.Safari")
    }

    func testRealChromeFixture() async throws {
        try await exercise("com.google.Chrome")
    }

    func testRealDesktopDragCancellationAndWindowMovement() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_AUTOMATION_ACCEPTANCE"] == "1" else {
            throw XCTSkip(
                "Real desktop acceptance requires TYPEFLUX_AUTOMATION_ACCEPTANCE=1 and Accessibility permission."
            )
        }
        guard AXIsProcessTrusted() else {
            XCTFail("Accessibility permission denied; controlled desktop allowed-path acceptance NOT executed.")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ObservationDesktop"),
            log = directory.appendingPathComponent("events")
        let source = AskBrowserDOMTests.fixture.deletingLastPathComponent()
            .appendingPathComponent("ObservationDesktop.swift")
        _ = try await ProcessCommandRunner().run(
            executablePath: "/usr/bin/xcrun",
            arguments: ["swiftc", source.path, "-o", executable.path]
        )
        let process = Process()
        process.executableURL = executable; process.arguments = [log.path]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }; process.waitUntilExit()
        }
        let probe = AskComputerTargetProbe()
        var application: NSRunningApplication?
        for _ in 0 ..< 40 {
            application = NSRunningApplication(processIdentifier: process.processIdentifier)
            if (try? probe.target(app: application)) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let app = try XCTUnwrap(application), target = try probe.target(app: app)
        let executor = AskComputerExecutor(store: .init()); executor.writesEnabled = true
        let scope = AskObservationStore.Scope(owner: "acceptance", conversation: UUID().uuidString, tool: "computer")
        var environment = probe.environment(app: app)
        func observe() async throws -> String {
            let result = try await executor.execute(["action": "inspect"], scope: scope, environment: environment)
            let json = try XCTUnwrap(try JSONSerialization
                .jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            return try XCTUnwrap((json["observation"] as? [String: Any])?["id"] as? String)
        }
        let id = try await observe()
        let x = (target.window.midX - target.bounds.minX) / (target.bounds.width - 1)
        let y = (target.window.midY - target.bounds.minY) / (target.bounds.height - 1)
        var operation: Task<AskLocalToolOutput, Error>!
        let post = environment.post
        environment.post = {
            event in post(event); if event.type == .leftMouseDragged {
                operation.cancel()
            }
        }
        operation = Task { try await executor.execute(
            ["action": "drag", "observation_id": id, "x": x, "y": y, "to_x": x + 0.02, "to_y": y + 0.02],
            scope: scope,
            environment: environment
        ) }
        let result = try await operation.value
        XCTAssertTrue(result.isError)
        var events = ""
        for _ in 0 ..< 20 {
            events = (try? String(contentsOf: log)) ?? ""
            if events.contains("up") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(events.contains("down")); XCTAssertTrue(events.contains("up"))
        environment.post = post
        let fresh = try await observe()
        let window = try XCTUnwrap(AskLocalTools.focusedWindow(app.processIdentifier))
        var moved = CGPoint(x: target.window.minX + 30, y: target.window.minY + 30)
        XCTAssertEqual(
            try AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, XCTUnwrap(AXValueCreate(
                .cgPoint,
                &moved
            ))),
            .success
        )
        do {
            _ = try await executor.execute(
                ["action": "click", "observation_id": fresh, "x": x, "y": y],
                scope: scope,
                environment: environment
            )
            XCTFail("Moved window must reject stale coordinates")
        } catch { XCTAssertEqual(error as? AskObservationError, .needsObservation) }
    }

    private func exercise(_ bundle: String) async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_AUTOMATION_ACCEPTANCE"] == "1" else {
            throw XCTSkip(
                "Real browser acceptance requires TYPEFLUX_AUTOMATION_ACCEPTANCE=1 and an interactive macOS permission grant."
            )
        }
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundle)
        let status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, typeWildCard, typeWildCard, false)
        guard status == noErr else {
            XCTFail("\(bundle) Automation permission unavailable (\(status)); allowed-path acceptance NOT executed.")
            return
        }
        let runner = AskAutomationScriptRunner()
        func run(_ script: String) async throws -> String {
            try await runner.run(executablePath: "/usr/bin/osascript", arguments: ["-e", script]).stdout
        }
        let safari = bundle == "com.apple.Safari"
        let url = AskBrowserDOMTests.fixture.absoluteString
        let literal = AskLocalTools.appleScriptLiteral
        let create = safari ? "make new document with properties {URL:\(literal(url))}"
            : "set fixtureWindow to make new window\nset URL of active tab of fixtureWindow to \(literal(url))"
        let window =
            try await run("tell application id \(literal(bundle))\n\(create)\nreturn id of front window\nend tell")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(window) != nil else { XCTFail("Missing fixture window ID"); return }
        let cleanup = "tell application id \(literal(bundle)) to close window id \(window)"
        do {
            let executor = AskBrowserExecutor(store: .init(), runner: runner)
            executor.writesEnabled = true
            let scope = AskObservationStore.Scope(owner: "acceptance", conversation: UUID().uuidString, tool: "browser")
            // Bounded fixture load; never read a pre-existing tab's content.
            var loaded = false
            for _ in 0 ..< 20 {
                let probe = try await executor.target(bundle: bundle)
                if probe.reference.windowId == window, probe.stamp.contains(url) {
                    loaded = true; break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(loaded)
            guard loaded else { throw AskObservationError.needsObservation }
            func observed() async throws -> String {
                let current = try await executor.target(bundle: bundle)
                guard current.reference.windowId == window,
                      current.stamp.contains(url) else { throw AskObservationError.needsObservation }
                let output = try await executor.execute(["action": "snapshot"], bundle: bundle, scope: scope)
                let json = try JSONSerialization.jsonObject(with: Data(output.content.utf8)) as! [String: Any]
                return (json["observation"] as! [String: Any])["id"] as! String
            }
            for selector in ["#text", "#area", "#editable"] {
                let id = try await observed()
                let result = try await executor.execute(
                    ["action": "fill", "selector": selector, "text": "controlled input", "observation_id": id],
                    bundle: bundle,
                    scope: scope
                )
                XCTAssertFalse(result.isError); XCTAssertTrue(result.content.contains("\"effect_verified\":true"))
            }
            let id = try await observed()
            let missing = try await executor.execute(
                ["action": "click", "selector": "#missing", "observation_id": id],
                bundle: bundle,
                scope: scope
            )
            XCTAssertTrue(missing.isError); XCTAssertTrue(missing.content.contains("Element not found"))
            let staleID = try await observed()
            let current = try await executor.target(bundle: bundle)
            _ = try await run(AskBrowserExecutor.appleScript(bundle: bundle, expected: current.stamp,
                                                             javascript: "(()=>{document.querySelector('#text').outerHTML=document.querySelector('#text').outerHTML;return 'redrawn'})()"))
            let stale = try await executor.execute(
                ["action": "click", "selector": "#click", "observation_id": staleID],
                bundle: bundle,
                scope: scope
            )
            XCTAssertTrue(stale.isError); XCTAssertTrue(stale.content.contains("needs-observation"))
            _ = try await run(cleanup)
        } catch {
            _ = try? await run(cleanup)
            throw error
        }
    }
}
