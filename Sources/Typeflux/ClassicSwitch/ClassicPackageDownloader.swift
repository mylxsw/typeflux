import Foundation

protocol ClassicPackageDownloading: Sendable {
    /// Downloads to a file owned by the caller. `progress` receives a fraction, or nil while the
    /// size is unknown. Cancelling the calling task cancels the transfer.
    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
}

enum ClassicPackageDownloadError: LocalizedError, Equatable {
    case httpStatus(Int)

    var errorDescription: String? { L("updater.download.failed") }
}

struct URLSessionClassicPackageDownloader: ClassicPackageDownloading {
    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let operation = ClassicDownloadOperation(progress: progress)
        return try await withTaskCancellationHandler {
            try await operation.start(url: url)
        } onCancel: {
            operation.cancel()
        }
    }
}

/// One transfer. URLSession retains its delegate until `finishTasksAndInvalidate` completes.
private final class ClassicDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var downloadedFile: URL?
    private var failure: Error?
    private var cancelled = false

    init(progress: @escaping @Sendable (Double?) -> Void) {
        self.progress = progress
    }

    func start(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            let alreadyCancelled = lock.withLock {
                self.continuation = continuation
                self.session = session
                self.task = task
                return cancelled
            }
            if alreadyCancelled {
                finish(.failure(CancellationError()))
                session.invalidateAndCancel()
                return
            }
            progress(nil)
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            progress(nil)
            return
        }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns; keep it before completion.
        if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            lock.withLock { failure = ClassicPackageDownloadError.httpStatus(http.statusCode) }
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-classic-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { downloadedFile = destination }
        } catch {
            lock.withLock { failure = error }
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let (file, storedFailure, wasCancelled) = lock.withLock { (downloadedFile, failure, cancelled) }
        if wasCancelled || (error as? URLError)?.code == .cancelled {
            if let file { try? FileManager.default.removeItem(at: file) }
            finish(.failure(CancellationError()))
        } else if let error = error ?? storedFailure {
            if let file { try? FileManager.default.removeItem(at: file) }
            finish(.failure(error))
        } else if let file {
            finish(.success(file))
        } else {
            finish(.failure(ClassicPackageDownloadError.httpStatus(0)))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
