import AppKit
import Testing
@testable import Typeflux

@Suite("Desktop identity evidence", .exclusiveUIState)
@MainActor
struct AskComputerTargetProbeTests {
    @Test func `window focus element replacement geometry and process generation change evidence`() throws {
        let probe = AskComputerTargetProbe()
        let app = try #require(NSWorkspace.shared.runningApplications.first { $0.processIdentifier > 0 })
        var launch = Date(timeIntervalSince1970: 1)
        var window = AXUIElementCreateApplication(100), control = AXUIElementCreateApplication(101),
            element = AXUIElementCreateApplication(102)
        var frame = CGRect(x: 0, y: 0, width: 500, height: 500), layout = "display:1000x1000", value = "first"
        probe.accessibilityTrusted = { true }; probe.processStarted = { _ in launch }
        probe.frontmostPID = { app.processIdentifier }
        probe.focusedWindow = { _ in window }; probe.windowFrame = { _ in frame }
        probe.focusedElement = { _ in control }
        probe.snapshot = { _, identify in .init(
            role: "AXWindow",
            name: "Fixture",
            value: value,
            frame: frame,
            identity: identify(element)
        ) }
        probe.displayForWindow = { _ in (1, CGRect(x: 0, y: 0, width: 1000, height: 1000)) }; probe
            .topology = { layout }
        let first = try probe.target(app: app)
        #expect(try probe.target(app: app).reference.target == first.reference.target)
        #expect(first.reference.pid == Int(app.processIdentifier)); #expect(first.reference.displayId == "1")
        for change in [
            { launch = Date(timeIntervalSince1970: 2) }, { window = AXUIElementCreateApplication(200) },
            { control = AXUIElementCreateApplication(201) }, { element = AXUIElementCreateApplication(202) },
            { frame.origin.x += 0.00001 }, { layout = "display:2000x2000" }, { value = "second" }
        ] {
            let before = try probe.target(app: app).reference.target
            change()
            #expect(try probe.target(app: app).reference.target != before)
        }
        let current = try probe.environment(app: app).target()
        #expect(current.reference.target != first.reference.target)
        probe.frontmostPID = { -1 }
        #expect(throws: AskObservationError.needsObservation) { try probe.target(app: app) }
        probe.frontmostPID = { app.processIdentifier }
        probe.focusedElement = { _ in nil }
        #expect(throws: AskObservationError.needsObservation) { try probe.target(app: app) }
        probe.focusedElement = { _ in control }; probe.snapshot = { _, _ in nil }
        #expect(throws: AskObservationError.needsObservation) { try probe.target(app: app) }
        probe.snapshot = { _, _ in .init(role: "AXWindow", name: "", value: "", frame: frame) }
        probe.displayForWindow = { _ in nil }
        #expect(throws: AskObservationError.needsObservation) { try probe.target(app: app) }
        probe.displayForWindow = { _ in (1, .zero) }
        #expect(throws: AskObservationError.needsObservation) { try probe.target(app: app) }
        probe.processStarted = { _ in nil }
        #expect(throws: AskObservationError.needsObservation) { try probe.target(app: app) }
        #expect(AskComputerTargetProbe.focusedElement(-1) == nil)
        #expect(AskComputerTargetProbe.displayForWindow(CGDisplayBounds(CGMainDisplayID())) != nil)
        #expect(AskComputerTargetProbe.displayForWindow(CGRect(x: -1e10, y: -1e10, width: 1, height: 1)) == nil)
    }
}
