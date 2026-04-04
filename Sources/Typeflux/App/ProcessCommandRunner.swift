import Foundation

struct ProcessCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol ProcessCommandRunning {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectoryURL: URL?
    ) async throws -> ProcessCommandResult
}

extension ProcessCommandRunning {
    func run(executablePath: String, arguments: [String]) async throws -> ProcessCommandResult {
        try await run(
            executablePath: executablePath,
            arguments: arguments,
            environment: nil,
            currentDirectoryURL: nil
        )
    }
}

final class ProcessCommandRunner: ProcessCommandRunning {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) async throws -> ProcessCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            if let environment {
                var mergedEnvironment = ProcessInfo.processInfo.environment
                environment.forEach { key, value in mergedEnvironment[key] = value }
                process.environment = mergedEnvironment
            }
            if let currentDirectoryURL {
                process.currentDirectoryURL = currentDirectoryURL
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Accumulate pipe output concurrently to prevent the child process from
            // blocking when its output exceeds the kernel pipe buffer (~64 KB).
            // Reading only in terminationHandler would deadlock: the process blocks
            // writing to a full pipe and never terminates, so the handler never fires.
            var stdoutData = Data()
            var stderrData = Data()
            let collectionLock = NSLock()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                collectionLock.lock()
                stdoutData.append(chunk)
                collectionLock.unlock()
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                collectionLock.lock()
                stderrData.append(chunk)
                collectionLock.unlock()
            }

            process.terminationHandler = { process in
                // Stop handlers and drain any bytes buffered after the last readability event.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                collectionLock.lock()
                stdoutData.append(remainingStdout)
                stderrData.append(remainingStderr)
                let finalStdout = stdoutData
                let finalStderr = stderrData
                collectionLock.unlock()

                let result = ProcessCommandResult(
                    stdout: String(decoding: finalStdout, as: UTF8.self),
                    stderr: String(decoding: finalStderr, as: UTF8.self),
                    exitCode: process.terminationStatus
                )

                if process.terminationStatus == 0 {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ProcessCommandRunner",
                            code: Int(process.terminationStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey: result.stderr.isEmpty ? result.stdout : result.stderr
                            ]
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
