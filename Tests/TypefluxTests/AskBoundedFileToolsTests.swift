import Darwin
@testable import Typeflux
import XCTest

final class AskBoundedFileToolsTests: XCTestCase {
    var root: URL!
    var tools: AskFileTools!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tools = AskFileTools(roots: [root.path])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @nonobjc func put(_ name: String, _ data: Data) throws {
        try data.write(to: root.appendingPathComponent(name))
    }

    @nonobjc func put(_ name: String, _ text: String) throws {
        try put(name, Data(text.utf8))
    }

    func contents(_ name: String = "file") throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(name),
            encoding: .utf8
        )
    }

    func staging() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".typeflux-write-") }
    }

    func resumeAll(_ first: AskFileRead.Page, _ name: String) throws -> String {
        var page = first, result = page.text, seen = Set<String>()
        while let cursor = page.continuation {
            XCTAssertTrue(seen.insert(cursor).inserted)
            XCTAssertLessThanOrEqual(cursor.utf8.count, 4096)
            page = try tools.readPage(name, continuation: cursor)
            XCTAssertLessThanOrEqual(page.rendered.utf8.count, 60000)
            result += page.text
        }
        return result
    }

    func testHugeLineCombiningUTF8AndCRLFReconstructWithoutGaps() throws {
        let text = String(repeating: "abé😀e\u{301}", count: 250_000) + "\r\nend\r\n"
        try put("file", text)
        let first = try tools.readPage("file")
        XCTAssertTrue(first.partial)
        XCTAssertTrue(first.rendered.contains("Partial line"))
        XCTAssertEqual(try resumeAll(first, "file"), text)
    }

    func testUTF8ScalarStraddlesBufferAndOutputBoundaries() throws {
        let text = String(repeating: "a", count: 65535) + "😀" + String(repeating: "é", count: 60000) + "\r\nb\n"
        try put("file", text)
        XCTAssertEqual(try resumeAll(tools.readPage("file"), "file"), text)
        XCTAssertEqual(try tools.readPage("file", offset: 1, limit: 1).text, "b\n")
    }

    func testLegacyOffsetScanContinuationMakesProgress() throws {
        let text = String(repeating: "x", count: AskFileTools.maximumScanBytes + 111) + "\nrequested\nnext"
        try put("file", text)
        let page = try tools.readPage("file", offset: 1, limit: 1)
        XCTAssertTrue(page.scanning); XCTAssertFalse(page.eof); XCTAssertEqual(page.text, "")
        let next = try tools.readPage("file", continuation: XCTUnwrap(page.continuation))
        XCTAssertEqual(next.text, "requested\n"); XCTAssertNil(next.continuation)
    }

    func testScanBudgetAtSplitScalarResumesBeforeScalar() throws {
        let text = String(repeating: "x", count: AskFileTools.maximumScanBytes - 1) + "😀\nlast"
        try put("file", text)
        let page = try tools.readPage("file", offset: 1)
        XCTAssertTrue(page.scanning)
        XCTAssertEqual(try tools.readPage("file", continuation: XCTUnwrap(page.continuation)).text, "last")
    }

    func testEmptyEOFAndLimit() throws {
        try put("file", "")
        let empty = try tools.readPage("file")
        XCTAssertTrue(empty.eof); XCTAssertEqual(empty.text, ""); XCTAssertNil(empty.continuation)
        try put("file", "a\r\nb\n")
        XCTAssertEqual(try tools.readPage("file", limit: 1).text, "a\r\n")
        XCTAssertEqual(try tools.readPage("file", offset: 3).text, "")
        XCTAssertEqual(try tools.readPage("file", offset: 1, limit: 1).numbered, "2\tb\n")
    }

    func testMalformedInconsistentAndStaleCursors() throws {
        try put("file", String(repeating: "a", count: 100_000))
        let page = try tools.readPage("file")
        let cursor = try XCTUnwrap(page.continuation)
        for bad in ["", "%%%", "a", String(repeating: "a", count: 4097), String(cursor.dropLast()) + "_"] {
            XCTAssertThrowsError(try tools.readPage("file", continuation: bad))
        }
        let state = try AskFileRead.decode(cursor)
        let mutations: [(inout AskFileRead.Cursor) -> Void] = [
            { $0.position = -1 }, { $0.position = Int64.max }, { $0.line = -1 },
            { $0.requestedLine = Int.max }, { $0.remainingLines = 0 }, { $0.format = 9 },
            { $0.root = "/" }, { $0.path = ["other"] }, { $0.rootIdentity = "other" },
            { $0.requestedLine = 20; $0.line = 0; $0.partial = true }
        ]
        for mutate in mutations {
            var changed = state; mutate(&changed)
            XCTAssertThrowsError(try tools.readPage("file", continuation: AskFileRead.encode(changed)))
        }
        try put("other", String(repeating: "b", count: 100_000))
        XCTAssertThrowsError(try tools.readPage("other", continuation: cursor))
        try put("file", String(repeating: "c", count: 100_000))
        XCTAssertThrowsError(try tools.readPage("file", continuation: cursor))
        XCTAssertThrowsError(try AskFileTools(roots: []).readPage("file", continuation: cursor))
    }

    func testToolSchemaAndArgumentBounds() throws {
        try put("file", "abc")
        let definition = try XCTUnwrap(AskFileTools.definition(roots: [root.path]))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: definition.parameters.data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["expected_version"])
        XCTAssertNotNil(properties["continuation"])
        XCTAssertThrowsError(try tools.execute([
            "action": "write",
            "path": "new",
            "content": "data",
            "expected_version": 1
        ]))
        XCTAssertThrowsError(try tools.write("new", content: "\0"))
        for value: Any in [-1, Int.max, 1.5, true, "1"] {
            XCTAssertThrowsError(try tools.execute(["action": "read", "path": "file", "offset": value]))
        }
        for args: [String: Any] in [["limit": 0], ["continuation": "x", "offset": 0], ["continuation": 1]] {
            XCTAssertThrowsError(try tools.execute(args.merging(["action": "read", "path": "file"]) { original, _ in
                original
            }))
        }
        XCTAssertTrue(try tools.execute(["action": "read", "path": "file", "limit": 1]).contains("1\tabc"))
    }

    func testBinaryAndStrictEncodingOnlyInConsumedData() throws {
        for bytes in [[UInt8](arrayLiteral: 0), [0xFF], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xE2, 0x82]] {
            try put("file", Data(bytes)); XCTAssertThrowsError(try tools.readPage("file"))
        }
        try put("file", Data("good\n".utf8) + Data([0]))
        XCTAssertEqual(try tools.readPage("file", limit: 1).text, "good\n")
        XCTAssertThrowsError(try tools.readPage("file"))
        try put("file", Data(repeating: 65, count: 100_000) + Data([0]))
        let first = try tools.readPage("file")
        XCTAssertNotNil(first.continuation)
        XCTAssertThrowsError(try resumeAll(first, "file"))
    }

    func testReadDetectsGrowthReplacementAndParentRename() throws {
        for event in ["read", "release"] {
            try put("file", "old")
            var hooked = try XCTUnwrap(tools)
            hooked.hooks.onEvent = { [root] current in
                if current == event {
                    try Data("changed".utf8).write(to: root!.appendingPathComponent("file"))
                }
            }
            XCTAssertThrowsError(try hooked.readPage("file"))
        }
        let directory = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: directory.appendingPathComponent("file"))
        tools.hooks.onEvent = { [root] event in
            if event == "release" {
                try FileManager.default.moveItem(
                    at: root!.appendingPathComponent("dir"),
                    to: root!.appendingPathComponent("moved")
                )
                try FileManager.default.createDirectory(
                    at: root!.appendingPathComponent("dir"),
                    withIntermediateDirectories: true
                )
            }
        }
        XCTAssertThrowsError(try tools.readPage("dir/file"))
    }

    func testUnsafeTargetsAndRootRevocation() throws {
        try put("file", "safe")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("file")
        )
        XCTAssertThrowsError(try tools.readPage("link"))
        XCTAssertThrowsError(try tools.write("link", content: "bad"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
        XCTAssertThrowsError(try tools.readPage("fifo"))
        for name in ["../file", "/etc/hosts", "a/../file", "\0", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try tools.readPage(name))
        }
        let linkedRoot = root.appendingPathComponent("rootlink")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        XCTAssertThrowsError(try AskFileTools(roots: [linkedRoot.path]).readPage("file"))
        tools.hooks.validateGrant = { throw AskFileAccess.denied }
        XCTAssertThrowsError(try tools.readPage("file"))
    }
}

extension AskBoundedFileToolsTests {
    func testConditionalWriteEditAndPermissions() throws {
        XCTAssertTrue(try tools.write("new/sub/file", content: "hello").hasPrefix("Created"))
        let name = "new/sub/file"
        let version = try tools.readPage(name).version
        XCTAssertThrowsError(try tools.write(name, content: "lost"))
        XCTAssertThrowsError(try tools.edit(name, old: "hello", new: "lost"))
        XCTAssertThrowsError(try tools.write(name, content: "lost", expectedVersion: "stale"))
        XCTAssertEqual(chmod(root.appendingPathComponent(name).path, 0o640), 0)
        let latest = try tools.readPage(name).version
        XCTAssertNotEqual(version, latest)
        XCTAssertTrue(try tools.edit(name, old: "hello", new: "world", expectedVersion: latest).hasPrefix("Edited"))
        let info = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
        XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(try contents(name), "world")
        XCTAssertTrue(try tools.write(name, content: "replaced", expectedVersion: tools.readPage(name).version)
            .hasPrefix("Replaced"))
        XCTAssertThrowsError(try tools.write("absent", content: "x", expectedVersion: latest))
        XCTAssertThrowsError(try tools.edit("absent", old: "x", new: "y", expectedVersion: latest))
    }

    func testMutationLimitsAmbiguityHardlinksAndBinary() throws {
        try put("file", "x x")
        let version = try tools.readPage("file").version
        XCTAssertThrowsError(try tools.edit("file", old: "x", new: "y", expectedVersion: version))
        XCTAssertThrowsError(try tools.edit("file", old: "absent", new: "y", expectedVersion: version))
        XCTAssertThrowsError(try tools.edit("file", old: "", new: "y", expectedVersion: version))
        XCTAssertThrowsError(try tools.write(
            "file",
            content: String(repeating: "x", count: 1_000_001),
            expectedVersion: version
        ))
        XCTAssertThrowsError(try tools.edit(
            "file",
            old: "x x",
            new: String(repeating: "x", count: 1_000_001),
            expectedVersion: version
        ))
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("file"),
            to: root.appendingPathComponent("hard")
        )
        XCTAssertThrowsError(try tools.write("file", content: "bad", expectedVersion: tools.readPage("file").version))
        try put("binary", Data([0]))
        let access = try AskFileAccess(AskFileAccess.location("binary", roots: tools.roots))
        XCTAssertThrowsError(try tools.edit("binary", old: "a", new: "b", expectedVersion: access.version))
        try put("huge", Data(repeating: 65, count: AskFileTools.maximumEditBytes + 1))
        XCTAssertThrowsError(try tools.write("huge", content: "small", expectedVersion: tools.readPage("huge").version))
    }

    func testObservedMutationRacesAndFailureCleanup() throws {
        for event in ["prepared", "staged", "precommit"] {
            try put("file", "original")
            let version = try tools.readPage("file").version
            var hooked = try XCTUnwrap(tools)
            hooked.hooks.onEvent = { [root] current in
                if current == event {
                    try Data("external".utf8).write(to: root!.appendingPathComponent("file"))
                }
            }
            XCTAssertThrowsError(try hooked.edit("file", old: "original", new: "new", expectedVersion: version))
            XCTAssertEqual(try contents(), "external"); XCTAssertEqual(try staging(), [])
        }
        for event in ["write", "staged", "precommit", "commit"] {
            try put("file", "original")
            let version = try tools.readPage("file").version
            var hooked = try XCTUnwrap(tools)
            hooked.hooks.onEvent = {
                current in if current == event {
                    throw CancellationError()
                }
            }
            XCTAssertThrowsError(try hooked.write("file", content: "new", expectedVersion: version))
            XCTAssertEqual(try contents(), "original"); XCTAssertEqual(try staging(), [])
        }
        var failing = try XCTUnwrap(tools)
        failing.hooks.onEvent = {
            event in if event == "write" {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOSPC)
                )
            }
        }
        XCTAssertThrowsError(try failing.write("new", content: "data"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        XCTAssertEqual(try staging(), [])
    }

    func testExclusiveCreateAndSameNameSymlinkSwap() throws {
        tools.hooks.onEvent = { [root] event in
            if event == "commit" {
                try Data("winner".utf8).write(to: root!.appendingPathComponent("file"))
            }
        }
        XCTAssertThrowsError(try tools.write("file", content: "loser"))
        XCTAssertEqual(try contents(), "winner"); XCTAssertEqual(try staging(), [])
        tools.hooks = .init()
        let version = try tools.readPage("file").version
        try put("other", "outside")
        tools.hooks.onEvent = { [root] event in
            if event == "precommit" {
                try FileManager.default.removeItem(at: root!.appendingPathComponent("file"))
                try FileManager.default.createSymbolicLink(
                    at: root!.appendingPathComponent("file"),
                    withDestinationURL: root!.appendingPathComponent("other")
                )
            }
        }
        XCTAssertThrowsError(try tools.write("file", content: "bad", expectedVersion: version))
        XCTAssertEqual(try contents("other"), "outside"); XCTAssertEqual(try staging(), [])
    }

    func testListingBoundedAndDirectoryIdentityRechecked() throws {
        for index in 0 ..< 505 {
            try put("f\(index)", "")
        }
        let listing = try tools.list(".")
        XCTAssertTrue(listing.contains("Partial listing")); XCTAssertLessThanOrEqual(
            listing.components(separatedBy: "\n").count,
            503
        )
        tools.hooks.onEvent = {
            event in if event == "entry" {
                throw CancellationError()
            }
        }
        XCTAssertThrowsError(try tools.list("."))
        tools.hooks.onEvent = {
            event in if event == "release" {
                throw AskFileAccess.conflict
            }
        }
        XCTAssertThrowsError(try tools.list("."))
    }

    func testSearchCaseCRLFChunkBoundaryBinaryAndPartialEmpty() throws {
        try put("file", String(repeating: "a", count: 65534) + "NeedLe\r\nsecond needle\n")
        let found = try tools.search(".", pattern: "needle")
        XCTAssertTrue(found.contains("file:1:")); XCTAssertTrue(found.contains("file:2: second needle"))
        XCTAssertEqual(try tools.search("file", pattern: "absent"), "No matches.")
        try put("binary", Data([0]))
        XCTAssertTrue(try tools.search(".", pattern: "absent").contains("No matches in the inspected portion"))
        XCTAssertThrowsError(try tools.search(".", pattern: ""))
        XCTAssertThrowsError(try tools.search(".", pattern: String(repeating: "x", count: 501)))
        XCTAssertThrowsError(try tools.search(".", pattern: "e" + String(repeating: "\u{301}", count: 2000)))
        tools.hooks.onEvent = {
            event in if event == "read" {
                throw CancellationError()
            }
        }
        XCTAssertThrowsError(try tools.search("file", pattern: "needle")) { XCTAssertTrue($0 is CancellationError) }
    }

    func testSearchDepthEntryAggregateAndOutputBudgets() throws {
        var directory = try XCTUnwrap(root)
        for _ in 0 ..< 18 {
            directory.appendPathComponent("d")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("needle".utf8).write(to: directory.appendingPathComponent("deep"))
        XCTAssertTrue(try tools.search(".", pattern: "needle").contains("Partial search"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("d"))
        for index in 0 ..< 5002 {
            try put("entry\(index)", "")
        }
        let broad = try tools.search(".", pattern: "needle")
        XCTAssertTrue(broad.contains("5000 entries visited")); XCTAssertTrue(broad
            .contains("No matches in the inspected portion"))
        for name in try FileManager.default
            .contentsOfDirectory(atPath: root.path) {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        for index in 0 ..< 20 {
            try put("large\(index)", Data(repeating: 65, count: 1_999_999))
        }
        let aggregate = try tools.search(".", pattern: "needle")
        XCTAssertTrue(aggregate.contains("Partial search"))
        try put("matches", String(repeating: "needle\n", count: 201))
        XCTAssertTrue(try tools.search("matches", pattern: "needle").contains("Partial search"))
        try put("wide", String(repeating: "needle" + String(repeating: "x", count: 900) + "\n", count: 100))
        let wide = try tools.search("wide", pattern: "needle")
        XCTAssertLessThanOrEqual(wide.utf8.count, 60000); XCTAssertTrue(wide.contains("Partial search"))
    }

    func testAppendDuringReadAndSearchGrowthAreBounded() throws {
        try put("file", "original")
        var growing = try XCTUnwrap(tools)
        growing.hooks.onEvent = { [root] event in
            if event == "read" {
                let handle = try FileHandle(forWritingTo: root!.appendingPathComponent("file"))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 65, count: 65536))
            }
        }
        XCTAssertThrowsError(try growing.readPage("file"))
        let result = try growing.search(".", pattern: "original")
        XCTAssertTrue(result.contains("No matches in the inspected portion"))
        XCTAssertTrue(result.contains("Partial search"))
        XCTAssertLessThan(
            try XCTUnwrap(try FileManager.default
                .attributesOfItem(atPath: root.appendingPathComponent("file").path)[.size] as? Int),
            3_000_000
        )
    }

    func testParentRenameBeforeCommitCleansPinnedStaging() throws {
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try put("parent/file", "original")
        let version = try tools.readPage("parent/file").version
        tools.hooks.onEvent = { [root] event in
            if event == "precommit" {
                try FileManager.default.moveItem(
                    at: root!.appendingPathComponent("parent"),
                    to: root!.appendingPathComponent("moved")
                )
                try FileManager.default.createDirectory(
                    at: root!.appendingPathComponent("parent"),
                    withIntermediateDirectories: true
                )
                try Data("replacement".utf8).write(to: root!.appendingPathComponent("parent/file"))
            }
        }
        XCTAssertThrowsError(try tools.write("parent/file", content: "bad", expectedVersion: version))
        XCTAssertEqual(try contents("parent/file"), "replacement")
        XCTAssertEqual(try contents("moved/file"), "original")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("moved").path)
            .contains { $0.hasPrefix(".typeflux-write-") })
    }

    func testRootRenameBeforeReleaseDoesNotReturnPinnedBytes() throws {
        try put("file", "original")
        let moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        tools.hooks.onEvent = { [root] event in
            if event == "release" {
                try FileManager.default.moveItem(at: root!, to: moved)
                try FileManager.default.createDirectory(at: root!, withIntermediateDirectories: true)
            }
        }
        XCTAssertThrowsError(try tools.readPage("file"))
    }

    func testSearchDoesNotReleaseReplacedMatches() throws {
        try put("file", "needle")
        tools.hooks.onEvent = { [root] event in
            if event == "release" {
                try Data("changed".utf8).write(to: root!.appendingPathComponent("file"))
            }
        }
        let result = try tools.search(".", pattern: "needle")
        XCTAssertFalse(result.contains("file:1:"))
        XCTAssertTrue(result.contains("No matches in the inspected portion"))
    }

    func testStagingSubstitutionCannotCommitALink() throws {
        try put("file", "original")
        try put("other", "private")
        let version = try tools.readPage("file").version
        tools.hooks.onEvent = { [root] event in
            if event == "staged" {
                let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root!.path)
                    .first { $0.hasPrefix(".typeflux-write-") })
                let url = root!.appendingPathComponent(stage)
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(
                    at: url,
                    withDestinationURL: root!.appendingPathComponent("other")
                )
            }
        }
        XCTAssertThrowsError(try tools.write("file", content: "new", expectedVersion: version))
        XCTAssertEqual(try contents(), "original")
        XCTAssertEqual(try contents("other"), "private")
        XCTAssertEqual(try staging(), [])
    }

    func testSingleUnboundedGraphemeStillAdvancesByBytes() throws {
        let text = "e" + String(repeating: "\u{301}", count: 600_000)
        try put("file", text)
        let first = try tools.readPage("file")
        XCTAssertNotNil(first.continuation)
        XCTAssertTrue(first.partial)
        XCTAssertEqual(try resumeAll(first, "file"), text)
    }
}
