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

            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = ProcessCommandResult(
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
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
                continuation.resume(throwing: error)
            }
        }
    }
}
