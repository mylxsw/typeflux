import AppKit
import Darwin
import TypefluxChatWindowProtocol

public enum ChatWindowApplication {
    @MainActor
    public static func run(socket: ChatWindowSocket, offscreen: Bool = false, stallAfterPresent: TimeInterval = 0) {
        let app = NSApplication.shared
        let delegate = ChatWindowDelegate(socket: socket, offscreen: offscreen, stall: stallAfterPresent)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class ChatWindowDelegate: NSObject, NSApplicationDelegate {
    private let socket: ChatWindowSocket
    private let presentation: ChatWindowPresentation
    private let stall: TimeInterval
    init(socket: ChatWindowSocket, offscreen: Bool, stall: TimeInterval) {
        self.socket = socket; self.stall = stall
        presentation = ChatWindowPresentation(offscreen: offscreen)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let socket = socket, presentation = presentation, stall = stall
        let parent = getppid()
        guard parent > 1 else { exit(0) }
        // Parent loss must terminate even while the GUI thread is frozen. No
        // listener socket, credentials, autosaved transcript or app services.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { if getppid() != parent { exit(0) } }
        watchdog.resume()
        DispatchQueue(label: "typeflux.chat-window.connection", qos: .userInitiated).async {
            defer { watchdog.cancel(); socket.stop() }
            do {
                while !socket.isStopped {
                    let request = try socket.receive(deadline: .now.advanced(by: .seconds(90)))
                    let result = ChatWindowReplyBox()
                    DispatchQueue.main.async {
                        result.complete(Result { try presentation.receive(request) })
                    }
                    // Only this private connection thread waits. The parent and
                    // its main thread never synchronously wait for child UI.
                    let reply = try result.wait()
                    try socket.send(reply, deadline: .now.advanced(by: .seconds(5)))
                    if request.kind == .shutdown { exit(0) }
                    if request.kind == .present, stall > 0 {
                        DispatchQueue.main.async { Thread.sleep(forTimeInterval: stall) }
                    }
                }
            } catch { /* Invalid, disconnected or idle connections terminate. */ }
            exit(0)
        }
    }
}

private final class ChatWindowReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<ChatWindowEnvelope, Error>?
    func complete(_ value: Result<ChatWindowEnvelope, Error>) {
        lock.lock(); result = value; lock.unlock(); ready.signal()
    }
    func wait() throws -> ChatWindowEnvelope {
        guard ready.wait(timeout: .now() + 60) == .success else { throw ChatWindowFailure.timedOut }
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw ChatWindowFailure.unavailable }
        return try result.get()
    }
}
