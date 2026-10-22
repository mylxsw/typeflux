import Foundation
import Darwin
import TypefluxChatWindowProtocol
import TypefluxChatWindowRuntime

@main
enum TypefluxChatWindowHelper {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var offscreen = false, stall: TimeInterval = 0
        if arguments != ["--ipc-fd", "100"] {
            #if DEBUG
            guard arguments.count == 4, Array(arguments.prefix(3)) == ["--ipc-fd", "100", "--probe"],
                  let seconds = TimeInterval(arguments[3]), seconds.isFinite, (0 ... 30).contains(seconds) else { exit(64) }
            offscreen = true; stall = seconds
            #else
            exit(64)
            #endif
        }
        guard let socket = try? ChatWindowSocket(owning: 100) else { exit(70) }
        ChatWindowApplication.run(socket: socket, offscreen: offscreen, stallAfterPresent: stall)
    }
}
