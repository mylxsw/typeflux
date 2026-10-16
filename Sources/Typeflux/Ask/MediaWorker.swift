import Darwin
import Foundation
import TypefluxMediaProtocol

/// A bounded, independent fault domain for disposable media decoders.
final class MediaWorker: @unchecked Sendable {
    static let shared = MediaWorker(requiresLifecycle: true)
    static let recordingExport = MediaWorker(timeout: 600)
    static let recordingTimeline = MediaWorker(timeout: 30)
    static let previews = MediaWorker(timeout: 3, requiresLifecycle: true)
    static let clipboardThumbnails = MediaWorker(timeout: 3)
    static let frameRegistration = MediaWorker(timeout: 3)
    static let textRecognition = MediaWorker(timeout: 30)
    static let clipboardOCR = MediaWorker(timeout: 30)
    static let clipboardMetadata = MediaWorker(timeout: 10)
    enum Input { case file(URL), data(Data) }
    typealias Runner = @Sendable (ManagedProcess.Request, @escaping @Sendable () -> Bool) throws -> ManagedProcess.Result
    private let lock = NSLock()
    private var active: [UUID: MediaLease] = [:]
    private var disabled = false
    private let requiresLifecycle: Bool
    private var lifecycle: MediaExtractionGate?
    private var retirement: CheckedContinuation<Void, Never>?
    private var budget = ModuleRecoveryBudget()
    private let executable: URL
    private let timeout: TimeInterval
    private let run: Runner
    private let uptime: @Sendable () -> TimeInterval

    init(executable: URL = MediaWorker.helperURL, timeout: TimeInterval = 30, requiresLifecycle: Bool = false,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         run: @escaping Runner = { try ManagedProcess().runBlocking($0, isCancelled: $1) }) {
        self.requiresLifecycle = requiresLifecycle
        self.executable = executable; self.timeout = timeout; self.uptime = uptime; self.run = run
    }

    static var helperURL: URL {
        helperURL(appExecutable: AskFileReader.executableURL)
    }

    static func helperURL(appExecutable binary: URL) -> URL {
        let directory = binary.deletingLastPathComponent()
        return (directory.lastPathComponent == "MacOS" && directory.deletingLastPathComponent().lastPathComponent == "Contents"
                ? directory.deletingLastPathComponent().appendingPathComponent("Helpers") : directory)
            .appendingPathComponent("TypefluxMediaHelper")
    }

    /// Synchronous only on an owned background task.
    func decode(_ operation: MediaRequest.Operation, input: Input,
                isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> MediaResponse {
        try perform(operation, input: input, isCancelled: isCancelled) { response, _ in response }
    }

    /// Result extraction finishes before the private directory can be retired.
    func perform<T>(_ operation: MediaRequest.Operation, input: Input, preview: MediaPreviewOptions? = nil, normalization: MediaImageType? = nil, icon: MediaNativeIcon? = nil, quickLook: MediaQuickLook? = nil, clipboard: MediaClipboardOptions? = nil, textInput: MediaTextInput? = nil, registration: MediaRegistrationInput? = nil, retaining: AnyObject? = nil,
                    isCancelled: @escaping @Sendable () -> Bool,
                    extract: (MediaResponse, Int32) throws -> T) throws -> T {
        var request = MediaRequest(operation: operation)
        request.preview = preview
        request.normalization = normalization
        request.icon = icon
        request.quickLook = quickLook
        request.clipboard = clipboard
        request.textInput = textInput
        request.registration = registration
        try request.validate()
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= (preview == nil ? MediaLimits.requestBytes : MediaPreviewOptions.requestBytes)
        else { throw MediaFailure.tooLarge }
        return try owned(id: request.id, retaining: retaining, isCancelled: isCancelled) { lease, executable, timeout, run, cancelled in
        let id = request.id
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-media-" + id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        lease.directory = directory
        try Self.copy(input, to: directory.appendingPathComponent("input"),
                 limit: operation == .recordingTimeline || operation == .recordingPosterVideo ? MediaRecordingTimeline.inputBytes : operation == .registerFrames ? MediaRegistrationInput.pairBytes : (operation == .recognizeText || operation == .textGeometry) ? (textInput == nil ? MediaOCRResult.inputBytes : MediaTextInput.rawBytes) : operation == .clipboardOCR ? MediaOCRResult.inputBytes : operation.isWorkflowImage ? MediaWorkflowImage.inputBytes : operation == .validateGeneratedImage ? 16 * 1024 * 1024 : operation == .normalizeImage ? 10 * 1024 * 1024 : (operation.isAV || (clipboard != nil && clipboard?.kind != .pdf) ? MediaAVLimits.inputBytes : MediaLimits.inputBytes), cancelled: cancelled)
        try check(cancelled)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MediaFailure.unavailable }
        defer { close(fd) }
        do {
            let process = ManagedProcess.Request(executable: executable.path, environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
                directoryDescriptor: fd, timeout: timeout, outputLimit: operation == .recordingTimeline ? 16 * 1024 : operation == .registerFrames ? 1024 : (operation == .textGeometry || operation == .recognizeText || operation == .clipboardOCR) ? MediaOCRResult.responseBytes : preview == nil && clipboard == nil && operation != .validateGeneratedImage && !operation.isWorkflowImage ? MediaLimits.responseBytes : 16 * 1024,
                stopOnOutputLimit: true, preserveWhitespace: true, onStarted: { lease.started() },
                stdin: encoded, stderrLimit: 1024,
                onReaped: { lease.reaped() })
            let result: ManagedProcess.Result
            do { result = try run(process, cancelled) }
            catch {
                lease.infrastructureFailed = true
                let code = error as NSError
                lease.configurationFailure = code.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(ENOENT), Int(ENOEXEC)].contains(code.code)
                throw error
            }
            try check(cancelled)
            guard result.termination == .exited(0), !result.outputTruncated,
                  result.stdout.utf8.count <= MediaLimits.responseBytes else { lease.infrastructureFailed = true; throw MediaFailure.unavailable }
            let response = try JSONDecoder().decode(MediaResponse.self, from: Data(result.stdout.utf8))
            try response.validate(for: request)
            try check(cancelled)
            let value = try extract(response, fd)
            try check(cancelled)
            return value
        } catch {
            if error is DecodingError || (error as? MediaFailure) == .invalidProtocol { lease.infrastructureFailed = true }
            throw error
        }
        }
    }

    /// The caller owns its directory policy; failed producers must retain their outputs.
    func owned<T>(id: UUID, retaining: AnyObject?, isCancelled: @escaping @Sendable () -> Bool,
                  body: (MediaLease, URL, TimeInterval, Runner, @escaping @Sendable () -> Bool) throws -> T) throws -> T {
        let lease = MediaLease()
        lease.retained = retaining
        let gate: MediaExtractionGate?, generation: UUID?
        (gate, generation) = try lock.withLock {
            guard !disabled, active.count < 2, active[id] == nil, !isCancelled() else { throw MediaFailure.unavailable }
            if requiresLifecycle && lifecycle == nil { throw MediaFailure.unavailable }
            let generation = try lifecycle?.admit()
            if lifecycle == nil, !budget.permitsAttempt(at: uptime()) { throw MediaFailure.unavailable }
            active[id] = lease
            return (lifecycle, generation)
        }
        gate?.changed()
        lease.cleanup = { [self] in
            let waiter = lock.withLock {
                active[id] = nil
                guard active.isEmpty else { return Optional<CheckedContinuation<Void, Never>>.none }
                let waiter = retirement; retirement = nil; return waiter
            }
            gate?.changed()
            waiter?.resume()
        }
        defer { lease.returned() }
        let cancelled: @Sendable () -> Bool = {
            lease.cancelled || isCancelled() || (gate != nil && !gate!.permits(generation))
        }
        do {
            try check(cancelled)
            let value = try body(lease, executable, timeout, run, cancelled)
            try check(cancelled)
            gate?.succeeded(generation)
            return value
        } catch {
            if !cancelled() {
                if let gate, lease.infrastructureFailed { gate.failed(generation, configuration: lease.configurationFailure) }
                else if gate == nil, (error as? MediaFailure) != .unreadable, (error as? MediaFailure) != .tooLarge {
                    lock.withLock { budget.failed(at: uptime()) }
                }
            }
            throw error
        }
    }

    /// Binding is one-time and precedes any work; factories reuse this pool,
    /// never replace it while cancelled host work or children remain owned.
    func bind(_ gate: MediaExtractionGate) -> Bool {
        lock.withLock {
            guard lifecycle == nil, active.isEmpty, !disabled else { return false }
            lifecycle = gate; return true
        }
    }

    func checkReadiness() throws {
        guard lock.withLock({ !disabled && active.isEmpty }), FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw ModuleFailure.unavailable }
    }

    func retireManaged() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                guard !active.isEmpty else { return true }
                // Exactly one supervisor cleanup owns this continuation. Its
                // cancellation never releases admission before actual collection.
                retirement = continuation
                active.values.forEach { $0.cancel() }
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func check(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }

    static func copy(_ input: Input, to target: URL, limit: Int, cancelled: () -> Bool) throws {
        switch input {
        case let .data(data):
            guard data.count <= limit else { throw MediaFailure.tooLarge }
            try data.write(to: target, options: .withoutOverwriting)
        case let .file(url):
            // Reject FIFOs/devices without blocking open, and bound reads even if
            // the original file grows after its metadata was checked.
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw MediaFailure.unreadable }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw MediaFailure.unreadable }
            guard info.st_size <= limit else { throw MediaFailure.tooLarge }
            let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw MediaFailure.unavailable }
            defer { close(output) }
            var buffer = [UInt8](repeating: 0, count: 65536), total = 0
            while true {
                if cancelled() { throw CancellationError() }
                let count = read(fd, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw MediaFailure.unreadable }
                total += count
                guard total <= limit else { throw MediaFailure.tooLarge }
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        if cancelled() { throw CancellationError() }
                        let written = write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw MediaFailure.unavailable }
                        offset += written
                    }
                }
            }
        }
    }

    func preventNewWork() {
        let leases = lock.withLock { disabled = true; lifecycle?.admission.shutdown(); return Array(active.values) }
        leases.forEach { $0.cancel() }
    }

    func shutdown() async {
        preventNewWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while activeCount > 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    var activeCount: Int { lock.withLock { active.count } }
}

/// Cleanup needs both host completion and actual child collection. The pool
/// retains this lease when a child cannot be collected within the stop budget.
final class MediaLease: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false, launched = false, collected = false, finished = false, cleaned = false
    // Written/read only by the owning synchronous host operation.
    var infrastructureFailed = false
    var configurationFailure = false
    var directory: URL?
    var retained: AnyObject?
    var cleanup: (@Sendable () -> Void)?
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
    func started() { lock.withLock { launched = true } }
    func reaped() { lock.withLock { collected = true }; collect(asynchronously: true) }
    func returned() { lock.withLock { finished = true }; collect(asynchronously: false) }
    private func collect(asynchronously: Bool) {
        let ready = lock.withLock {
            guard !cleaned, finished, !launched || collected else { return false }
            cleaned = true; return true
        }
        guard ready else { return }
        let remove: @Sendable () -> Void = { [self] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
            cleanup?()
            retained = nil
        }
        // A delayed reaper callback must not block collection of other children.
        if asynchronously { DispatchQueue.global(qos: .utility).async(execute: remove) }
        else { remove() }
    }
}
