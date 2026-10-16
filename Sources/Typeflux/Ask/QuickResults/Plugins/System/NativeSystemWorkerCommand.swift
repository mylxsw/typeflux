import Foundation

/// Early CLI dispatch: never initializes application DI, windows or hotkeys.
public enum NativeSystemWorkerCommand {
    static func handleInvocation(arguments: [String]) -> Int32? {
        guard arguments.first == "native-system-worker" else { return nil }
        return run(arguments: Array(arguments.dropFirst()))
    }

    public static func run(arguments: [String]) -> Int32 {
        run(arguments: arguments, input: .standardInput, output: .standardOutput, adapter: .init())
    }

    static func run(arguments: [String], input: FileHandle, output: FileHandle,
                    adapter: NativeSystemAdapter) -> Int32 {
        guard arguments.isEmpty else { return 2 }
        do {
            var data = Data()
            while let chunk = try input.read(upToCount: NativeSystemProtocol.maximumBytes + 1 - data.count),
                  !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= NativeSystemProtocol.maximumBytes else { return 2 }
            }
            let request = try NativeSystemProtocol.decodeRequest(data)
            let response = NativeSystemResponse(requestID: request.requestID, operation: request.operation,
                                                outcome: adapter.execute(request.operation))
            try output.write(contentsOf: JSONEncoder().encode(response))
            return 0
        } catch { return 2 }
    }
}
