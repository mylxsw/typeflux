import Foundation

/// A host-created capability, never decoded from model arguments or history.
/// WebKit has no HTTP access. Only explicit GET resources pass through this
/// bounded proxy to the live lease's exact origin, without redirects or cookies.
@MainActor final class AskDevelopmentPreview {
    let lease: AskProjectRuntimeLease
    let scope: AskProjectScope
    let address: URL
    let entry: String
    let paths: Set<String>
    private let runtime: AskProjectRuntime
    private let session: URLSession
    private let redirects = AskPreviewRedirectPolicy()
    private var observer: UUID?
    private var usedBytes = 0
    private var requests = 0
    private var closed = false
    private let maximumFileBytes: Int
    var invalidated: () -> Void = {}

    init(runtime: AskProjectRuntime, lease: AskProjectRuntimeLease, scope: AskProjectScope,
         entry: String, paths: [String], maximumFileBytes: Int = AskArtifactStore.maximumFileBytes) throws {
        guard !paths.isEmpty, paths.count <= AskArtifactStore.maximumFiles,
              Set(paths).count == paths.count, paths.contains(entry),
              AskArtifactStore.mediaType(entry) == "text/html",
              (1 ... AskArtifactStore.maximumFileBytes).contains(maximumFileBytes),
              let address = try runtime.serviceAddress(lease, scope: scope) else {
            throw AskArtifactError.dynamicUnavailable
        }
        for path in paths {
            try AskArtifactStore.validatePath(path)
        }
        self.runtime = runtime; self.lease = lease; self.scope = scope
        self.address = address; self.entry = entry; self.paths = Set(paths)
        self.maximumFileBytes = maximumFileBytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        observer = try runtime.observeInvalidation(lease, scope: scope) { [weak self] in
            self?.close(); self?.invalidated()
        }
    }

    func validate(process: AskProcessRef? = nil, address: URL? = nil) throws {
        guard !closed, process.map({ $0 == lease.reference }) ?? true,
              address.map({ $0 == self.address }) ?? true,
              try runtime.serviceAddress(lease, scope: scope) == self.address else {
            throw AskArtifactError.denied
        }
    }

    func load(_ path: String) async throws -> Data {
        try validate()
        guard paths.contains(path), requests < 256 else { throw AskArtifactError.denied }
        try AskArtifactStore.validatePath(path)
        requests += 1
        let url = address.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url, response.expectedContentLength <= Int64(maximumFileBytes) else {
            throw AskArtifactError.unavailable
        }
        var data = Data()
        // Check the accumulated byte count, not only an untrusted Content-Length.
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumFileBytes,
                      usedBytes < AskArtifactStore.maximumBundleBytes else { throw AskArtifactError.tooLarge }
                data.append(byte); usedBytes += 1
            }
            try validate()
            return data
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    func close() {
        closed = true
        if let observer {
            runtime.removeObserver(observer); self.observer = nil
        }
        session.invalidateAndCancel()
    }

    deinit { session.invalidateAndCancel() }
}

private final class AskPreviewRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask,
                    willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
