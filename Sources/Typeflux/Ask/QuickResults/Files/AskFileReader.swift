import Darwin
import Foundation

protocol AskFileReading: AnyObject {
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse
}

extension AskFileReading {
    func resolve(_ path: String, blocked: [String]) throws -> String {
        try read(AskFileReadRequest(operation: .resolve, path: path, blocked: blocked), isCancelled: { false }).path ?? path
    }
}

enum AskFileReadError: Error { case timeout, cancelled, unavailable, exhausted, protocolError }

/// Serial, reusable child with deadline-bound pipe I/O. A hung syscall is confined to the child.
final class AskFileReader: AskFileReading {
    private let executable: URL?
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumFailures: Int
    private var failures = 0
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    init(executable: URL? = nil, arguments: [String] = ["file-index-worker"],
         timeout: TimeInterval = 5, maximumFailures: Int = 3) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.maximumFailures = maximumFailures
    }

    deinit { stop() }

    static var executableURL: URL {
        let bundle = Bundle(for: AskFileWorkerBundle.self)
        // Test code is loaded into xctest (argv[0] is the runner on newer toolchains).
        if bundle.bundleURL.pathExtension == "xctest" {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Typeflux")
        }
        return bundle.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool = { false }) throws -> AskFileReadResponse {
        guard failures < maximumFailures else { throw AskFileReadError.exhausted }
        do {
            if isCancelled() { throw AskFileReadError.cancelled }
            if process == nil { try start() }
            guard let input, let output else { throw AskFileReadError.unavailable }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let data = try JSONEncoder().encode(request) + Data([10])
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(input.fileDescriptor, events: Int16(POLLOUT), deadline: deadline, isCancelled: isCancelled)
                    let count = Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EAGAIN || errno == EINTR { continue }
                    guard count > 0 else { throw AskFileReadError.unavailable }
                    offset += count
                }
            }
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]
                    let response = try JSONDecoder().decode(AskFileReadResponse.self, from: line)
                    buffer.removeSubrange(...end)
                    return response
                }
                try wait(output.fileDescriptor, events: Int16(POLLIN), deadline: deadline, isCancelled: isCancelled)
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EAGAIN || errno == EINTR { continue }
                guard count > 0 else { throw AskFileReadError.unavailable }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 128 * 1024 * 1024 else { throw AskFileReadError.protocolError }
            }
        } catch {
            failures += 1
            stop()
            throw error
        }
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval, isCancelled: () -> Bool) throws {
        while true {
            if isCancelled() { throw AskFileReadError.cancelled }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw AskFileReadError.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(50, max(1, remaining * 1000))))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw AskFileReadError.unavailable }
            if item.revents & events != 0 { return }
            if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw AskFileReadError.unavailable }
        }
    }

    private func start() throws {
        let process = Process()
        let incoming = Pipe(), outgoing = Pipe()
        process.executableURL = executable ?? Self.executableURL
        process.arguments = arguments
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        try? incoming.fileHandleForReading.close()
        try? outgoing.fileHandleForWriting.close()
        for handle in [input, output].compactMap({ $0 }) {
            _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
    }

    func stop() {
        // Process owns reaping. Never waitUntilExit here: an uninterruptible kernel read may outlive SIGKILL.
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        buffer.removeAll(keepingCapacity: false)
    }
}

private final class AskFileWorkerBundle {}
