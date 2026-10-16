import Darwin
import Foundation
import TypefluxInferenceProtocol
import TypefluxInferenceRuntime

@main
struct TypefluxInferenceHelper {
    static func main() async {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--ipc-fd", "100"],
              let socket = try? InferenceSocket(owning: 100) else { return }
        guard Bundle(url: Bundle.main.bundleURL.appendingPathComponent("swift-transformers_Hub.bundle")) != nil else {
            socket.stop()
            return
        }
        // Parent loss must retire even a wedged engine. This thread never consumes
        // messages and is independent of Swift's cooperative executor.
        DispatchQueue.global(qos: .utility).async {
            while !socket.isStopped {
                var item = pollfd(fd: socket.descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&item, 1, 250)
                guard !socket.isStopped else { return }
                var byte: UInt8 = 0
                let eof = item.revents & Int16(POLLIN) != 0
                    && recv(socket.descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
                if eof || item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { _exit(0) }
                if item.revents != 0 { usleep(10000) }
            }
        }
        await InferenceServer(engine: WhisperInferenceEngine()).serve(socket: socket)
    }
}
