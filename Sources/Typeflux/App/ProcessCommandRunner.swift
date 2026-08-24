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
    private let onProcessStarted: (@Sendable () -> Void)?

    init(onProcessStarted: (@Sendable () -> Void)? = nil) {
        self.onProcessStarted = onProcessStarted
    }

    private final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return snapshot
        }
    }

    private final class CancellationController: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func install(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func clear(_ process: Process) {
            lock.lock()
            if self.process === process {
                self.process = nil
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = process
            lock.unlock()

            if process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) async throws -> ProcessCommandResult {
        let cancellationController = CancellationController()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                cancellationController.install(process)

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
                let stdoutData = OutputBuffer()
                let stderrData = OutputBuffer()

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    stdoutData.append(chunk)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    stderrData.append(chunk)
                }

                process.terminationHandler = { process in
                    cancellationController.clear(process)
                    // Stop handlers and drain any bytes buffered after the last readability event.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stdoutData.append(remainingStdout)
                    stderrData.append(remainingStderr)
                    let finalStdout = stdoutData.snapshot()
                    let finalStderr = stderrData.snapshot()

                    let result = ProcessCommandResult(
                        stdout: String(decoding: finalStdout, as: UTF8.self),
                        stderr: String(decoding: finalStderr, as: UTF8.self),
                        exitCode: process.terminationStatus
                    )

                    if cancellationController.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus == 0 {
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

                guard !cancellationController.isCancelled else {
                    cancellationController.clear(process)
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    try process.run()
                    onProcessStarted?()
                    if cancellationController.isCancelled, process.isRunning {
                        process.terminate()
                    }
                } catch {
                    cancellationController.clear(process)
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellationController.cancel()
        }
    }
}
