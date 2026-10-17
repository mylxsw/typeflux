import CryptoKit
import Foundation
import Testing
@testable import Typeflux

/// Every test owns and joins its loopback server; no process or network fixture escapes the test.
@Suite(.serialized)
struct SemanticDownloadResumeTests {
    final class Server {
        let root: URL
        let process = Process()
        let log: FileHandle
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-http-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let output = root.appendingPathComponent("server.log")
            _ = FileManager.default.createFile(atPath: output.path, contents: nil)
            log = try FileHandle(forWritingTo: output)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [repo.appendingPathComponent("scripts/fixtures/semantic_download_http.py").path, root.path]
            process.standardOutput = log; process.standardError = log
            try process.run()
        }
        deinit {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? log.close()
            try? FileManager.default.removeItem(at: root)
        }
        func url(_ mode: String) async throws -> URL {
            let port = root.appendingPathComponent("port")
            for _ in 0..<200 {
                if let value = try? String(contentsOf: port, encoding: .utf8), let number = Int(value) {
                    return URL(string: "http://127.0.0.1:\(number)/\(mode)")!
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw URLError(.cannotConnectToHost)
        }
        func requests() throws -> [[String: Any]] {
            try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        func evidence(_ name: String, result: [String: Any]) throws {
            guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_EVIDENCE"] else { return }
            let output = URL(fileURLWithPath: path)
            try FileManager.default.copyItem(at: root.appendingPathComponent("requests.jsonl"),
                                            to: output.appendingPathComponent(name + "-requests.jsonl"))
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(name + "-result.json"))
        }
    }
    static var payload: Data { Data((0..<1024).flatMap { _ in (0...255).map(UInt8.init) }) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func download(_ url: URL, root: URL, data: Data = Self.payload,
                  progress: @escaping @Sendable (Int64) -> Void = { _ in }) -> SemanticModelDownload {
        .init(url: url, bytes: Int64(data.count), sha256: Self.hash(data), directory: root, progress: progress)
    }
    func state(_ url: URL, root: URL, data: Data = Self.payload) throws -> SemanticDownloadState {
        try .init(root: root, identity: .init(url: url, bytes: Int64(data.count), sha256: Self.hash(data)))
    }

    @Test func realHTTPInterruptionResumesAcrossNewInstancesAndInstallsVerifiedBytes() async throws {
        let server = try Server(), url = try await server.url("resume")
        let root = server.root.appendingPathComponent("downloads")
        await #expect(throws: (any Error).self) { try await download(url, root: root).fetch() }
        var saved: [String: Any] = [:]
        do {
            let partial = try state(url, root: root)
            #expect(partial.received == 65536 && partial.etag == "\"v1\"")
            #expect(try Data(contentsOf: partial.directory.url.appendingPathComponent("payload")) == Self.payload.prefix(65536))
            saved = ["prefix_bytes": partial.received, "etag": partial.etag!, "metadata_exists": true]
        }
        let progress = Progress()
        let (file, response) = try await download(url, root: root, progress: { progress.add($0) }).fetch()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(try Data(contentsOf: file) == Self.payload)
        #expect(progress.values.first == 65536 && progress.values.last == Int64(Self.payload.count))
        #expect(progress.values == progress.values.sorted())
        let installed = server.root.appendingPathComponent("installed.gguf")
        try SemanticModel.install(file, to: installed, bytes: Int64(Self.payload.count),
                                  sha256: Self.hash(Self.payload), cancelled: { false })
        let requests = try server.requests()
        #expect(requests.count == 2)
        #expect(requests[1]["range"] as? String == "bytes=65536-")
        #expect(requests[1]["if_range"] as? String == "\"v1\"")
        saved["installed_sha256"] = Self.hash(try Data(contentsOf: installed))
        saved["expected_sha256"] = Self.hash(Self.payload)
        saved["resumed_progress"] = progress.values
        saved["metadata_removed"] = !FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("metadata.json").path)
        try server.evidence("resume", result: saved)
    }

    @Test(arguments: ["ignore", "change"])
    func ignoredRangeOrChangedResourceReplacesPrefix(_ mode: String) async throws {
        let server = try Server(), url = try await server.url(mode)
        let root = server.root.appendingPathComponent("downloads")
        let expected = mode == "change" ? Data(Self.payload.reversed()) : Self.payload
        await #expect(throws: (any Error).self) { try await download(url, root: root, data: expected).fetch() }
        let progress = Progress()
        let (file, response) = try await download(url, root: root, data: expected, progress: { progress.add($0) }).fetch()
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(progress.values.first == 0)
        let requests = try server.requests()
        #expect(requests.count == 2)
        #expect(requests[1]["range"] as? String == "bytes=65536-")
        #expect(requests[1]["if_range"] as? String == "\"v1\"")
        #expect(try Data(contentsOf: file) == expected)
        try server.evidence(mode, result: ["sha256": Self.hash(try Data(contentsOf: file)), "progress": progress.values])
    }

    @Test(arguments: ["wrong", "etag206", "truncated", "hash"])
    func invalidOrIncompleteResponsesNeverPublishAndRetryIsBounded(_ mode: String) async throws {
        let server = try Server(), url = try await server.url(mode)
        let root = server.root.appendingPathComponent("downloads")
        await #expect(throws: (any Error).self) { try await download(url, root: root).fetch() }
        if mode != "hash" {
            await #expect(throws: (any Error).self) { try await download(url, root: root).fetch() }
        }
        let requests = try server.requests()
        #expect(requests.count == (mode == "hash" ? 1 : 2))
        let partial = try state(url, root: root)
        if mode != "truncated" { #expect(partial.received == 0) }
        #expect(partial.directory.entries().allSatisfy { !$0.hasSuffix(".verified") })
        try server.evidence(mode, result: ["requests": requests.count, "remaining_bytes": partial.received, "published": false])
    }

    @Test func cancellationKeepsOnlyPrefixAndConcurrentInstanceCannotWrite() async throws {
        let server = try Server(), url = try await server.url("slow")
        let root = server.root.appendingPathComponent("downloads"), progress = Progress()
        let task = Task { try await download(url, root: root, progress: { progress.add($0) }).fetch() }
        for _ in 0..<200 {
            if progress.values.last ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(progress.values.last ?? 0 > 0)
        await #expect(throws: (any Error).self) { try await download(url, root: root).fetch() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        do {
            let partial = try state(url, root: root)
            #expect(partial.received > 0 && partial.received < Int64(Self.payload.count))
            #expect(!partial.directory.entries().contains { $0.hasSuffix(".verified") })
        }
        let (file, _) = try await download(url, root: root).fetch()
        #expect(try Data(contentsOf: file) == Self.payload)
        #expect(try server.requests().count == 2)
    }

    @Test func identityIsolationFullCheckpointAndSymlinks() async throws {
        let server = try Server(), url = try await server.url("resume")
        let root = server.root.appendingPathComponent("downloads")
        var modelDirectory: URL!
        do {
            let checkpoint = try state(url, root: root)
            try checkpoint.reset(etag: "\"v1\"")
            try checkpoint.append(Self.payload)
            modelDirectory = try checkpoint.directory.url
        }
        let different = Data(Self.payload.reversed())
        do {
            let other = try state(url, root: root, data: different)
            let otherDirectory = try other.directory.url
            #expect(other.received == 0 && otherDirectory != modelDirectory)
        }
        let (file, _) = try await download(url, root: root).fetch()
        #expect(try Data(contentsOf: file) == Self.payload)
        #expect(!FileManager.default.fileExists(atPath: server.root.appendingPathComponent("requests.jsonl").path))
        let external = server.root.appendingPathComponent("external")
        try Data("untouched".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: modelDirectory.appendingPathComponent("payload"), withDestinationURL: external)
        await #expect(throws: (any Error).self) { try await download(url, root: root).fetch() }
        #expect(try String(contentsOf: external, encoding: .utf8) == "untouched")
        try FileManager.default.removeItem(at: modelDirectory.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(at: modelDirectory.appendingPathComponent("metadata.json"), withDestinationURL: external)
        await #expect(throws: (any Error).self) { try await download(url, root: root).fetch() }
        #expect(try String(contentsOf: external, encoding: .utf8) == "untouched")
    }

    @Test func productionTextAndProjectorFetchUseSeparatePinnedIdentities() async throws {
        let server = try Server()
        let config = URLSessionConfiguration.ephemeral
        // The protocol refuses the pinned production URLs without touching external HTTP.
        config.protocolClasses = [PinnedFailureProtocol.self]
        let text = SemanticModelFiles(directory: server.root, configuration: config)
        let media = SemanticMediaModelFiles(directory: server.root, configuration: config)
        await #expect(throws: (any Error).self) { try await text.fetch { _ in } }
        await #expect(throws: (any Error).self) { try await media.fetch { _ in } }
        let actual = try AskSecureDirectory.openRoot(server.root)
        let identities: [[String: Any]] = actual.entries().compactMap { name in
            guard let folder = try? actual.child(name),
                  let data = try? folder.readFile("metadata.json", limit: 16 * 1024),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return record["identity"] as? [String: Any]
        }
        #expect(identities.count == 2)
        #expect(identities.contains { ($0["url"] as? String) == SemanticModel.url.absoluteString
            && ($0["bytes"] as? Int64) == SemanticModel.bytes && ($0["sha256"] as? String) == SemanticModel.sha256 })
        #expect(identities.contains { ($0["url"] as? String) == SemanticMediaModel.url.absoluteString
            && ($0["bytes"] as? Int64) == SemanticMediaModel.bytes
            && ($0["sha256"] as? String) == SemanticMediaModel.sha256 })
        do {
            let textState = try SemanticDownloadState(root: server.root, identity: .init(
                url: SemanticModel.url, bytes: SemanticModel.bytes, sha256: SemanticModel.sha256))
            let mediaState = try SemanticDownloadState(root: server.root, identity: .init(
                url: SemanticMediaModel.url, bytes: SemanticMediaModel.bytes, sha256: SemanticMediaModel.sha256))
            let textDirectory = try textState.directory.url, mediaDirectory = try mediaState.directory.url
            #expect(textDirectory != mediaDirectory)
            #expect(textState.received == 0 && mediaState.received == 0)
        }
        let cancelled = Task { try await media.fetch { _ in } }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    final class PinnedFailureProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    @Test func invalidRangesAreRejected() {
        for value in ["bytes 9-19/20", "bytes 10-20/20", "bytes 10-19/21", "bytes */20", "bytes 10-9/20", "bytes 10-19", "items 10-19/20"] {
            #expect(SemanticModelDownload.rangeEnd(value, start: 10, total: 20) == nil)
        }
        #expect(SemanticModelDownload.rangeEnd("bytes 10-19/20", start: 10, total: 20) == 20)
    }

    final class Progress: @unchecked Sendable {
        let lock = NSLock()
        private var stored: [Int64] = []
        var values: [Int64] { lock.withLock { stored } }
        func add(_ value: Int64) { lock.withLock { stored.append(value) } }
    }
}
