import Foundation

/// A serial session streams bytes to a private persistent prefix. A new instance can resume it.
final class SemanticModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let identity: SemanticDownloadState.Identity
    private let configuration: URLSessionConfiguration
    private let directory: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    // Accessed only by the serial delegate queue after start.
    private var storage: SemanticDownloadState?
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var responseEnd: Int64 = 0
    private var cancelled = false
    private var started = false

    init(url: URL = SemanticModel.url, bytes: Int64 = SemanticModel.bytes, sha256: String = SemanticModel.sha256,
         directory: URL = SemanticModel.directory.appendingPathComponent("Downloads", isDirectory: true),
         configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (Int64) -> Void) {
        identity = .init(url: url, bytes: bytes, sha256: sha256)
        self.directory = directory; self.configuration = configuration; self.progress = progress
    }

    func fetch() async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled, !started else {
                    let error: Error = cancelled ? CancellationError() : URLError(.unknown)
                    lock.unlock(); continuation.resume(throwing: error); return
                }
                started = true
                do {
                    let state = try SemanticDownloadState(root: directory, identity: identity)
                    storage = state
                    if state.received == identity.bytes {
                        self.continuation = continuation
                        lock.unlock()
                        DispatchQueue.global(qos: .utility).async {
                            self.response = HTTPURLResponse(url: self.identity.url, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)
                            self.responseEnd = self.identity.bytes
                            self.finish(error: nil)
                        }
                        return
                    }
                    var request = URLRequest(url: identity.url)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if state.received > 0, let etag = state.etag {
                        request.setValue("bytes=\(state.received)-", forHTTPHeaderField: "Range")
                        request.setValue(etag, forHTTPHeaderField: "If-Range")
                    }
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    queue.qualityOfService = .utility
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    let task = session.dataTask(with: request)
                    self.continuation = continuation; self.session = session; self.task = task
                    lock.unlock()
                    task.resume()
                } catch {
                    storage = nil
                    lock.unlock(); continuation.resume(throwing: error)
                }
            }
        } onCancel: { self.cancel() }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard !isCancelled else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse, let state = storage,
                  http.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true else {
                throw URLError(.badServerResponse)
            }
            let etag = http.value(forHTTPHeaderField: "ETag")
            if http.statusCode == 200 {
                // If-Range mismatch or ignored Range: replace the prefix, never append.
                try state.reset(etag: etag.flatMap { $0.hasPrefix("\"") && $0.hasSuffix("\"") ? $0 : nil })
                guard http.expectedContentLength < 0 || http.expectedContentLength == identity.bytes else {
                    throw URLError(.badServerResponse)
                }
                responseEnd = identity.bytes
            } else if http.statusCode == 206 {
                guard state.received > 0, let previous = state.etag, etag == previous,
                      let range = http.value(forHTTPHeaderField: "Content-Range"),
                      let end = Self.rangeEnd(range, start: state.received, total: identity.bytes),
                      http.expectedContentLength < 0 || http.expectedContentLength == end - state.received else {
                    try state.reset(etag: nil)
                    throw URLError(.badServerResponse)
                }
                responseEnd = end
            } else { throw URLError(.badServerResponse) }
            self.response = http
            progress(state.received)
            completionHandler(.allow)
        } catch {
            failure = error; completionHandler(.cancel)
        }
    }

    /// End is exclusive. A bounded 206 is retained as partial, never published as complete.
    static func rangeEnd(_ value: String, start: Int64, total: Int64) -> Int64? {
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Int64(parts[1]) == total else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, Int64(bounds[0]) == start, let end = Int64(bounds[1]),
              end >= start, end < total else { return nil }
        return end + 1
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard !isCancelled else { throw CancellationError() }
            guard failure == nil, response != nil, let state = storage else { return }
            guard Int64(data.count) <= responseEnd - state.received else {
                try state.reset(etag: nil); throw URLError(.badServerResponse)
            }
            try state.append(data)
            progress(state.received)
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        finish(error: error)
    }

    private func finish(error: Error?) {
        var result: Result<(URL, URLResponse), Error>
        do {
            guard !isCancelled else { throw CancellationError() }
            if let failure = failure ?? error { throw failure }
            guard let state = storage, let response, state.received == responseEnd,
                  state.received == identity.bytes else { throw URLError(.networkConnectionLost) }
            let file = try state.complete(cancelled: { self.isCancelled })
            if !isCancelled { progress(state.received) }
            result = .success((file, response))
        } catch { result = .failure(error) }
        let completion = lock.withLock {
            if cancelled {
                if case let .success((url, _)) = result { try? FileManager.default.removeItem(at: url) }
                result = .failure(CancellationError())
            }
            let completion = continuation
            continuation = nil; task = nil; session = nil
            return completion
        }
        // Release the exclusive directory before a resumed caller starts another attempt.
        storage = nil
        completion?.resume(with: result)
    }
}
