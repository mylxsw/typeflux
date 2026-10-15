import Foundation
import Darwin
import TypefluxMediaRuntime

@main
enum TypefluxMediaHelper {
    static func main() {
        // One disposable process, one request. No app DI, model or microphone.
        // The parent normally enforces 30 seconds. Bound orphaned native work too.
        alarm(35)
        MediaHelperCommand.run()
    }
}
