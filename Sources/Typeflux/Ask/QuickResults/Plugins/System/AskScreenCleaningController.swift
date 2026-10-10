import AppKit

/// A temporary black cover with an event tap; Escape and a deadline always release it.
@MainActor
final class AskScreenCleaningController {
    static let shared = AskScreenCleaningController()
    private var windows: [NSWindow] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var deadline: Task<Void, Never>?

    func show() throws {
        close()
        guard AXIsProcessTrusted() else {
            throw AskPluginFailure(message: L("ask.system.clean.permission"), retry: false)
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
                                              if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                                                  Task { @MainActor in AskScreenCleaningController.shared.close() }
                                                  return Unmanaged.passUnretained(event)
                                              }
                                              if type == .keyDown,
                                                 event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                                                  Task { @MainActor in AskScreenCleaningController.shared.close() }
                                              }
                                              return nil
                                          }, userInfo: nil) else {
            throw AskPluginFailure(message: L("ask.system.clean.permission"), retry: false)
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: L("ask.system.clean.hint"))
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 20, y: screen.frame.height / 2, width: screen.frame.width - 40, height: 50)
            window.contentView?.addSubview(label)
            window.orderFrontRegardless()
            windows.append(window)
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.close()
        }
    }

    func close() {
        deadline?.cancel()
        deadline = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        windows.forEach { $0.close() }
        windows = []
    }
}
