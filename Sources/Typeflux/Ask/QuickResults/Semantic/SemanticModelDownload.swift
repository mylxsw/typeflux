import Foundation

/// A session-owned download delegate delivers incremental progress on macOS.
/// The temporary file must be moved before the delegate callback returns.
final class SemanticModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloaded: URL?
    private var copyError: Error?
    private var cancelled = false
    private var started = false

    private struct Completion {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>?
        let file: URL?
        let error: Error?
        let session: URLSession?
    }

    init(url: URL = SemanticModel.url, configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.configuration = configuration; self.progress = progress
    }

    func fetch() async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                guard !self.cancelled else {
                    self.lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                guard !self.started else {
                    self.lock.unlock(); continuation.resume(throwing: URLError(.unknown)); return
                }
                self.started = true
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: self.url)
                self.session = session; self.task = task
                self.lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        let task = self.lock.withLock { self.cancelled = true; return self.task }
        task?.cancel()
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        self.progress(totalBytesWritten)
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantic-model-\(UUID().uuidString).partial")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            self.lock.withLock { self.downloaded = target }
        } catch { self.lock.withLock { self.copyError = error } }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = self.lock.withLock {
            let failure: Error? = self.cancelled ? CancellationError() : (self.copyError ?? error)
            let result = Completion(continuation: continuation, file: downloaded, error: failure, session: session)
            continuation = nil; self.downloaded = nil; self.session = nil; self.task = nil
            return result
        }
        state.session?.finishTasksAndInvalidate()
        guard let continuation = state.continuation else { return }
        if let error = state.error {
            if let file = state.file {
                try? FileManager.default.removeItem(at: file)
            }
            continuation.resume(throwing: error)
        } else if let file = state.file, let response = task.response {
            continuation.resume(returning: (file, response))
        } else {
            if let file = state.file {
                try? FileManager.default.removeItem(at: file)
            }
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
