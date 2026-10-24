import Darwin
import Foundation

protocol AskFileReading: AnyObject {
    func stop()
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse
    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws
}

extension AskFileReading {
    func stop() {}
    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        _ = try receive(read(request, isCancelled: isCancelled))
    }

    func resolve(_ path: String, blocked: [String]) throws -> String {
        try read(AskFileReadRequest(operation: .resolve, path: path, blocked: blocked), isCancelled: { false })
            .path ?? path
    }
}

enum AskFileReadError: Error { case timeout, cancelled, unavailable, nonLocalMount, protocolError }

/// Serial, reusable child with deadline-bound pipe I/O. A hung syscall is confined to the child.
final class AskFileReader: AskFileReading {
    private let executable: URL?
    private let arguments: [String]
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    private let qualityOfService: QualityOfService?
    private var process: AskFileReaderProcess?
    private let ownership: AskFileReaderOwnership
    private let reaper: OwnedProcessReaper
    private let inventory: AskDirectoryInventory?
    private var streaming = false
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    init(executable: URL? = nil, arguments: [String] = ["file-index-worker"],
         timeout: TimeInterval = 5, startupTimeout: TimeInterval? = nil, qualityOfService: QualityOfService? = nil,
         ownership: AskFileReaderOwnership = AskFileReaderOwnership(), reaper: OwnedProcessReaper = .shared,
         inventory: AskDirectoryInventory? = .shared) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.startupTimeout = startupTimeout ?? (executable == nil ? max(30, timeout) : timeout)
        self.qualityOfService = qualityOfService
        self.ownership = ownership; self.reaper = reaper
        self.inventory = inventory
    }

    deinit { stop() }

    /// Read on the reader's serial owner, like stream() and stop().
    var isRunning: Bool {
        process?.isRunning == true
    }

    static var executableURL: URL {
        let bundle = Bundle(for: AskFileWorkerBundle.self)
        // Test code is loaded into xctest (argv[0] is the runner on newer toolchains).
        if bundle.bundleURL.pathExtension == "xctest" {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Typeflux")
        }
        return bundle.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool = { false }) throws -> AskFileReadResponse {
        var result = AskFileReadResponse()
        try stream(request, isCancelled: isCancelled) { response in
            result.entries += response.entries
            result.path = response.path ?? result.path
            result.text = response.text ?? result.text
            result.pages = response.pages ?? result.pages
            result.version = response.version ?? result.version
            result.nextCursor = response.nextCursor
            result.directoryCursor = response.directoryCursor
            result.inspected = response.inspected
            result.embeddings = response.embeddings ?? result.embeddings
            result.semanticTiming = response.semanticTiming ?? result.semanticTiming
            result.truncated = response.truncated ?? result.truncated
            result.fileSize = response.fileSize ?? result.fileSize
            result.modified = response.modified ?? result.modified
            result.imageWidth = response.imageWidth ?? result.imageWidth
            result.imageHeight = response.imageHeight ?? result.imageHeight
            result.error = response.error ?? result.error
            result.skippedMounts = (result.skippedMounts ?? []) + (response.skippedMounts ?? [])
            return true
        }
        return result
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool = { false },
                receive: (AskFileReadResponse) -> Bool) throws {
        guard request.operation == .directory, let scope = request.scope, let inventory else {
            return try transfer(request, isCancelled: isCancelled, receive: receive)
        }
        // Content discovery only consumes names/kinds; file modification times are validated separately.
        // Filename rebuilds always read fresh attributes, even when directory membership is unchanged.
        if request.directoryCursor != nil, let listing = inventory.listing(path: request.path, scope: scope) {
            var version: String?
            try transfer(.init(operation: .directoryVersion, path: request.path, scope: scope),
                         isCancelled: isCancelled) { response in version = response.version ?? version; return true }
            if version == listing.version {
                guard ownership.permitsWork, !isCancelled() else { throw AskFileReadError.cancelled }
                if try serve(listing, request: request, scope: scope, isCancelled: isCancelled, receive: receive) { return }
            } else { inventory.invalidate(path: request.path, id: listing.id) }
        }
        var entries: [AskFileCrawler.Entry] = [], skippedMounts: [String] = []
        var reusable = request.directoryCursor == nil
        try transfer(request, isCancelled: isCancelled) { response in
            if reusable {
                entries += response.entries
                skippedMounts += response.skippedMounts ?? []
                if entries.count > 8192 { reusable = false; entries.removeAll() }
            }
            let keep = receive(response)
            if keep, reusable, response.more != true, response.error == nil, let version = response.version,
               !isCancelled(), ownership.permitsWork {
                inventory.store(path: request.path, listing: .init(scope: scope, version: version, entries: entries,
                                                                  skippedMounts: skippedMounts))
            }
            return keep
        }
    }

    private func serve(_ listing: AskDirectoryInventory.Listing, request: AskFileReadRequest, scope: AskFileScope,
                       isCancelled: () -> Bool, receive: (AskFileReadResponse) -> Bool) throws -> Bool {
        let cursor = request.directoryCursor
        if let cursor, !cursor.session.isEmpty,
           cursor.session != listing.id || cursor.version != listing.version { return false }
        let start = cursor.map { $0.session.isEmpty ? 0 : Int(clamping: $0.inspected) } ?? 0
        guard start >= 0, start <= listing.entries.count else { return false }
        guard !streaming, let process else { throw AskFileReadError.unavailable }
        try ownership.begin(process.id)
        streaming = true
        defer { ownership.end(process.id); streaming = false }
        guard ownership.permitsWork, !isCancelled() else { throw AskFileReadError.cancelled }
        try SemanticWorkBudget.current?.checkpoint(cancelled: isCancelled)
        let end = min(listing.entries.count, start + 128)
        let entries = listing.entries[start ..< end].filter { scope.includes($0.path, isDirectory: $0.kind != .file) }
        let next = end < listing.entries.count ? AskDirectoryCursor(session: listing.id, version: listing.version,
                                                                    inspected: Int64(end)) : nil
        let mounts = start == 0 ? listing.skippedMounts.filter { scope.includes($0, isDirectory: true) } : []
        _ = receive(AskFileReadResponse(entries: Array(entries), skippedMounts: mounts, version: listing.version, directoryCursor: next,
                                        inspected: end - start))
        guard self.process === process, ownership.permits(process.id), !isCancelled() else {
            throw AskFileReadError.cancelled
        }
        return true
    }

    // Each frame/pipe transfer resets the idle deadline; a large advancing directory has no total deadline.
    // Keep resource ownership, cancellation and state checks in one operation.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func transfer(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                          receive: (AskFileReadResponse) -> Bool) throws {
        guard !streaming else { throw AskFileReadError.unavailable }
        guard ownership.permitsWork else { throw AskFileReadError.unavailable }
        streaming = true
        var activity: UUID?
        var launched = false
        func cancelled() -> Bool { isCancelled() || !ownership.permitsWork || (activity.map { !ownership.permits($0) } ?? false) }
        defer { if let activity { ownership.end(activity) }; streaming = false }
        do {
            try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
            if cancelled() { throw AskFileReadError.cancelled }
            let starting = process == nil
            if starting {
                SemanticSearchTrace.current?.mark("helper-launch")
                try start(isCancelled: cancelled)
            }
            guard let input, let output, let process else { throw AskFileReadError.unavailable }
            try ownership.begin(process.id); activity = process.id; launched = true
            var deadline = ProcessInfo.processInfo.systemUptime + (starting ? startupTimeout : timeout)
            let data = try JSONEncoder().encode(request) + Data([10])
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(
                        input.fileDescriptor,
                        events: Int16(POLLOUT),
                        deadline: &deadline,
                        isCancelled: cancelled
                    )
                    let count = Darwin.write(
                        input.fileDescriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EAGAIN || errno == EINTR {
                        continue
                    }
                    guard count > 0 else { throw AskFileReadError.unavailable }
                    offset += count
                }
            }
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]
                    let response = try JSONDecoder().decode(AskFileReadResponse.self, from: line)
                    buffer.removeSubrange(...end)
                    if cancelled() { throw AskFileReadError.cancelled }
                    let keepReading = receive(response)
                    guard self.process === process, !cancelled() else { throw AskFileReadError.cancelled }
                    if !keepReading { stop(); return }
                    if response.more != true { ownership.succeeded(); return }
                    deadline = ProcessInfo.processInfo.systemUptime + timeout
                    if request.paced == true {
                        let next = Data("continue\n".utf8)
                        try next.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                try wait(
                                    input.fileDescriptor,
                                    events: Int16(POLLOUT),
                                    deadline: &deadline,
                                    isCancelled: cancelled
                                )
                                let count = Darwin.write(
                                    input.fileDescriptor,
                                    bytes.baseAddress!.advanced(by: offset),
                                    bytes.count - offset
                                )
                                if count < 0, errno == EAGAIN || errno == EINTR {
                                    continue
                                }
                                guard count > 0 else { throw AskFileReadError.unavailable }
                                offset += count
                            }
                        }
                    }
                    continue
                }
                try wait(output.fileDescriptor, events: Int16(POLLIN), deadline: &deadline, isCancelled: cancelled)
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EAGAIN || errno == EINTR {
                    continue
                }
                guard count > 0 else { throw AskFileReadError.unavailable }
                deadline = ProcessInfo.processInfo.systemUptime + timeout
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 8 * 1024 * 1024 else { throw AskFileReadError.protocolError }
            }
        } catch {
            let ns = error as NSError
            if !cancelled() {
                if ns.domain == NSPOSIXErrorDomain && [EACCES, EPERM, ENOENT, ENOEXEC].contains(Int32(ns.code)) {
                    ownership.failed(configuration: true)
                } else if launched, !(error is CancellationError), !(error is SemanticWorkBudget.Interrupted), (error as? AskFileReadError) != .cancelled {
                    ownership.failed(configuration: false)
                }
            }
            stop()
            throw error
        }
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: inout TimeInterval,
                      isCancelled: () -> Bool) throws {
        while true {
            deadline += try SemanticWorkBudget.current?.checkpoint(child: process, cancelled: isCancelled) ?? 0
            if isCancelled() {
                throw AskFileReadError.cancelled
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw AskFileReadError.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(
                &item,
                1,
                Int32(min(SemanticWorkBudget.current == nil ? 50 : 10, max(1, remaining * 1000)))
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result >= 0 else { throw AskFileReadError.unavailable }
            if item.revents & events != 0 {
                return
            }
            if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw AskFileReadError.unavailable
            }
        }
    }

    private func start(isCancelled: () -> Bool) throws {
        let incoming = Pipe(), outgoing = Pipe()
        let process = try AskFileReaderProcess(executable: executable ?? Self.executableURL, arguments: arguments,
            input: incoming.fileHandleForReading.fileDescriptor, output: outgoing.fileHandleForWriting.fileDescriptor,
            qualityOfService: qualityOfService, ownership: ownership, reaper: reaper, isCancelled: isCancelled)
        self.process = process
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        try? incoming.fileHandleForReading.close()
        try? outgoing.fileHandleForWriting.close()
        for handle in [input, output].compactMap(\.self) {
            _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
    }

    func stop() {
        // Collection is asynchronous; the lineage stays occupied through host completion.
        process?.stop()
        process = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        buffer.removeAll(keepingCapacity: false)
    }
}

private final class AskFileWorkerBundle {}
