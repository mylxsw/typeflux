import Darwin
import Foundation
import Typeflux

@main
struct TypefluxCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "file-index-worker":
            exit(AskFileWorkerCommand.run())
        #if DEBUG
        case "audio-capture-check":
            arguments.removeFirst()
            let exitCode = await AudioCaptureCheckCommand.run(arguments: arguments)
            exit(Int32(exitCode))
        #endif
        case "batch-wav":
            arguments.removeFirst()
            let exitCode = await TypefluxBatchCommand.run(arguments: arguments)
            exit(Int32(exitCode))
        case "process-audio":
            arguments.removeFirst()
            let exitCode = await TypefluxAudioProcessCommand.run(arguments: arguments)
            exit(Int32(exitCode))
        default:
            TypefluxApplication.run()
        }
    }
}
