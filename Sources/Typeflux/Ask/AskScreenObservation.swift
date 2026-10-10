import AppKit

/// Screenshot consent remains useful without AX access. This path never issues
/// a write observation, and a capture cannot silently substitute another screen.
@MainActor
final class AskScreenObservation {
    struct Target: Equatable {
        var display: CGDirectDisplayID
        var binding: AskExecutionTarget
    }

    var target: () throws -> Target = AskScreenObservation.currentTarget
    var capture: (CGDirectDisplayID) async throws -> AskContextCapture.Screenshot

    init(capturer: any ScreenCapturing = ScreenCaptureService(),
         permission: any ScreenCapturePermissionProviding = ScreenCapturePermission.live) {
        capture = { try await AskContextCapture.screenshot(displayId: $0, permission: permission, capturer: capturer) }
    }

    static func currentTarget() throws -> Target {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let display = number?.uint32Value,
              CGDisplayIsActive(display) != 0 else { throw AskObservationError.needsObservation }
        return .init(display: display, binding: .init(
            kind: "desktop_window", id: "display:\(display)",
            version: AskToolPolicy.digest(try AskComputerTargetProbe.displayTopology())
        ))
    }

    func execute(store: AskObservationStore, scope: AskObservationStore.Scope,
                 approved: AskExecutionTarget?, authorize: () throws -> Void) async throws -> AskLocalToolOutput {
        store.invalidate(scope: scope)
        let current = try target()
        guard approved == nil || approved == current.binding else { throw AskObservationError.needsObservation }
        try authorize()
        let shot = try await capture(current.display)
        try Task.checkCancellation()
        try authorize()
        guard shot.displayId == current.display, try target() == current
        else { throw AskObservationError.needsObservation }
        return AskActionReceipt.observed(
            "Current screen: \(shot.width) × \(shot.height). Read-only capture; no stable application/window " +
                "observation is available. Inspect the target again before requesting any input action.",
            reference: nil
        ).output(image: shot.dataURL)
    }
}
