import Foundation
import Darwin
import TypefluxMediaRuntime
import TypefluxMediaProtocol

@main
enum TypefluxMediaHelper {
    static func main() async {
        if CommandLine.arguments.count == 4, ["--audio-playback", "--video-playback", "--recording-playback"].contains(CommandLine.arguments[1]),
           CommandLine.arguments[2] == "100", let container = MediaAVContainer(rawValue: CommandLine.arguments[3]) {
            // Persistent file playback uses a private inherited socket, not stdout/stdin.
            alarm(12)
            if let socket = try? MediaPlaybackSocket(owning: 100) {
                let server = MediaPlaybackServer(engine: MediaAVPlaybackEngine(video: CommandLine.arguments[1] != "--audio-playback", recording: CommandLine.arguments[1] == "--recording-playback"), watchdog: { _ = alarm(12) })
                await server.serve(socket: socket, input: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("audio." + container.rawValue))
            }
            return
        }
        if CommandLine.arguments == [CommandLine.arguments[0], "--recording-export"] {
            alarm(605)
            await MediaRecordingExportDecoder.run()
            return
        }
        // One disposable process, one request. No app DI, model or microphone.
        // The parent normally enforces 30 seconds. Bound orphaned native work too.
        alarm(35)
        await MediaHelperCommand.runAsync()
    }
}
