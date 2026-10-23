import Foundation

/// The event tap must keep draining while AppKit lays out a merged UI window.
/// A run-loop source sleeps in the kernel; it does not poll while idle.
final class HotkeyInputRunLoop: @unchecked Sendable {
    static let shared = HotkeyInputRunLoop()
    let value: CFRunLoop

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let storage = RunLoopStorage()
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()!
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(loop, keepAlive, .commonModes)
            storage.value = loop
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Typeflux global input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        value = storage.value!
    }

    private final class RunLoopStorage: @unchecked Sendable { var value: CFRunLoop? }
}

final class HotkeyRecordingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
