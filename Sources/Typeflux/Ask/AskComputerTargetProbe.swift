import AppKit

/// OS evidence is local to this executor. No model-provided PID, window ID or
/// display ID is accepted as authority, and capture never follows the pointer.
@MainActor
final class AskComputerTargetProbe {
    private var windows: [pid_t: (AXUIElement, String)] = [:]
    private var controls: [pid_t: (AXUIElement, String)] = [:]
    private var elements: [pid_t: [CFHashCode: [(AXUIElement, String)]]] = [:]
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var processStarted: (NSRunningApplication) -> Date? = { $0.isTerminated ? nil : $0.launchDate }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var focusedWindow: (pid_t) -> AXUIElement? = AskLocalTools.focusedWindow
    var windowFrame: (AXUIElement) -> CGRect? = AskLocalTools.windowFrame
    var focusedElement: (pid_t) -> AXUIElement? = AskComputerTargetProbe.focusedElement
    var snapshot: (pid_t, (AXUIElement) -> String?) -> AskDesktopActions.Node? = { AskDesktopActions.snapshot(
        pid: $0,
        identify: $1
    ) }
    var displayForWindow: (CGRect) -> (CGDirectDisplayID, CGRect)? = AskComputerTargetProbe.displayForWindow
    var topology: () throws -> String = AskComputerTargetProbe.displayTopology

    func environment(app: NSRunningApplication?) -> AskComputerExecutor.Environment {
        .init(target: { try self.target(app: app) }, activate: {
            guard AXIsProcessTrusted(), let app, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.activate(options: [.activateIgnoringOtherApps])
            else { throw AskObservationError.needsObservation }
        }, isActive: { app?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier })
    }

    func target(app: NSRunningApplication?) throws -> AskComputerExecutor.Target {
        guard accessibilityTrusted() else { throw AskLocalError.message(L("ask.tool.accessibility")) }
        guard let app, app.processIdentifier > 0, let launch = processStarted(app),
              let window = focusedWindow(app.processIdentifier),
              let frame = windowFrame(window) else { throw AskObservationError.needsObservation }
        let foreground = frontmostPID()
        guard foreground == app.processIdentifier || foreground == ProcessInfo.processInfo.processIdentifier
        else { throw AskObservationError.needsObservation }
        let pid = app.processIdentifier
        let previous = elements[pid] ?? [:]
        var observed: [CFHashCode: [(AXUIElement, String)]] = [:]
        guard let root = snapshot(pid, { element in
            let hash = CFHash(element)
            let token = previous[hash]?.first(where: { CFEqual($0.0, element) })?.1 ?? UUID().uuidString
            observed[hash, default: []].append((element, token))
            return token
        }) else { throw AskObservationError.needsObservation }
        elements[pid] = observed
        if windows[pid].map({ CFEqual($0.0, window) }) != true {
            windows[pid] = (window, UUID().uuidString)
        }
        guard let control = focusedElement(pid) else { throw AskObservationError.needsObservation }
        if controls[pid].map({ CFEqual($0.0, control) }) != true {
            controls[pid] = (control, UUID().uuidString)
        }
        guard let (display, bounds) = displayForWindow(frame) else { throw AskObservationError.needsObservation }
        guard bounds.width > 1, bounds.height > 1 else { throw AskObservationError.needsObservation }
        let topology = try topology()
        let process = "\(pid):\(launch.timeIntervalSince1970)", windowID = windows[pid]!.1
        let identity = AskToolPolicy
            .digest("\(process):\(windowID):\(controls[pid]!.1):\(frame):\(display):\(topology)")
        let target = AskExecutionTarget(kind: "desktop_window", id: "\(pid):\(windowID)",
                                        version: AskToolPolicy.digest(identity + ":" + Self.fingerprint(root)))
        return .init(reference: .init(id: "", target: target, capturedAt: Date(), appId: app.bundleIdentifier,
                                      processInstanceId: process, pid: Int(pid), windowId: windowID,
                                      displayId: String(display)),
                     display: display, bounds: bounds, window: frame,
                     description: AskDesktopActions.describe(root, display: bounds), dispatchIdentity: identity)
    }

    static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        // CF type identity was checked above; a conditional Swift cast is not supported for AXUIElement.
        // swiftlint:disable:next force_cast
        return (focused as! AXUIElement)
    }

    static func displayForWindow(_ frame: CGRect) -> (CGDirectDisplayID, CGRect)? {
        var display: CGDirectDisplayID = 0, count: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count) == .success,
              count == 1, CGDisplayIsActive(display) != 0 else { return nil }
        return (display, CGDisplayBounds(display))
    }

    static func fingerprint(_ node: AskDesktopActions.Node) -> String {
        // Length-prefix text to avoid delimiter ambiguity. Preserve full geometry,
        // unlike the rounded coordinates in the model-facing description.
        let fields = [node.role, node.name, node.value, String(describing: node.frame), node.identity ?? ""]
        return fields.map { "\($0.utf8.count):\($0)" }.joined() + "[" + node.children.map(fingerprint).joined() + "]"
    }

    static func displayTopology() throws -> String {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displays, &count) == .success, count > 0,
              count < 32 else { throw AskObservationError.needsObservation }
        return displays.prefix(Int(count)).sorted().map {
            "\($0):\(CGDisplayBounds($0)):\(CGDisplayPixelsWide($0))x\(CGDisplayPixelsHigh($0)):\(CGDisplayRotation($0))"
        }.joined(separator: ";")
    }
}
