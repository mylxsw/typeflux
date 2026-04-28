import Darwin
import Foundation
import Typeflux

@main
struct TypefluxCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "batch-wav" else {
            TypefluxApplication.run()
            return
        }

        arguments.removeFirst()
        let exitCode = await TypefluxBatchCommand.run(arguments: arguments)
        exit(Int32(exitCode))
    }
}
