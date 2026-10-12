import AppKit
import Darwin
import Testing
@testable import Typeflux

@MainActor
final class PreviewTestClock: AskFilePreviewClock {
    struct Event { var id: UUID; var time: Double; var action: @MainActor () -> Void }
    var now = 0.0
    var events: [Event] = []
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AskFilePreviewTimer {
        let id = UUID()
        events.append(Event(id: id, time: now + seconds, action: action))
        return AskFilePreviewTimer { [weak self] in self?.events.removeAll { $0.id == id } }
    }

    func advance(_ seconds: Double) {
        let end = now + seconds
        while let event = events.filter({ $0.time <= end + 0.0000001 }).min(by: { $0.time < $1.time }) {
            events.removeAll { $0.id == event.id }; now = event.time; event.action()
        }
        now = end
    }
}

@MainActor
final class PreviewTestLoader: AskFilePreviewLoading {
    var requests: [AskFileHit] = []
    var completions: [(AskFilePreviewContent?) -> Void] = []
    var cancelled = 0
    var prefetched: [AskFileHit] = []
    var visible: [Bool] = []
    func load(_ hit: AskFileHit, pixels _: CGSize, completion: @escaping (AskFilePreviewContent?) -> Void) {
        requests.append(hit); completions.append(completion)
    }

    func cancel() {
        cancelled += 1
    }

    func prefetch(_ hits: [AskFileHit], pixels _: CGSize) {
        prefetched = hits
    }

    func setVisible(_ value: Bool) {
        visible.append(value); if !value {
            cancel()
        }
    }
}

func previewHit(_ name: String = "hello.txt") -> AskFileHit {
    AskFileHit(path: "/Users/test/" + name, name: name, kind: .file, modified: Date(timeIntervalSince1970: 1), score: 1)
}

@Suite("File preview policy and text")
struct AskFilePreviewPolicyTests {
    @Test(arguments: [
        ("PNG", AskFilePreviewKind.image), ("heic", .image), ("pdf", .pdf), ("swift", .text),
        ("log", .text), ("md", .markdown), ("markdown", .markdown), ("csv", .table), ("tsv", .table),
        ("docx", .document), ("pages", .document), ("pptx", .document), ("numbers", .document),
        ("mp4", .video), ("mov", .video), ("mp3", .audio), ("wav", .audio)
    ]) func kinds(ext: String, kind: AskFilePreviewKind) {
        #expect(AskFilePreviewPolicy.kind(for: previewHit("file." + ext)) == kind)
    }

    @Test func `rejects placeholders and special files`() {
        #expect(AskFilePreviewPolicy.isResidentRegularFile(mode: S_IFREG, flags: 0))
        #expect(!AskFilePreviewPolicy.isResidentRegularFile(mode: S_IFREG, flags: UInt32(SF_DATALESS)))
        #expect(!AskFilePreviewPolicy.isResidentRegularFile(mode: S_IFDIR, flags: 0))
        #expect(!AskFilePreviewPolicy.isResidentRegularFile(mode: S_IFLNK, flags: 0))
        #expect(!AskFilePreviewPolicy.isResidentRegularFile(mode: S_IFIFO, flags: 0))
    }

    @Test func `all code extensions`() throws {
        for ext in try #require(AskFileType.extensions[.code]) {
            #expect(AskFilePreviewPolicy.kind(path: "/x." + ext) == .text)
        }
        for kind in AskFilePreviewKind.allCases {
            #expect(kind.readsText == [.text, .markdown, .table].contains(kind))
            #expect(kind.canPrefetch == [.image, .pdf].contains(kind))
        }
    }

    @Test(arguments: [
        ".env",
        ".env.local",
        ".envrc",
        "id_rsa.pub",
        "credentials.json",
        "CREDENTIALS.txt",
        "x.pem",
        "x.key",
        "x.p12",
        "x.app",
        "x.zip",
        "x.dmg",
        "x.bin",
        "README",
        ".file.png.icloud"
    ])
    func rejects(name: String) {
        #expect(AskFilePreviewPolicy.kind(for: previewHit(name)) == nil)
    }

    @Test func `rejects folder`() {
        var hit = previewHit("photo.png"); hit.kind = .folder
        #expect(AskFilePreviewPolicy.kind(for: hit) == nil)
    }

    @Test func `text bounds and encoding`() throws {
        #expect(AskFilePreviewText.decode(Data(), hasMore: false)?.text == "")
        #expect(AskFilePreviewText.decode(Data([0, 10]), hasMore: false) == nil)
        #expect(AskFilePreviewText.decode(Data([1]), hasMore: false) == nil)
        #expect(AskFilePreviewText.decode(Data([255]), hasMore: false) == nil)
        #expect(AskFilePreviewText.decode(Data([255]), hasMore: true) == nil)
        for invalid: [UInt8] in [[0xE0, 0x80], [0xED, 0xA0], [0xF0, 0x80], [0xF4, 0x90]] {
            #expect(AskFilePreviewText.decode(Data(invalid), hasMore: true) == nil)
        }
        let bytes = Data("abc界".utf8)
        for count in 1 ... 2 {
            #expect(AskFilePreviewText.decode(bytes.dropLast(count), hasMore: true)?.text == "abc")
            #expect(AskFilePreviewText.decode(bytes.dropLast(count), hasMore: false) == nil)
        }
        let lines = Array(repeating: "hello", count: 205).joined(separator: "\r\n")
        let result = try #require(AskFilePreviewText.decode(Data(lines.utf8), hasMore: false))
        #expect(result.text.components(separatedBy: "\n").count == 200)
        #expect(result.truncated)
        #expect(AskFilePreviewText.decode(Data("a\rb\tc".utf8), hasMore: false)?.text == "a\nb\tc")
    }

    @Test func tables() {
        #expect(AskFilePreviewText.table("a,b\n\"c,d\",\"e\"\"f\"\n", separator: ",") == [["a", "b"], ["c,d", "e\"f"]])
        #expect(AskFilePreviewText.table("a\tb\n1\t2", separator: "\t") == [["a", "b"], ["1", "2"]])
        #expect(AskFilePreviewText.table("\"a\nb\",c", separator: ",") == [["a\nb", "c"]])
        #expect(AskFilePreviewText.table("", separator: ",").isEmpty)
        #expect(AskFilePreviewText.table(Array(repeating: "a,b", count: 60).joined(separator: "\n"), separator: ",")
            .count == 30)
        #expect(AskFilePreviewText.table(Array(repeating: "a", count: 60).joined(separator: ","), separator: ",")[0]
            .count == 30)
    }
}

@Suite("File preview placement")
struct AskFilePreviewPlacementTests {
    @Test func `sides and minimum height`() throws {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let card = CGRect(x: 400, y: 500, width: 600, height: 100)
        let right = try #require(AskFilePreviewPlacement.resolve(card: card, screens: [screen]))
        #expect(right.side == .right)
        #expect(right.frame == CGRect(x: 1010, y: 280, width: 380, height: 320))
        let left = try #require(AskFilePreviewPlacement.resolve(card: card.offsetBy(dx: 450, dy: 0), screens: [screen]))
        #expect(left.side == .left)
        #expect(left.frame.maxX == 840)
        #expect(AskFilePreviewPlacement.resolve(
            card: CGRect(x: 270, y: 300, width: 740, height: 400),
            screens: [CGRect(x: 0, y: 0, width: 1280, height: 900)]
        ) == nil)
        #expect(AskFilePreviewPlacement.resolve(card: card, screens: []) == nil)
        #expect(AskFilePreviewPlacement.resolve(card: card.offsetBy(dx: 3000, dy: 0), screens: [screen]) == nil)
    }

    @Test func `reduced width and displays`() throws {
        let card = CGRect(x: -1050, y: -200, width: 600, height: 500)
        let screen = CGRect(x: -1400, y: -400, width: 1400, height: 1000)
        let result = try #require(AskFilePreviewPlacement.resolve(
            card: card,
            screens: [.init(x: 0, y: 0, width: 1600, height: 1000), screen]
        ))
        #expect(result.frame.maxY == card.maxY)
        #expect(result.frame.height == 500)
        #expect(result.side == .right)
        let narrow = CGRect(x: 0, y: 0, width: 1200, height: 900)
        #expect(AskFilePreviewPlacement
            .resolve(card: .init(x: 290, y: 100, width: 600, height: 500), screens: [narrow])?.frame.width == 300)
        #expect(AskFilePreviewPlacement
            .resolve(card: .init(x: 310, y: 100, width: 620, height: 500), screens: [narrow])?.side == .left)
    }
}

@Suite("File preview selection timing", .exclusiveUIState)
@MainActor
struct AskFilePreviewControllerTests {
    @Test func `query metadata changes keep the same file load and content identity`() {
        let clock = PreviewTestClock(), loader = PreviewTestLoader()
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        let first = previewHit("xcode.swift"), neighbour = previewHit("next.png")
        controller.request(first, neighbours: [neighbour])
        clock.advance(0.05)
        let cancellations = loader.cancelled
        var updated = first
        updated.score = 42; updated.match = 10; updated.highlights = [0 ..< 4]
        controller.request(updated)
        #expect(controller.state.hit == updated)
        clock.advance(0.07)
        #expect(loader.requests.count == 1, "Metadata changes must not restart the dwell timer")
        loader.completions[0](.init(kind: .text, text: "let value = 1"))
        let contentID = controller.state.contentID
        updated.name = "Xcode.swift"; updated.highlights = [0 ..< 5]
        controller.request(updated)
        clock.advance(1)
        #expect(controller.isVisible)
        #expect(controller.state.hit == updated)
        #expect(controller.state.content?.text == "let value = 1")
        #expect(controller.state.contentID == contentID)
        #expect(loader.requests.count == 1)
        #expect(loader.cancelled == cancellations)
        #expect(loader.prefetched == [neighbour])
    }

    @Test func `debounce skeleton and stale results`() {
        let clock = PreviewTestClock(), loader = PreviewTestLoader()
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        controller.request(previewHit("a.txt")); clock.advance(0.119)
        #expect(loader.requests.isEmpty)
        controller.request(previewHit("b.txt")); clock.advance(0.12)
        #expect(loader.requests.map(\.name) == ["b.txt"])
        #expect(!controller.isVisible)
        clock.advance(0.149); #expect(!controller.isVisible)
        clock.advance(0.001); #expect(controller.isVisible); #expect(controller.state.skeleton)
        controller.request(previewHit("c.txt")); clock.advance(0.12)
        loader.completions[0](AskFilePreviewContent(kind: .text, text: "stale"))
        #expect(controller.state.content == nil)
        loader.completions[1](AskFilePreviewContent(kind: .text, text: "current"))
        #expect(controller.state.content?.text == "current"); #expect(!controller.state.skeleton)
        controller.dismissNow(); #expect(!controller.isVisible)
    }

    @Test func `retain content header and grace`() {
        let clock = PreviewTestClock(), loader = PreviewTestLoader()
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        controller.request(previewHit()); clock.advance(0.12)
        loader.completions[0](AskFilePreviewContent(kind: .text, text: "first"))
        #expect(controller.isVisible)
        controller.request(previewHit("second.txt"))
        #expect(controller.state.hit?.name == "second.txt")
        #expect(controller.state.content?.text == "first")
        controller.request(nil); clock.advance(0.149); #expect(controller.isVisible)
        controller.request(previewHit("second.txt")); clock.advance(0.12)
        #expect(controller.isVisible)
        loader.completions.last?(AskFilePreviewContent(kind: .text, text: "second"))
        controller.request(nil); clock.advance(0.15); #expect(!controller.isVisible)
        clock.advance(0.14); #expect(controller.state.content == nil)
    }

    @Test func `immediate dismiss failure and same selection`() {
        let clock = PreviewTestClock(), loader = PreviewTestLoader()
        let controller = AskFilePreviewController(loader: loader, clock: clock, reduceMotion: { true })
        controller.request(previewHit()); controller.request(previewHit()); clock.advance(0.12)
        #expect(loader.requests.count == 1)
        loader.completions[0](AskFilePreviewContent(kind: .text))
        controller.request(nil, empty: true)
        #expect(!controller.isVisible); #expect(controller.state.content == nil)
        clock.advance(1)
        controller.request(previewHit()); clock.advance(0.12)
        loader.completions[1](nil)
        #expect(!controller.isVisible)
        controller.request(previewHit("bad.zip")); clock.advance(0.15)
        #expect(loader.requests.count == 2)
        controller.request(previewHit()); controller.dismissNow(); clock.advance(1)
        #expect(loader.requests.count == 2)
    }
}

@Suite("File preview reader")
struct AskFilePreviewReaderTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: AskFileScope.canonical(root.path))
    }

    @Test func `worker reads bounds and failures`() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.txt")
        func read() -> AskFileReadResponse {
            AskFileWorkerCommand.handle(.init(operation: .preview, path: url.path))
        }
        try Data().write(to: url)
        #expect(
            read().error == nil,
            "Path: \(url.path), error: \(String(describing: read().error)), mounts: \(String(describing: read().skippedMounts))"
        )
        #expect(read().text == ""); #expect(read().fileSize == 0)
        try Data((String(repeating: "a", count: 65535) + "界more").utf8).write(to: url)
        #expect(read().text?.utf8.count == 65535); #expect(read().truncated == true)
        try Data(Array(repeating: "line", count: 300).joined(separator: "\n").utf8).write(to: url)
        #expect(read().text?.components(separatedBy: "\n").count == 200)
        try Data([0, 1, 2]).write(to: url)
        #expect(read().error == EILSEQ)
        #expect(AskFileWorkerCommand.handle(.init(operation: .preview, path: url.path, readText: false)).fileSize == 3)
        #expect(AskFileWorkerCommand.handle(.init(
            operation: .preview,
            path: root.appendingPathComponent("missing.txt").path
        )).error != nil)
        #expect(AskFileWorkerCommand.handle(.init(operation: .preview, path: url.path, blocked: [root.path]))
            .error == EACCES)
        #expect(AskFileWorkerCommand.handle(.init(operation: .preview, path: root.appendingPathComponent(".env").path))
            .error == EACCES)
        let alias = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        #expect(AskFileWorkerCommand.handle(.init(operation: .preview, path: alias.path)).error == EINVAL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        #expect(read().error == EACCES)
        #expect(AskFileWorkerCommand.handle(.init(operation: .preview, path: url.path, readText: false))
            .error == EACCES)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var responses: [AskFileReadResponse] = []
        try AskFileWorkerCommand.stream(
            .init(operation: .preview, path: url.path),
            mounts: .init(excluded: [root.path])
        ) { responses.append($0) }
        #expect(responses.last?.skippedMounts == [root.path])
    }

    @Test func `preview read deadline stops an unresponsive worker`() {
        let reader = AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "read first; read second"], timeout: 0.05, startupTimeout: 0.05)
        #expect(throws: AskFileReadError.self) {
            try reader.read(.init(operation: .preview, path: "/test.txt"))
        }
    }

    @Test func `subprocess round trip`() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.txt")
        try Data("hello\nworld".utf8).write(to: url)
        let reader = AskFileReader()
        let result = try reader.read(.init(operation: .preview, path: url.path))
        #expect(result.text == "hello\nworld"); #expect(result.fileSize == 11); #expect(result.modified != nil)
        #expect(throws: AskFileReadError.self) { try reader.read(
            .init(operation: .preview, path: url.path),
            isCancelled: { true }
        ) }
    }
}
