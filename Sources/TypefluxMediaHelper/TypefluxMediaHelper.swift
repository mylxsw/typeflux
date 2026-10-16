import Foundation
import Darwin
import TypefluxMediaRuntime
import TypefluxMediaProtocol

@main
enum TypefluxMediaHelper {
    static func main() async {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--audio-playback",
           CommandLine.arguments[2] == "100", let container = MediaAVContainer(rawValue: CommandLine.arguments[3]) {
            // Persistent file playback uses a private inherited socket, not stdout/stdin.
            alarm(12)
            if let socket = try? MediaPlaybackSocket(owning: 100) {
                let server = MediaPlaybackServer(engine: MediaAVPlaybackEngine(), watchdog: { _ = alarm(12) })
                await server.serve(socket: socket, input: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("audio." + container.rawValue))
            }
            return
        }
        // One disposable process, one request. No app DI, model or microphone.
        // The parent normally enforces 30 seconds. Bound orphaned native work too.
        alarm(35)
        await MediaHelperCommand.runAsync()
    }
}
